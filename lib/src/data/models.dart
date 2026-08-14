import 'package:meta/meta.dart';

/// A populated place from the bundled GeoNames-derived database.
///
/// The table is fully denormalised — there are no lookup tables for country or
/// administrative divisions — so every field here comes from a single row.
@immutable
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.admin1,
    required this.admin2,
    required this.country,
    required this.latitude,
    required this.longitude,
    required this.population,
    required this.timeZone,
  });

  /// GeoNames identifier. Sparse, not a row number.
  final int id;

  final String name;

  /// First-level division, stored as a display name rather than a code, e.g.
  /// `Dhaka Division`. Null for 462 rows.
  final String? admin1;

  /// Second-level division, e.g. `Dhaka`. Null for 33,521 rows, so it can
  /// never be assumed present.
  final String? admin2;

  /// ISO 3166-1 alpha-2 country code.
  final String country;

  final double latitude;
  final double longitude;

  /// Population. Never null, but zero for 30,661 rows.
  final int population;

  /// IANA time zone name.
  final String timeZone;

  /// Builds a place from a database row.
  ///
  /// Coordinates are stored as degrees multiplied by 100,000 and held as
  /// integers, which is what lets the proximity index be a plain B-tree.
  factory Place.fromRow(Map<String, Object?> row) {
    return Place(
      id: row['id']! as int,
      name: row['name']! as String,
      admin1: row['admin1'] as String?,
      admin2: row['admin2'] as String?,
      country: row['country']! as String,
      latitude: (row['lat_e5']! as int) / 100000.0,
      longitude: (row['lon_e5']! as int) / 100000.0,
      population: (row['pop'] as int?) ?? 0,
      timeZone: (row['tz'] as String?) ?? '',
    );
  }

  /// The administrative hierarchy FR-3.1 asks for, e.g.
  /// `Dhanmondi, Dhaka, Dhaka Division, BD`.
  ///
  /// Null components are dropped, and a component identical to the one before
  /// it is dropped too — Dhaka city carries `Dhaka` as both its own name and
  /// its second-level division, and `Dhaka, Dhaka, Dhaka Division, BD` reads
  /// like a bug. Only exact repeats are collapsed: `Dhaka` and `Dhaka
  /// Division` are different places and both survive.
  String get displayName {
    final parts = <String>[];
    for (final component in [name, admin2, admin1, country]) {
      if (component == null || component.isEmpty) continue;
      if (parts.isNotEmpty && parts.last == component) continue;
      parts.add(component);
    }
    return parts.join(', ');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Place && id == other.id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Place($id, $displayName)';
}

/// How confidently a resolved place can be said to describe where the user is.
///
/// The distinction exists because of the coverage gap measured in the
/// requirements: Bangladesh has 161 places to the United States' 21,782, so a
/// rural user can easily be tens of kilometres from the nearest one. Saying
/// they are *in* that place would be confidently wrong, which is exactly the
/// failure FR-3.2 exists to prevent.
enum Proximity {
  /// Close enough to name without qualification.
  inside,

  /// The nearest known place, but far enough that the user is beside it rather
  /// than in it.
  near,
}

/// A resolved place together with how far away it actually is.
@immutable
class PlaceMatch {
  const PlaceMatch({
    required this.place,
    required this.distanceKm,
    required this.proximity,
  });

  final Place place;

  /// Great-circle distance from the queried position, in kilometres.
  final double distanceKm;

  final Proximity proximity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaceMatch &&
          place == other.place &&
          distanceKm == other.distanceKm &&
          proximity == other.proximity);

  @override
  int get hashCode => Object.hash(place, distanceKm, proximity);

  @override
  String toString() =>
      'PlaceMatch(${place.displayName}, '
      '${distanceKm.toStringAsFixed(2)} km, ${proximity.name})';
}
