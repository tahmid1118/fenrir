import 'dart:math' as math;

import 'database.dart';

import '../geo/haversine.dart';
import 'models.dart';

/// Resolves a position to the nearest populated place, entirely offline
/// (FR-3.1, FR-3.2, FR-3.3).
///
/// The bundled database has no R*Tree, and Android's system SQLite ships
/// without the maths functions, so `acos` is unavailable in SQL. Proximity is
/// therefore a two-stage query: an integer bounding box that the
/// `idx_place_lat` B-tree can serve, then haversine over the survivors in
/// Dart. `EXPLAIN QUERY PLAN` confirms the index is used rather than a scan of
/// all 235,242 rows.
class PlaceRepository {
  PlaceRepository(this._db);

  final Database _db;

  /// Opens the extracted database read-only.
  ///
  /// [factory] exists so tests can supply the FFI factory and run against the
  /// real shipped database on the desktop.
  static Future<PlaceRepository> openAt(
    String path, {
    DatabaseFactory? factory,
  }) async {
    final db = await (factory ?? appDatabaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    return PlaceRepository(db);
  }

  Future<void> close() => _db.close();

  /// Radii tried in turn, in kilometres.
  ///
  /// Starting small keeps the common case cheap: in a populated area the first
  /// box already contains the answer and returns a handful of rows. Only
  /// genuinely remote positions pay for the wider searches, and those are
  /// sparse by definition, so the work is self-balancing against NFR-2.
  ///
  /// The ceiling is what implements FR-3.3. It has to sit well below the
  /// distance to the nearest land from open ocean — the specification's
  /// mid-Atlantic fixture is 1,317 km from the nearest place — so that open
  /// water yields nothing rather than a confidently wrong match.
  static const List<double> searchRadiiKm = [25.0, 100.0, 250.0];

  /// Within this distance the user is described as being *in* the place,
  /// rather than *near* it.
  ///
  /// Was 5.0 km. A real user in Rampura/Banasree, Dhaka — neither of which is
  /// in the database, the exact coverage gap FR-3.4 exists to eventually fix —
  /// was resolved to Paltan at 3.458 km and shown "Paltan, Dhaka, Dhaka
  /// Division, BD" with no qualifier, reading as if they were standing in it.
  /// That is precisely the confidently-wrong failure FR-3.2 exists to prevent;
  /// it was just happening at city scale rather than the rural scale the
  /// specification's own worked example worries about.
  ///
  /// 2.0 km keeps the specification's flagship fixture — Dhanmondi at 1.29 km
  /// — solidly "inside", while the Paltan case above now correctly reads
  /// "Near Paltan". It is a flat number rather than one scaled by a place's
  /// population, which would size the radius to a big city's real footprint
  /// more honestly; that is future work, not a difference this fix depends on.
  static const double insideRadiusKm = 2.0;

  /// Kilometres per degree of latitude. Constant everywhere on a sphere.
  static const double _kmPerDegreeLat = 111.32;

  /// The nearest populated place, or null when there is none worth naming.
  ///
  /// Null is the explicit "no known place nearby" state FR-3.3 requires. It is
  /// not an error and not an empty match: the caller is forced by the type to
  /// handle it, which is what stops a distant false positive reaching the UI.
  Future<PlaceMatch?> nearestPlace(double latitude, double longitude) async {
    for (final radiusKm in searchRadiiKm) {
      final candidates = await _within(latitude, longitude, radiusKm);
      if (candidates.isEmpty) continue;

      var best = candidates.first;
      var bestDistance =
          distanceKm(latitude, longitude, best.latitude, best.longitude);
      for (final candidate in candidates.skip(1)) {
        final d = distanceKm(
          latitude,
          longitude,
          candidate.latitude,
          candidate.longitude,
        );
        if (d < bestDistance) {
          best = candidate;
          bestDistance = d;
        }
      }

      // The box is a square, so its corners reach further than `radiusKm`. A
      // nearest candidate beyond that radius proves nothing was found inside
      // it, but does not prove this candidate is the nearest overall -- there
      // could be a closer one just outside a shorter edge. Widening settles
      // it. Only a result within the radius is provably correct.
      if (bestDistance <= radiusKm) {
        return PlaceMatch(
          place: best,
          distanceKm: bestDistance,
          proximity: bestDistance <= insideRadiusKm
              ? Proximity.inside
              : Proximity.near,
        );
      }
    }
    return null;
  }

  /// Full-text search across place names (FR-8.1).
  ///
  /// Uses the `place_fts` index that already ships in the database and was,
  /// until now, 5.3 MB of the bundle doing nothing.
  ///
  /// Results are ordered by population rather than by relevance score alone.
  /// Every hit matches the typed prefix equally well as far as bm25 is
  /// concerned, so a raw rank ordering puts hamlets above capitals; someone
  /// typing "paris" almost always means the large one. An exact name match is
  /// promoted above all of them.
  ///
  /// [fromLatitude] and [fromLongitude] are optional: searching before the
  /// receiver has a fix is a normal thing to do, and the results are still
  /// useful without a distance.
  Future<List<PlaceSearchResult>> searchPlaces(
    String query, {
    double? fromLatitude,
    double? fromLongitude,
    int limit = 30,
  }) async {
    final expression = buildMatchExpression(query);
    if (expression == null) return const [];

    final rows = await _db.rawQuery(
      'SELECT p.id, p.name, p.admin1, p.admin2, p.country, '
      'p.lat_e5, p.lon_e5, p.pop, p.tz '
      'FROM place_fts f JOIN place p ON p.id = f.rowid '
      'WHERE place_fts MATCH ? '
      'ORDER BY (CASE WHEN lower(p.name) = ? THEN 0 ELSE 1 END), '
      'p.pop DESC '
      'LIMIT ?',
      [expression, query.trim().toLowerCase(), limit],
    );

    final hasOrigin = fromLatitude != null && fromLongitude != null;
    return rows.map((row) {
      final place = Place.fromRow(row);
      return PlaceSearchResult(
        place: place,
        distanceKm: hasOrigin
            ? distanceKm(
                fromLatitude,
                fromLongitude,
                place.latitude,
                place.longitude,
              )
            : null,
        bearingDeg: hasOrigin
            ? bearingDeg(
                fromLatitude,
                fromLongitude,
                place.latitude,
                place.longitude,
              )
            : null,
      );
    }).toList();
  }

  /// Turns typed text into a safe FTS5 MATCH expression.
  ///
  /// FTS5 has its own query language, and characters a user types perfectly
  /// reasonably — quotes, asterisks, hyphens, colons, parentheses, the words
  /// AND, OR and NOT — are operators in it. Passing raw input through throws a
  /// syntax error, which for a search box means every apostrophe crashes the
  /// screen. Each token is therefore quoted, which makes it a literal, and
  /// given a trailing `*` so the search matches as the user is still typing.
  ///
  /// Returns null when nothing searchable remains.
  ///
  /// Exposed for testing: this is the boundary where hostile input meets a
  /// query parser.
  static String? buildMatchExpression(String query) {
    final tokens = query
        // Anything that is not a letter, digit or mark is a separator. This
        // keeps accented and non-Latin characters, which matter for a database
        // where names like Şobḩān and 上海 are ordinary.
        .split(RegExp(r'[^\p{L}\p{N}\p{M}]+', unicode: true))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return null;

    // Double quotes cannot appear after the split above, so quoting is safe
    // without further escaping.
    return tokens.map((t) => '"$t"*').join(' ');
  }

  /// Rows whose coordinates fall inside the bounding box around a position.
  Future<List<Place>> _within(
    double latitude,
    double longitude,
    double radiusKm,
  ) async {
    final rows = <Map<String, Object?>>[];
    for (final box in boundingBoxes(latitude, longitude, radiusKm)) {
      rows.addAll(await _db.rawQuery(
        'SELECT id, name, admin1, admin2, country, lat_e5, lon_e5, pop, tz '
        'FROM place '
        'WHERE lat_e5 BETWEEN ? AND ? AND lon_e5 BETWEEN ? AND ?',
        [box.minLatE5, box.maxLatE5, box.minLonE5, box.maxLonE5],
      ));
    }
    return rows.map(Place.fromRow).toList();
  }

  /// The integer bounding box or boxes covering [radiusKm] around a position.
  ///
  /// Returns two boxes when the span crosses the antimeridian, because
  /// `lon_e5 BETWEEN` cannot express a wrapped range — a single box from
  /// +179 to -179 selects nothing, silently reporting no place nearby for
  /// anyone near the 180th meridian.
  ///
  /// Exposed for testing: the geometry is easy to get wrong in ways that only
  /// show up in places nobody visits during development.
  static List<GeoBoundingBox> boundingBoxes(
    double latitude,
    double longitude,
    double radiusKm,
  ) {
    final dLat = radiusKm / _kmPerDegreeLat;
    final minLat = (latitude - dLat).clamp(-90.0, 90.0);
    final maxLat = (latitude + dLat).clamp(-90.0, 90.0);

    // Longitude lines converge toward the poles, so the span in degrees is
    // widest at whichever edge of the box lies closest to a pole. Using that
    // edge makes the box over-cover rather than under-cover, which is the safe
    // direction: a box that is too big costs a few extra rows, one that is too
    // small silently loses the correct answer.
    final polewardLat = math.max(minLat.abs(), maxLat.abs());
    final cosLat = math.cos(polewardLat * math.pi / 180.0);

    // Near the poles cosLat approaches zero and the span exceeds the globe.
    // Scanning every longitude is then both correct and cheap, since there is
    // very little at those latitudes.
    if (cosLat <= 0.0) {
      return [_box(minLat, maxLat, -180.0, 180.0)];
    }
    final dLon = radiusKm / (_kmPerDegreeLat * cosLat);
    if (dLon >= 180.0) {
      return [_box(minLat, maxLat, -180.0, 180.0)];
    }

    final minLon = longitude - dLon;
    final maxLon = longitude + dLon;

    if (minLon < -180.0) {
      return [
        _box(minLat, maxLat, -180.0, maxLon),
        _box(minLat, maxLat, minLon + 360.0, 180.0),
      ];
    }
    if (maxLon > 180.0) {
      return [
        _box(minLat, maxLat, minLon, 180.0),
        _box(minLat, maxLat, -180.0, maxLon - 360.0),
      ];
    }
    return [_box(minLat, maxLat, minLon, maxLon)];
  }

  static GeoBoundingBox _box(
    double minLat,
    double maxLat,
    double minLon,
    double maxLon,
  ) {
    return GeoBoundingBox(
      minLatE5: (minLat * 100000).floor(),
      maxLatE5: (maxLat * 100000).ceil(),
      minLonE5: (minLon * 100000).floor(),
      maxLonE5: (maxLon * 100000).ceil(),
    );
  }
}

/// A bounding box in the integer coordinate space the database stores.
class GeoBoundingBox {
  const GeoBoundingBox({
    required this.minLatE5,
    required this.maxLatE5,
    required this.minLonE5,
    required this.maxLonE5,
  });

  final int minLatE5;
  final int maxLatE5;
  final int minLonE5;
  final int maxLonE5;

  @override
  String toString() =>
      'GeoBoundingBox(lat $minLatE5..$maxLatE5, lon $minLonE5..$maxLonE5)';
}
