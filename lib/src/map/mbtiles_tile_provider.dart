import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import '../data/database.dart';

/// Serves basemap tiles to `flutter_map` out of the bundled MBTiles archive.
///
/// MBTiles is a SQLite database, and the app already opens SQLite for the place
/// database, so reading tiles is a query rather than a dependency. Using
/// `flutter_map_mbtiles` instead would pull in `mbtiles` and
/// `sqlite3_flutter_libs`, adding a second SQLite build to the package — around
/// 1.5 MB per ABI against the NFR-3 budget — to do what the statement below
/// does.
class MbTilesTileProvider extends TileProvider {
  MbTilesTileProvider(this._db);

  final Database _db;

  /// Opens an extracted archive read-only.
  static Future<MbTilesTileProvider> openAt(
    String path, {
    DatabaseFactory? factory,
  }) async {
    final db = await (factory ?? appDatabaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    return MbTilesTileProvider(db);
  }

  /// Reads one tile, or null when the archive has no such tile.
  ///
  /// [y] is a slippy-map row index, counted from the north. MBTiles stores rows
  /// from the south, so it is flipped here. This is the same conversion the
  /// builder applies in reverse, and getting it wrong renders the world upside
  /// down.
  Future<Uint8List?> tileBytes(int zoom, int x, int y) async {
    final rows = await _db.rawQuery(
      'SELECT tile_data FROM tiles '
      'WHERE zoom_level = ? AND tile_column = ? AND tile_row = ? LIMIT 1',
      [zoom, x, (1 << zoom) - 1 - y],
    );
    if (rows.isEmpty) return null;
    return rows.first['tile_data'] as Uint8List?;
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return _MbTilesImage(this, coordinates.z, coordinates.x, coordinates.y);
  }

  @override
  Future<void> dispose() async {
    await _db.close();
    super.dispose();
  }
}

/// Resolves a single tile from the archive.
///
/// A tile that is absent resolves to a transparent image rather than throwing.
/// `flutter_map` requests tiles speculatively around the viewport and past the
/// edges of the world, so a missing tile is an ordinary event; letting it raise
/// would put an error box on the map, which NFR-6 forbids.
@immutable
class _MbTilesImage extends ImageProvider<_MbTilesImage> {
  const _MbTilesImage(this.provider, this.z, this.x, this.y);

  final MbTilesTileProvider provider;
  final int z;
  final int x;
  final int y;

  @override
  Future<_MbTilesImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_MbTilesImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _MbTilesImage key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      _load(key, decode),
      informationCollector: () => [
        DiagnosticsProperty<String>('Tile', 'z$z/x$x/y$y'),
      ],
    );
  }

  Future<ImageInfo> _load(
    _MbTilesImage key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await key.provider.tileBytes(key.z, key.x, key.y);
    if (bytes == null || bytes.isEmpty) {
      return ImageInfo(image: await _transparentTile());
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await decode(buffer);
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _MbTilesImage &&
          other.provider == provider &&
          other.z == z &&
          other.x == x &&
          other.y == y);

  @override
  int get hashCode => Object.hash(provider, z, x, y);

  @override
  String toString() => 'MbTilesImage(z$z/x$x/y$y)';
}

ui.Image? _transparentCache;

/// A 1x1 transparent image, built once and reused for every missing tile.
Future<ui.Image> _transparentTile() async {
  final cached = _transparentCache;
  if (cached != null) return cached;

  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 1, 1),
    Paint()..color = const Color(0x00000000),
  );
  final image = await recorder.endRecording().toImage(1, 1);
  return _transparentCache = image;
}
