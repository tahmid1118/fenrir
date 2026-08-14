import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A minimal GeoJSON reader for the Natural Earth layers the basemap needs.
///
/// Only the geometry types those layers actually use are handled — Polygon,
/// MultiPolygon, LineString, MultiLineString. Properties are ignored entirely:
/// at zoom 0 to 5 nothing is labelled or styled per feature, so parsing them
/// would be work with no output.
///
/// Coordinates are kept in flat `Float64List`s rather than lists of point
/// objects. Every ring is walked once per tile it touches, and at 1,365 tiles
/// the allocation churn of boxed points is the difference between a build that
/// takes seconds and one that takes minutes.

/// A closed ring, plus the bounding box used to skip it cheaply.
class GeoRing {
  GeoRing(this.coordinates)
      : minLon = _min(coordinates, 0),
        maxLon = _max(coordinates, 0),
        minLat = _min(coordinates, 1),
        maxLat = _max(coordinates, 1);

  /// Flat `[lon0, lat0, lon1, lat1, ...]`.
  final Float64List coordinates;

  final double minLon;
  final double maxLon;
  final double minLat;
  final double maxLat;

  int get pointCount => coordinates.length ~/ 2;

  static double _min(Float64List c, int offset) {
    var v = double.infinity;
    for (var i = offset; i < c.length; i += 2) {
      if (c[i] < v) v = c[i];
    }
    return v;
  }

  static double _max(Float64List c, int offset) {
    var v = double.negativeInfinity;
    for (var i = offset; i < c.length; i += 2) {
      if (c[i] > v) v = c[i];
    }
    return v;
  }
}

/// A polygon with its holes, carrying a combined bounding box.
class GeoPolygon {
  GeoPolygon(this.exterior, this.holes);

  final GeoRing exterior;
  final List<GeoRing> holes;

  double get minLon => exterior.minLon;
  double get maxLon => exterior.maxLon;
  double get minLat => exterior.minLat;
  double get maxLat => exterior.maxLat;

  int get pointCount =>
      exterior.pointCount +
      holes.fold(0, (sum, hole) => sum + hole.pointCount);
}

/// Everything read out of one GeoJSON file.
class GeoLayer {
  GeoLayer({required this.polygons, required this.lines});

  final List<GeoPolygon> polygons;
  final List<GeoRing> lines;

  int get pointCount =>
      polygons.fold(0, (s, p) => s + p.pointCount) +
      lines.fold(0, (s, l) => s + l.pointCount);

  static GeoLayer read(String path) {
    final raw = File(path).readAsStringSync();
    final root = jsonDecode(raw) as Map<String, Object?>;
    final features = (root['features'] as List<Object?>?) ?? const [];

    final polygons = <GeoPolygon>[];
    final lines = <GeoRing>[];

    for (final feature in features) {
      final geometry =
          (feature as Map<String, Object?>)['geometry'] as Map<String, Object?>?;
      if (geometry == null) continue;

      final type = geometry['type'] as String?;
      final coordinates = geometry['coordinates'] as List<Object?>?;
      if (type == null || coordinates == null) continue;

      switch (type) {
        case 'Polygon':
          final polygon = _polygon(coordinates);
          if (polygon != null) polygons.add(polygon);
        case 'MultiPolygon':
          for (final part in coordinates) {
            final polygon = _polygon(part as List<Object?>);
            if (polygon != null) polygons.add(polygon);
          }
        case 'LineString':
          final ring = _ring(coordinates);
          if (ring != null) lines.add(ring);
        case 'MultiLineString':
          for (final part in coordinates) {
            final ring = _ring(part as List<Object?>);
            if (ring != null) lines.add(ring);
          }
        default:
          // Points and geometry collections do not appear in these layers and
          // would contribute nothing to render if they did.
          break;
      }
    }

    return GeoLayer(polygons: polygons, lines: lines);
  }

  static GeoPolygon? _polygon(List<Object?> rings) {
    if (rings.isEmpty) return null;
    final exterior = _ring(rings.first as List<Object?>);
    if (exterior == null) return null;

    final holes = <GeoRing>[];
    for (var i = 1; i < rings.length; i++) {
      final hole = _ring(rings[i] as List<Object?>);
      if (hole != null) holes.add(hole);
    }
    return GeoPolygon(exterior, holes);
  }

  static GeoRing? _ring(List<Object?> points) {
    if (points.length < 2) return null;
    final flat = Float64List(points.length * 2);
    for (var i = 0; i < points.length; i++) {
      final point = points[i] as List<Object?>;
      flat[i * 2] = (point[0] as num).toDouble();
      flat[i * 2 + 1] = (point[1] as num).toDouble();
    }
    return GeoRing(flat);
  }
}
