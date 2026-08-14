import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fenrir/src/map/mbtiles_tile_provider.dart';

void main() {
  // Runs against the real bundled archive, for the same reason the place
  // repository tests do: the tiles that ship are the ones worth testing.
  late MbTilesTileProvider provider;

  setUpAll(() async {
    sqfliteFfiInit();
    provider = await MbTilesTileProvider.openAt(
      p.absolute('assets/map/basemap.mbtiles'),
      factory: databaseFactoryFfi,
    );
  });

  tearDownAll(() async => provider.dispose());

  group('reading tiles', () {
    test('the zoom 0 tile exists and is a PNG', () async {
      final bytes = await provider.tileBytes(0, 0, 0);
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(1000));
      // PNG magic number.
      expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    });

    test('every zoom level has its full complement of tiles', () async {
      for (var z = 0; z <= 5; z++) {
        final n = 1 << z;
        // Corners of the grid, which is where an off-by-one in the row flip
        // shows up first.
        for (final (x, y) in [(0, 0), (n - 1, 0), (0, n - 1), (n - 1, n - 1)]) {
          expect(await provider.tileBytes(z, x, y), isNotNull,
              reason: 'z$z/x$x/y$y');
        }
      }
    });

    test('a tile outside the world resolves to null, not an error', () async {
      // flutter_map requests tiles speculatively past the edges of the world.
      expect(await provider.tileBytes(0, 1, 0), isNull);
      expect(await provider.tileBytes(0, 0, 1), isNull);
      expect(await provider.tileBytes(5, 32, 0), isNull);
      expect(await provider.tileBytes(5, -1, 0), isNull);
      expect(await provider.tileBytes(9, 0, 0), isNull,
          reason: 'beyond the bundled zoom ceiling');
    });
  });

  group('the TMS row flip', () {
    test('north and south are not interchangeable', () async {
      // At zoom 1 the two rows are the northern and southern hemispheres, and
      // they look different. If the flip were dropped or applied twice, these
      // would come back swapped -- which is invisible in a single tile and
      // obvious only against a real coastline.
      final north = await provider.tileBytes(1, 0, 0);
      final south = await provider.tileBytes(1, 0, 1);
      expect(north, isNotNull);
      expect(south, isNotNull);
      expect(north, isNot(south));
    });

    test('agrees with the builder for the verified Europe tile', () async {
      // tools/README.md records that zoom 4, column 8, TMS row 10 shows
      // Britain, the Alps and Italy. In slippy-map terms that is y = 5.
      final viaProvider = await provider.tileBytes(4, 8, 5);
      expect(viaProvider, isNotNull);

      final db = await databaseFactoryFfi.openDatabase(
        p.absolute('assets/map/basemap.mbtiles'),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      addTearDown(db.close);
      final rows = await db.rawQuery(
        'SELECT tile_data FROM tiles '
        'WHERE zoom_level = 4 AND tile_column = 8 AND tile_row = 10',
      );
      expect(rows, hasLength(1));
      expect(viaProvider, rows.first['tile_data']);
    });
  });

  group('the archive is the one the builder produced', () {
    late Database db;

    setUpAll(() async {
      db = await databaseFactoryFfi.openDatabase(
        p.absolute('assets/map/basemap.mbtiles'),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
    });

    tearDownAll(() async => db.close());

    test('holds exactly 1365 tiles across zoom 0 to 5', () async {
      final total = await db.rawQuery('SELECT count(*) AS n FROM tiles');
      expect(total.first['n'], 1365);

      final byZoom = await db.rawQuery(
        'SELECT zoom_level AS z, count(*) AS n FROM tiles '
        'GROUP BY zoom_level ORDER BY zoom_level',
      );
      expect(
        byZoom.map((r) => r['n']).toList(),
        [1, 4, 16, 64, 256, 1024],
      );
    });

    test('declares the metadata the map widget relies on', () async {
      final rows = await db.rawQuery('SELECT name, value FROM metadata');
      final meta = {
        for (final r in rows) r['name'] as String: r['value'] as String,
      };

      expect(meta['format'], 'png');
      expect(meta['minzoom'], '0');
      expect(meta['maxzoom'], '5');
      expect(meta['type'], 'baselayer');
      // A licence obligation, carried in the archive itself so it travels with
      // the data. See NOTICE.md.
      expect(meta['attribution'], contains('Natural Earth'));
    });

    test('stays inside the Tier 1 size budget alongside places.db', () async {
      // NFR-3 caps the bundled payload at 60 MB.
      final basemap = await databaseFactoryFfi.databaseExists(
        p.absolute('assets/map/basemap.mbtiles'),
      );
      expect(basemap, isTrue);

      final basemapBytes =
          File(p.absolute('assets/map/basemap.mbtiles')).lengthSync();
      final placesBytes = File(p.absolute('assets/db/places.db')).lengthSync();
      final totalMb = (basemapBytes + placesBytes) / 1024 / 1024;

      // ignore: avoid_print
      print('NFR-3: Tier 1 payload ${totalMb.toStringAsFixed(2)} MB of 60 MB '
          '(basemap ${(basemapBytes / 1024 / 1024).toStringAsFixed(2)} MB, '
          'places ${(placesBytes / 1024 / 1024).toStringAsFixed(2)} MB)');

      expect(totalMb, lessThan(60.0));
    });
  });
}
