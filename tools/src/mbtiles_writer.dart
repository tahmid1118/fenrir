import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'mercator.dart';

/// Writes an MBTiles 1.3 archive.
///
/// MBTiles is a SQLite database, which is why it was chosen over PMTiles for
/// this project: the whole container can be produced from Dart with no external
/// toolchain, on a machine with no Python, GDAL or mapnik installed.
class MbTilesWriter {
  MbTilesWriter._(this._db);

  final Database _db;

  static Future<MbTilesWriter> create(
    String path, {
    required String name,
    required String description,
    required String attribution,
    required int minZoom,
    required int maxZoom,
  }) async {
    sqfliteFfiInit();
    // Must be absolute. A relative path is resolved against the package's own
    // .dart_tool databases directory rather than the working directory, so the
    // archive silently lands somewhere nobody is looking for it.
    final db = await databaseFactoryFfi.openDatabase(
      p.absolute(path),
      options: OpenDatabaseOptions(singleInstance: false),
    );

    await db.execute('CREATE TABLE metadata (name TEXT, value TEXT)');
    await db.execute(
      'CREATE TABLE tiles ('
      'zoom_level INTEGER, tile_column INTEGER, '
      'tile_row INTEGER, tile_data BLOB)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX tile_index ON tiles '
      '(zoom_level, tile_column, tile_row)',
    );

    final metadata = <String, String>{
      'name': name,
      'description': description,
      'attribution': attribution,
      'format': 'png',
      'type': 'baselayer',
      'version': '1.0.0',
      'minzoom': '$minZoom',
      'maxzoom': '$maxZoom',
      // The full Web Mercator extent, truncated at the latitude where the
      // projection is cut.
      'bounds': '-180.0,-$webMercatorMaxLatitude,180.0,$webMercatorMaxLatitude',
      'center': '0.0,0.0,$minZoom',
    };
    final batch = db.batch();
    metadata.forEach((k, v) {
      batch.insert('metadata', {'name': k, 'value': v});
    });
    await batch.commit(noResult: true);

    return MbTilesWriter._(db);
  }

  Batch? _batch;

  /// Adds a tile, converting the XYZ row index to the TMS one MBTiles stores.
  ///
  /// This conversion is the single most consequential line in the writer: get
  /// it backwards and the entire world renders upside down, which is symmetric
  /// enough to look plausible until a coastline is compared against reality.
  void addTile({
    required int zoom,
    required int x,
    required int y,
    required Uint8List png,
  }) {
    final batch = _batch ??= _db.batch();
    batch.insert('tiles', {
      'zoom_level': zoom,
      'tile_column': x,
      'tile_row': tmsRow(zoom, y),
      'tile_data': png,
    });
  }

  Future<void> flush() async {
    final batch = _batch;
    if (batch == null) return;
    await batch.commit(noResult: true);
    _batch = null;
  }

  Future<void> close() async {
    await flush();
    // Reclaims the free pages left by the write, which matters against the
    // NFR-3 size budget.
    await _db.execute('VACUUM');
    await _db.close();
  }
}
