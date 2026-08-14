import 'dart:math' as math;

/// Web Mercator projection and slippy-map tile arithmetic.
///
/// Shared by the basemap builder and its tests. Kept free of any rendering or
/// I/O concern so the geometry can be checked on its own — a projection error
/// is invisible in a thumbnail and obvious only once the map is on a phone.

/// The latitude where Web Mercator is truncated to make the world square.
///
/// The projection sends the poles to infinity, so every slippy-map
/// implementation cuts it here. Antarctica is clipped as a result, which is
/// standard and matches what the map widget expects.
const double webMercatorMaxLatitude = 85.05112877980659;

/// Longitude to a fraction of the world's width, west to east.
double lonToWorldX(double lon) => (lon + 180.0) / 360.0;

/// Latitude to a fraction of the world's height, north to south.
double latToWorldY(double lat) {
  final clamped = lat.clamp(-webMercatorMaxLatitude, webMercatorMaxLatitude);
  final s = math.sin(clamped * math.pi / 180.0);
  return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
}

double worldXToLon(double x) => x * 360.0 - 180.0;

double worldYToLat(double y) {
  final n = math.pi * (1.0 - 2.0 * y);
  // atan(sinh(n)); Dart has no sinh.
  return 180.0 / math.pi * math.atan((math.exp(n) - math.exp(-n)) / 2.0);
}

/// Tiles per axis at [zoom].
int tilesPerAxis(int zoom) => 1 << zoom;

/// Total tiles from zoom 0 through [maxZoom] inclusive.
int totalTiles(int maxZoom) {
  var sum = 0;
  for (var z = 0; z <= maxZoom; z++) {
    final n = tilesPerAxis(z);
    sum += n * n;
  }
  return sum;
}

/// Converts an XYZ row index to the TMS row index MBTiles stores.
///
/// MBTiles numbers rows from the south, slippy-map XYZ from the north. Getting
/// this backwards renders the world upside down, and it is symmetric enough to
/// look plausible in a single tile, so it is tested rather than eyeballed.
int tmsRow(int zoom, int y) => tilesPerAxis(zoom) - 1 - y;

/// The geographic extent of one tile.
class TileBounds {
  const TileBounds({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });

  final double west;
  final double south;
  final double east;
  final double north;

  bool intersects(double minLon, double minLat, double maxLon, double maxLat) {
    return minLon <= east &&
        maxLon >= west &&
        minLat <= north &&
        maxLat >= south;
  }

  @override
  String toString() => 'TileBounds($west, $south, $east, $north)';
}

TileBounds tileBounds(int zoom, int x, int y) {
  final n = tilesPerAxis(zoom);
  return TileBounds(
    west: worldXToLon(x / n),
    east: worldXToLon((x + 1) / n),
    north: worldYToLat(y / n),
    south: worldYToLat((y + 1) / n),
  );
}

/// Projects a position into pixel coordinates within a tile.
///
/// Results outside `0..size` are expected and meaningful: geometry usually
/// extends past the tile it is being drawn into, and the rasteriser relies on
/// the true off-canvas coordinates to get the slope of an edge right at the
/// boundary.
class TileProjector {
  TileProjector({
    required this.zoom,
    required this.x,
    required this.y,
    required this.size,
  }) : _worldPixels = tilesPerAxis(zoom) * size.toDouble();

  final int zoom;
  final int x;
  final int y;
  final int size;
  final double _worldPixels;

  double projectX(double lon) => lonToWorldX(lon) * _worldPixels - x * size;

  double projectY(double lat) => latToWorldY(lat) * _worldPixels - y * size;
}
