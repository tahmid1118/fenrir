import 'dart:math' as math;
import 'dart:typed_data';

import '../data/database.dart';

/// One MBTiles file, opened read-only.
///
/// Knows the zoom range and geographic extent it covers, so a caller holding
/// several archives can skip the ones that cannot possibly contain a tile
/// instead of querying each in turn. With a Tier 1 basemap and several regional
/// packs installed, that is the difference between one query per tile and one
/// per archive per tile.
class MbTilesArchive {
  MbTilesArchive._(this._db, this.metadata);

  final Database _db;
  final MbTilesMetadata metadata;

  static Future<MbTilesArchive> openAt(
    String path, {
    DatabaseFactory? factory,
  }) async {
    final db = await (factory ?? appDatabaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    return MbTilesArchive._(db, await MbTilesMetadata.read(db));
  }

  /// Whether this archive could hold the given tile.
  ///
  /// A cheap rejection: zoom range first, then the bounding box. Wrong only in
  /// the conservative direction — it may say yes for a tile the archive does
  /// not actually contain, which costs one query, but never says no for a tile
  /// it does.
  bool covers(int zoom, int x, int y) {
    if (zoom < metadata.minZoom || zoom > metadata.maxZoom) return false;
    return metadata.bounds?.containsTile(zoom, x, y) ?? true;
  }

  /// Reads one tile, or null when the archive has no such tile.
  ///
  /// [y] is a slippy-map row, counted from the north; MBTiles stores rows from
  /// the south, so it is flipped here.
  Future<Uint8List?> tileBytes(int zoom, int x, int y) async {
    final rows = await _db.rawQuery(
      'SELECT tile_data FROM tiles '
      'WHERE zoom_level = ? AND tile_column = ? AND tile_row = ? LIMIT 1',
      [zoom, x, (1 << zoom) - 1 - y],
    );
    if (rows.isEmpty) return null;
    return rows.first['tile_data'] as Uint8List?;
  }

  Future<int> tileCount() async {
    final rows = await _db.rawQuery('SELECT count(*) AS n FROM tiles');
    return rows.first['n']! as int;
  }

  Future<void> close() => _db.close();
}

/// What an MBTiles file says about itself.
class MbTilesMetadata {
  const MbTilesMetadata({
    required this.name,
    required this.format,
    required this.minZoom,
    required this.maxZoom,
    this.bounds,
    this.attribution,
  });

  final String name;
  final String format;
  final int minZoom;
  final int maxZoom;
  final GeoBounds? bounds;
  final String? attribution;

  static Future<MbTilesMetadata> read(Database db) async {
    final rows = await db.rawQuery('SELECT name, value FROM metadata');
    final map = {
      for (final r in rows) r['name'] as String: r['value'] as String?,
    };

    return MbTilesMetadata(
      name: map['name'] ?? 'Unnamed',
      format: map['format'] ?? 'png',
      // A file that omits its zoom range is treated as covering everything
      // rather than nothing: refusing to read it would be a worse failure than
      // querying it needlessly.
      minZoom: int.tryParse(map['minzoom'] ?? '') ?? 0,
      maxZoom: int.tryParse(map['maxzoom'] ?? '') ?? 22,
      bounds: GeoBounds.parse(map['bounds']),
      attribution: map['attribution'],
    );
  }

  @override
  String toString() => 'MbTilesMetadata($name, z$minZoom-$maxZoom)';
}

/// A west, south, east, north extent in degrees.
class GeoBounds {
  const GeoBounds({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });

  final double west;
  final double south;
  final double east;
  final double north;

  /// Parses the MBTiles `bounds` field, `west,south,east,north`.
  static GeoBounds? parse(String? value) {
    if (value == null) return null;
    final parts = value.split(',').map((p) => double.tryParse(p.trim())).toList();
    if (parts.length != 4 || parts.any((p) => p == null)) return null;
    return GeoBounds(
      west: parts[0]!,
      south: parts[1]!,
      east: parts[2]!,
      north: parts[3]!,
    );
  }

  /// Whether a slippy-map tile overlaps this extent.
  bool containsTile(int zoom, int x, int y) {
    final n = 1 << zoom;
    if (x < 0 || y < 0 || x >= n || y >= n) return false;

    final tileWest = x / n * 360.0 - 180.0;
    final tileEast = (x + 1) / n * 360.0 - 180.0;
    final tileNorth = _latitudeAt(y / n);
    final tileSouth = _latitudeAt((y + 1) / n);

    return tileWest <= east &&
        tileEast >= west &&
        tileSouth <= north &&
        tileNorth >= south;
  }

  /// Inverse Web Mercator: a world-Y fraction back to a latitude.
  static double _latitudeAt(double worldY) {
    final n = math.pi * (1 - 2 * worldY);
    // atan(sinh(n)); Dart has no sinh.
    return 180.0 / math.pi * math.atan((math.exp(n) - math.exp(-n)) / 2);
  }

  @override
  String toString() => 'GeoBounds($west, $south, $east, $north)';
}
