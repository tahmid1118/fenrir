import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fenrir/src/map/layered_tile_provider.dart';
import 'package:fenrir/src/map/mbtiles_archive.dart';

void main() {
  late Directory temp;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fenrir_layer_test');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  /// Builds a small MBTiles file whose tiles carry an identifiable payload.
  Future<String> makeArchive({
    required String name,
    required int minZoom,
    required int maxZoom,
    String? bounds,
    required List<(int z, int x, int y, String marker)> tiles,
  }) async {
    final path = p.join(temp.path, '$name.mbtiles');
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );

    await db.execute('CREATE TABLE metadata (name TEXT, value TEXT)');
    await db.execute('CREATE TABLE tiles (zoom_level INTEGER, '
        'tile_column INTEGER, tile_row INTEGER, tile_data BLOB)');

    final meta = <String, String>{
      'name': name,
      'format': 'png',
      'minzoom': '$minZoom',
      'maxzoom': '$maxZoom',
      'bounds': ?bounds,
    };
    for (final e in meta.entries) {
      await db.insert('metadata', {'name': e.key, 'value': e.value});
    }

    for (final (z, x, y, marker) in tiles) {
      await db.insert('tiles', {
        'zoom_level': z,
        'tile_column': x,
        // Stored TMS, counted from the south.
        'tile_row': (1 << z) - 1 - y,
        'tile_data': Uint8List.fromList(marker.codeUnits),
      });
    }

    await db.close();
    return path;
  }

  Future<MbTilesArchive> open(String path) =>
      MbTilesArchive.openAt(path, factory: databaseFactoryFfi);

  group('FR-4.2 detail upgrade', () {
    test('a regional pack takes precedence over the basemap', () async {
      // The whole point: where a pack is installed the map draws its detail,
      // and where it is not the basemap still answers. One map that gets
      // sharper, not two maps with a seam.
      final basemap = await makeArchive(
        name: 'basemap',
        minZoom: 0,
        maxZoom: 5,
        tiles: [(5, 23, 13, 'BASEMAP')],
      );
      final pack = await makeArchive(
        name: 'pack',
        minZoom: 5,
        maxZoom: 14,
        tiles: [(5, 23, 13, 'PACK')],
      );

      final provider = LayeredTileProvider([
        await open(pack),
        await open(basemap),
      ]);
      addTearDown(provider.dispose);

      final bytes = await provider.tileBytes(5, 23, 13);
      expect(String.fromCharCodes(bytes!), 'PACK');
    });

    test('falls through to the basemap where no pack covers', () async {
      final basemap = await makeArchive(
        name: 'basemap',
        minZoom: 0,
        maxZoom: 5,
        tiles: [(3, 1, 2, 'BASEMAP')],
      );
      final pack = await makeArchive(
        name: 'pack',
        minZoom: 6,
        maxZoom: 14,
        tiles: [(6, 1, 2, 'PACK')],
      );

      final provider = LayeredTileProvider([
        await open(pack),
        await open(basemap),
      ]);
      addTearDown(provider.dispose);

      final bytes = await provider.tileBytes(3, 1, 2);
      expect(String.fromCharCodes(bytes!), 'BASEMAP');
    });

    test('a hole in a pack is filled by the layer underneath', () async {
      // A pack that covers an area but happens to lack one tile must not end
      // the search, or the map shows a gap where the basemap had an answer.
      final basemap = await makeArchive(
        name: 'basemap',
        minZoom: 0,
        maxZoom: 5,
        tiles: [(5, 23, 13, 'BASEMAP')],
      );
      final pack = await makeArchive(
        name: 'pack',
        minZoom: 0,
        maxZoom: 14,
        tiles: [(5, 99, 99, 'ELSEWHERE')],
      );

      final provider = LayeredTileProvider([
        await open(pack),
        await open(basemap),
      ]);
      addTearDown(provider.dispose);

      final bytes = await provider.tileBytes(5, 23, 13);
      expect(String.fromCharCodes(bytes!), 'BASEMAP');
    });

    test('a tile nothing holds resolves to null, not an error', () async {
      final basemap = await makeArchive(
        name: 'basemap',
        minZoom: 0,
        maxZoom: 5,
        tiles: [(0, 0, 0, 'BASEMAP')],
      );
      final provider = LayeredTileProvider([await open(basemap)]);
      addTearDown(provider.dispose);

      expect(await provider.tileBytes(9, 5, 5), isNull);
    });
  });

  group('skipping archives cheaply', () {
    test('zoom range rules an archive out without a query', () async {
      final pack = await makeArchive(
        name: 'pack',
        minZoom: 10,
        maxZoom: 14,
        tiles: [],
      );
      final archive = await open(pack);
      addTearDown(archive.close);

      expect(archive.covers(5, 0, 0), isFalse);
      expect(archive.covers(12, 0, 0), isTrue);
      expect(archive.covers(15, 0, 0), isFalse);
    });

    test('bounds rule out tiles on the far side of the world', () async {
      // Bangladesh's extent, roughly.
      final pack = await makeArchive(
        name: 'bd',
        minZoom: 0,
        maxZoom: 14,
        bounds: '88.0,20.5,92.7,26.7',
        tiles: [],
      );
      final archive = await open(pack);
      addTearDown(archive.close);

      // Zoom 5 tile over Bangladesh.
      expect(archive.covers(5, 23, 13), isTrue);
      // Zoom 5 tile over the Americas.
      expect(archive.covers(5, 8, 12), isFalse);
    });

    test('an archive with no stated bounds is assumed to cover everything',
        () async {
      // Refusing to read it would be a worse failure than querying it
      // needlessly.
      final pack = await makeArchive(
        name: 'unbounded',
        minZoom: 0,
        maxZoom: 14,
        tiles: [],
      );
      final archive = await open(pack);
      addTearDown(archive.close);

      expect(archive.covers(5, 0, 0), isTrue);
      expect(archive.covers(5, 31, 31), isTrue);
    });
  });

  group('the detail hint FR-4.2 asks for', () {
    test('reports the best zoom available at a position', () async {
      final basemap = await makeArchive(
        name: 'basemap',
        minZoom: 0,
        maxZoom: 5,
        tiles: [],
      );
      final bd = await makeArchive(
        name: 'bd',
        minZoom: 0,
        maxZoom: 14,
        bounds: '88.0,20.5,92.7,26.7',
        tiles: [],
      );

      final provider = LayeredTileProvider([
        await open(bd),
        await open(basemap),
      ]);
      addTearDown(provider.dispose);

      // Inside Bangladesh: full detail.
      expect(provider.bestZoomAt(23.7461, 90.3742), 14);
      // In London: only the bundled ceiling, so the user is looking at
      // upscaled tiles and a pack would help.
      expect(provider.bestZoomAt(51.5074, -0.1278), 5);
    });
  });

  group('rebuilding the stack', () {
    test('archives can be replaced when a pack is installed or deleted',
        () async {
      final basemap = await makeArchive(
        name: 'basemap',
        minZoom: 0,
        maxZoom: 5,
        tiles: [(5, 23, 13, 'BASEMAP')],
      );
      final pack = await makeArchive(
        name: 'pack',
        minZoom: 0,
        maxZoom: 14,
        tiles: [(5, 23, 13, 'PACK')],
      );

      final provider = LayeredTileProvider([await open(basemap)]);
      addTearDown(provider.dispose);

      expect(
        String.fromCharCodes((await provider.tileBytes(5, 23, 13))!),
        'BASEMAP',
      );

      await provider.setArchives([await open(pack), await open(basemap)]);

      expect(
        String.fromCharCodes((await provider.tileBytes(5, 23, 13))!),
        'PACK',
      );
    });
  });
}
