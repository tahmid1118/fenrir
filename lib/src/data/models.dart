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

/// A position the user chose to keep (FR-6.1).
///
/// Everything the requirement asks for is captured at the moment of saving:
/// the position, when it was taken, how accurate it was, the resolved place
/// name, and an optional note.
///
/// The place name is stored rather than re-resolved on display. It is what the
/// user saw when they decided this spot was worth keeping, and a later database
/// rebuild could otherwise silently rename their waypoint.
@immutable
class Waypoint {
  const Waypoint({
    this.id,
    this.label,
    this.note,
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    this.altitudeMeters,
    this.placeName,
    required this.savedAt,
  });

  /// Null until the row has been written.
  final int? id;

  /// What the user called it. Null means it is shown by place or coordinates.
  final String? label;

  final String? note;

  final double latitude;
  final double longitude;

  /// The accuracy radius at the moment of saving.
  ///
  /// Kept because a waypoint recorded with a 200 metre fix is a different
  /// thing from one recorded with a 4 metre fix, and FR-1.2's honesty applies
  /// just as much afterwards as it does live.
  final double accuracyMeters;

  final double? altitudeMeters;

  /// The resolved place name as it stood when this was saved.
  final String? placeName;

  final DateTime savedAt;

  /// What to show as the primary name, in order of what the user will
  /// recognise.
  String get displayLabel {
    final chosen = label?.trim();
    if (chosen != null && chosen.isNotEmpty) return chosen;
    final place = placeName?.trim();
    if (place != null && place.isNotEmpty) return place;
    return '${latitude.toStringAsFixed(5)}, '
        '${longitude.toStringAsFixed(5)}';
  }

  Waypoint copyWith({int? id, String? label, String? note}) {
    return Waypoint(
      id: id ?? this.id,
      label: label ?? this.label,
      note: note ?? this.note,
      latitude: latitude,
      longitude: longitude,
      accuracyMeters: accuracyMeters,
      altitudeMeters: altitudeMeters,
      placeName: placeName,
      savedAt: savedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Waypoint &&
          id == other.id &&
          label == other.label &&
          note == other.note &&
          latitude == other.latitude &&
          longitude == other.longitude &&
          accuracyMeters == other.accuracyMeters &&
          altitudeMeters == other.altitudeMeters &&
          placeName == other.placeName &&
          savedAt == other.savedAt);

  @override
  int get hashCode => Object.hash(
        id,
        label,
        note,
        latitude,
        longitude,
        accuracyMeters,
        altitudeMeters,
        placeName,
        savedAt,
      );

  @override
  String toString() => 'Waypoint($id, $displayLabel)';
}

/// A search hit, with how far away it is from wherever the user is now.
///
/// FR-8.1 asks for distance and bearing alongside each result. Both are null
/// when there is no fix to measure from — searching before the receiver has
/// locked on is a normal thing to do, and the results are still useful.
@immutable
class PlaceSearchResult {
  const PlaceSearchResult({
    required this.place,
    this.distanceKm,
    this.bearingDeg,
  });

  final Place place;

  /// Great-circle distance from the current position, in kilometres.
  final double? distanceKm;

  /// Initial bearing from the current position, degrees clockwise from north.
  final double? bearingDeg;

  /// The bearing as a compass point, which is what a person can act on.
  ///
  /// "NNE" is directly usable standing in a field; "22 degrees" is not.
  String? get compassPoint {
    final bearing = bearingDeg;
    if (bearing == null) return null;
    const points = [
      'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', //
      'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW',
    ];
    return points[(((bearing % 360) / 22.5) + 0.5).floor() % 16];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaceSearchResult &&
          place == other.place &&
          distanceKm == other.distanceKm &&
          bearingDeg == other.bearingDeg);

  @override
  int get hashCode => Object.hash(place, distanceKm, bearingDeg);

  @override
  String toString() => 'PlaceSearchResult(${place.displayName})';
}
