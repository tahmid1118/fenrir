import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'src/geojson.dart';
import 'src/mbtiles_writer.dart';
import 'src/mercator.dart';
import 'src/tile_canvas.dart';

/// Builds the Tier 1 world basemap from Natural Earth data.
///
///     dart run tools/build_basemap.dart [--max-zoom 5] [--out path]
///
/// Natural Earth is public domain. That is the reason it is used here rather
/// than an OpenStreetMap extract: at zoom 0 to 5 the only renderable content is
/// coastlines, borders and lakes, which is exactly what Natural Earth provides,
/// and it keeps the bundled tier clear of the ODbL share-alike question that
/// section 7 of the requirements specification flags as unresolved.
///
/// Source files are expected in tools/data/. They are gitignored; re-fetch with
/// the URLs listed in tools/README.md.

/// Colours are deliberately low-contrast. The basemap sits underneath the
/// position marker and its accuracy circle, and a busy map makes the one thing
/// the user actually needs harder to find.
class Palette {
  const Palette({
    required this.ocean,
    required this.land,
    required this.border,
  });

  final Rgb ocean;
  final Rgb land;
  final Rgb border;

  /// Tuned against the app's dark theme surface (#0D1316).
  ///
  /// An earlier pass used a much narrower range, and land was barely
  /// distinguishable from ocean on a phone held at arm's length. A basemap the
  /// user cannot read is an empty map, which is what NFR-6 forbids, so land
  /// carries a clear step up from the water even though the whole palette stays
  /// subdued.
  static final dark = Palette(
    ocean: Rgb.hex('#0A1216'),
    land: Rgb.hex('#2C3E47'),
    border: Rgb.hex('#5B7784'),
  );
}

/// One level-of-detail band: which source files to use over which zooms.
class DetailBand {
  const DetailBand({
    required this.minZoom,
    required this.maxZoom,
    required this.land,
    required this.lakes,
    required this.borders,
  });

  final int minZoom;
  final int maxZoom;
  final String land;
  final String lakes;
  final String borders;
}

const _bands = <DetailBand>[
  // 1:110m is a coarse generalisation, which is what the low zooms want: at
  // zoom 0 the whole world is 256 pixels across, and finer data would cost
  // parsing time to draw detail smaller than a pixel.
  DetailBand(
    minZoom: 0,
    maxZoom: 2,
    land: 'ne_110m_land.geojson',
    lakes: 'ne_110m_lakes.geojson',
    borders: 'ne_110m_admin_0_boundary_lines_land.geojson',
  ),
  DetailBand(
    minZoom: 3,
    maxZoom: 5,
    land: 'ne_50m_land.geojson',
    lakes: 'ne_50m_lakes.geojson',
    borders: 'ne_50m_admin_0_boundary_lines_land.geojson',
  ),
];

const int tileSize = 256;

/// Tiles are rendered at this multiple and averaged down.
///
/// The scanline rasteriser writes hard-edged pixels, so a coastline drawn
/// straight to 256 px looks visibly jagged on a phone.
const int supersample = 2;

const String _dataDir = 'tools/data';

Future<void> main(List<String> args) async {
  final maxZoom = _intArg(args, '--max-zoom') ?? 5;
  final outPath = _stringArg(args, '--out') ?? 'assets/map/basemap.mbtiles';

  final palette = Palette.dark;
  final stopwatch = Stopwatch()..start();

  stdout.writeln('Building basemap, zoom 0-$maxZoom -> $outPath');

  final layers = <int, _BandLayers>{};
  for (final band in _bands) {
    if (band.minZoom > maxZoom) continue;
    final missing = [band.land, band.lakes, band.borders]
        .where((f) => !File('$_dataDir/$f').existsSync())
        .toList();
    if (missing.isNotEmpty) {
      stderr.writeln('Missing source data in $_dataDir: ${missing.join(', ')}');
      stderr.writeln('See tools/README.md for the download URLs.');
      exitCode = 1;
      return;
    }

    final loaded = _BandLayers(
      land: GeoLayer.read('$_dataDir/${band.land}'),
      lakes: GeoLayer.read('$_dataDir/${band.lakes}'),
      borders: GeoLayer.read('$_dataDir/${band.borders}'),
    );
    for (var z = band.minZoom; z <= band.maxZoom; z++) {
      layers[z] = loaded;
    }
    stdout.writeln(
      '  zoom ${band.minZoom}-${band.maxZoom}: '
      '${loaded.land.polygons.length} land, '
      '${loaded.lakes.polygons.length} lakes, '
      '${loaded.borders.lines.length} border lines '
      '(${loaded.pointCount} points)',
    );
  }

  final outFile = File(outPath);
  await outFile.parent.create(recursive: true);
  if (outFile.existsSync()) await outFile.delete();

  final writer = await MbTilesWriter.create(
    outPath,
    name: 'Fenrir world basemap',
    description:
        'Tier 1 offline basemap, zoom 0-$maxZoom, derived from Natural Earth.',
    attribution: 'Natural Earth (public domain)',
    minZoom: 0,
    maxZoom: maxZoom,
  );

  var written = 0;
  var oceanTiles = 0;
  final expected = totalTiles(maxZoom);

  for (var z = 0; z <= maxZoom; z++) {
    final band = layers[z]!;
    final n = tilesPerAxis(z);
    for (var x = 0; x < n; x++) {
      for (var y = 0; y < n; y++) {
        final canvas = _renderTile(z, x, y, band, palette);
        if (canvas.isUniform(palette.ocean)) oceanTiles++;
        writer.addTile(zoom: z, x: x, y: y, png: _encode(canvas));
        written++;
      }
    }
    await writer.flush();
    stdout.writeln('  zoom $z: ${n * n} tiles ($written/$expected)');
  }

  await writer.close();
  stopwatch.stop();

  final bytes = outFile.lengthSync();
  stdout
    ..writeln('')
    ..writeln('Wrote $written tiles in '
        '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s')
    ..writeln('$oceanTiles tiles are open ocean')
    ..writeln('Size: ${(bytes / 1024 / 1024).toStringAsFixed(2)} MB');

  // NFR-3 caps the whole Tier 1 payload at 60 MB. Reporting the combined
  // figure here means the budget is checked at the moment it can be affected,
  // rather than discovered during a release build.
  final placesDb = File('assets/db/places.db');
  if (placesDb.existsSync()) {
    final total = bytes + placesDb.lengthSync();
    stdout.writeln(
      'Tier 1 total with places.db: '
      '${(total / 1024 / 1024).toStringAsFixed(2)} MB of 60 MB (NFR-3)',
    );
    if (total > 60 * 1024 * 1024) {
      stderr.writeln('Tier 1 payload exceeds the NFR-3 budget.');
      exitCode = 1;
    }
  }
}

class _BandLayers {
  _BandLayers({required this.land, required this.lakes, required this.borders});

  final GeoLayer land;
  final GeoLayer lakes;
  final GeoLayer borders;

  int get pointCount =>
      land.pointCount + lakes.pointCount + borders.pointCount;
}

TileCanvas _renderTile(
  int z,
  int x,
  int y,
  _BandLayers band,
  Palette palette,
) {
  final size = tileSize * supersample;
  final canvas = TileCanvas(size, size, palette.ocean);
  final bounds = tileBounds(z, x, y);
  final projector = TileProjector(zoom: z, x: x, y: y, size: size);

  // Bounding-box rejection before any projection. Most rings miss most tiles,
  // and skipping them here is what keeps the build to seconds rather than
  // minutes.
  for (final polygon in band.land.polygons) {
    if (!bounds.intersects(
      polygon.minLon,
      polygon.minLat,
      polygon.maxLon,
      polygon.maxLat,
    )) {
      continue;
    }
    canvas.fillRings(
      [
        _project(polygon.exterior, projector),
        for (final hole in polygon.holes) _project(hole, projector),
      ],
      palette.land,
    );
  }

  for (final lake in band.lakes.polygons) {
    if (!bounds.intersects(
      lake.minLon,
      lake.minLat,
      lake.maxLon,
      lake.maxLat,
    )) {
      continue;
    }
    canvas.fillRings([_project(lake.exterior, projector)], palette.ocean);
  }

  // Borders last so coastlines and lakes do not paint over them.
  for (final line in band.borders.lines) {
    if (!bounds.intersects(
      line.minLon,
      line.minLat,
      line.maxLon,
      line.maxLat,
    )) {
      continue;
    }
    canvas.strokePolyline(
      _project(line, projector),
      palette.border,
      thickness: supersample,
    );
  }

  return canvas.downsample(supersample);
}

Float64List _project(GeoRing ring, TileProjector projector) {
  final source = ring.coordinates;
  final out = Float64List(source.length);
  for (var i = 0; i < source.length; i += 2) {
    out[i] = projector.projectX(source[i]);
    out[i + 1] = projector.projectY(source[i + 1]);
  }
  return out;
}

Uint8List _encode(TileCanvas canvas) {
  final image = img.Image(
    width: canvas.width,
    height: canvas.height,
    numChannels: 3,
  );
  final data = image.data!;
  var k = 0;
  for (var y = 0; y < canvas.height; y++) {
    for (var x = 0; x < canvas.width; x++) {
      data.setPixelRgb(
        x,
        y,
        canvas.pixels[k],
        canvas.pixels[k + 1],
        canvas.pixels[k + 2],
      );
      k += 3;
    }
  }
  // Level 9 costs build time once and saves download size on every install.
  return img.encodePng(image, level: 9);
}

int? _intArg(List<String> args, String name) {
  final value = _stringArg(args, name);
  return value == null ? null : int.tryParse(value);
}

String? _stringArg(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i == -1 || i + 1 >= args.length) return null;
  return args[i + 1];
}
