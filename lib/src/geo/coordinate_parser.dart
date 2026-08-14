import 'package:geobase/geobase.dart';
import 'package:meta/meta.dart';

import 'coordinate_formats.dart';
import 'plus_code.dart';

/// Parses a position out of text the user pasted or typed (FR-8.2).
///
/// The requirement is to accept "a pasted coordinate or Plus Code in any
/// supported format". In practice that means whatever another app put on the
/// clipboard, so the parser is deliberately forgiving about separators,
/// symbols and spacing, and strict about the one thing that matters: never
/// silently returning the wrong point.
///
/// Ambiguity is resolved by refusing rather than guessing. `48 2` could be
/// latitude and longitude, or a UTM zone; a wrong answer here puts a user
/// somewhere they are not.

/// A successfully parsed position.
@immutable
class ParsedCoordinate {
  const ParsedCoordinate({
    required this.latitude,
    required this.longitude,
    required this.format,
    this.plusCodeArea,
  });

  final double latitude;
  final double longitude;

  /// Which notation the text turned out to be in, for confirming back to the
  /// user what was understood.
  final CoordinateFormat format;

  /// Present when the input was a Plus Code: codes name areas rather than
  /// points, and the area is worth keeping so the map can show it honestly.
  final PlusCodeArea? plusCodeArea;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ParsedCoordinate &&
          latitude == other.latitude &&
          longitude == other.longitude &&
          format == other.format);

  @override
  int get hashCode => Object.hash(latitude, longitude, format);

  @override
  String toString() =>
      'ParsedCoordinate($latitude, $longitude, ${format.name})';
}

/// Attempts to read a position from [input]. Returns null if it cannot.
ParsedCoordinate? parseCoordinate(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  // Order matters. Plus Codes and MGRS have distinctive shapes and are tested
  // first; degree forms are the most permissive and would otherwise swallow
  // input meant for the others.
  return _tryPlusCode(text) ??
      _tryMgrs(text) ??
      _tryUtm(text) ??
      _tryDms(text) ??
      _tryDecimalDegrees(text);
}

ParsedCoordinate? _tryPlusCode(String text) {
  final candidate = text.toUpperCase().replaceAll(RegExp(r'\s+'), '');
  if (!candidate.contains('+')) return null;
  if (!isFullPlusCode(candidate)) return null;

  try {
    final area = decodePlusCode(candidate);
    return ParsedCoordinate(
      latitude: area.latitudeCenter,
      longitude: area.longitudeCenter,
      format: CoordinateFormat.plusCode,
      plusCodeArea: area,
    );
  } on PlusCodeException {
    return null;
  }
}

/// MGRS, e.g. `31U DQ 48251 11932` or `31UDQ4825111932`.
ParsedCoordinate? _tryMgrs(String text) {
  final compact = text.toUpperCase().replaceAll(RegExp(r'\s+'), '');
  // Zone (1-2 digits), band letter, two grid letters, then an even number of
  // digits. Requiring the digits rules out a bare grid square, which names an
  // area 100 km across and is not a position.
  if (!RegExp(r'^\d{1,2}[C-HJ-NP-X][A-HJ-NP-Z]{2}\d{2,10}$')
      .hasMatch(compact)) {
    return null;
  }
  if (compact.replaceFirst(RegExp(r'^\d{1,2}[A-Z]{3}'), '').length.isOdd) {
    return null;
  }

  try {
    final geographic = Mgrs.parse(compact).toUtm().toGeographic();
    return ParsedCoordinate(
      latitude: geographic.lat,
      longitude: geographic.lon,
      format: CoordinateFormat.mgrs,
    );
  } on Object {
    return null;
  }
}

/// UTM, e.g. `31 N 448252 5411933`.
ParsedCoordinate? _tryUtm(String text) {
  final match = RegExp(
    r'^(\d{1,2})\s*([NS])\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)$',
    caseSensitive: false,
  ).firstMatch(text.trim());
  if (match == null) return null;

  // Easting and northing are metres and always large. Requiring that keeps
  // "31 N 4 5" from being read as a position rather than rejected.
  final easting = double.parse(match.group(3)!);
  final northing = double.parse(match.group(4)!);
  if (easting < 100000 || easting > 999999) return null;

  try {
    final geographic = Utm(
      int.parse(match.group(1)!),
      match.group(2)!.toUpperCase(),
      easting,
      northing,
    ).toGeographic();
    return ParsedCoordinate(
      latitude: geographic.lat,
      longitude: geographic.lon,
      format: CoordinateFormat.utm,
    );
  } on Object {
    return null;
  }
}

/// Degrees and minutes, with or without seconds, in either order of hemisphere
/// marker. Accepts `23°44'46.0"N, 90°22'27.1"E` and the many ways a keyboard
/// without those symbols renders it.
ParsedCoordinate? _tryDms(String text) {
  // The minute marker is optional and separate from the seconds group. Tying
  // them together means that in a degrees-and-decimal-minutes reading such as
  // 23°44.767'N -- the form marine and aviation charts use -- the apostrophe
  // is left unconsumed and the hemisphere letter is never reached.
  final pattern = RegExp(
    r'''(\d{1,3})\s*[°d:\s]\s*(\d{1,2}(?:\.\d+)?)\s*['m:\u2032]?\s*'''
    r'''(?:(\d{1,2}(?:\.\d+)?)\s*(?:["s\u2033\u201d]|'')?)?\s*([NSEW])''',
    caseSensitive: false,
  );

  final matches = pattern.allMatches(text).toList();
  if (matches.length != 2) return null;

  double? latitude;
  double? longitude;

  for (final m in matches) {
    final degrees = double.parse(m.group(1)!);
    final minutes = double.parse(m.group(2)!);
    final seconds = m.group(3) == null ? 0.0 : double.parse(m.group(3)!);
    if (minutes >= 60 || seconds >= 60) return null;

    final hemisphere = m.group(4)!.toUpperCase();
    var value = degrees + minutes / 60 + seconds / 3600;
    if (hemisphere == 'S' || hemisphere == 'W') value = -value;

    if (hemisphere == 'N' || hemisphere == 'S') {
      if (latitude != null || value.abs() > 90) return null;
      latitude = value;
    } else {
      if (longitude != null || value.abs() > 180) return null;
      longitude = value;
    }
  }

  if (latitude == null || longitude == null) return null;
  return ParsedCoordinate(
    latitude: latitude,
    longitude: longitude,
    format: CoordinateFormat.degreesMinutesSeconds,
  );
}

/// Signed or hemisphere-suffixed decimal degrees: `23.7461, 90.3742`,
/// `23.7461N 90.3742E`, `23.7461° 90.3742°`.
ParsedCoordinate? _tryDecimalDegrees(String text) {
  final cleaned = text.replaceAll('°', ' ').trim();

  // Hemisphere-suffixed first, since it states which value is which.
  final suffixed = RegExp(
    r'^\s*(-?\d{1,3}(?:\.\d+)?)\s*([NS])\s*[, ]\s*'
    r'(-?\d{1,3}(?:\.\d+)?)\s*([EW])\s*$',
    caseSensitive: false,
  ).firstMatch(cleaned);
  if (suffixed != null) {
    var lat = double.parse(suffixed.group(1)!);
    var lon = double.parse(suffixed.group(3)!);
    if (suffixed.group(2)!.toUpperCase() == 'S') lat = -lat;
    if (suffixed.group(4)!.toUpperCase() == 'W') lon = -lon;
    return _validated(lat, lon);
  }

  // Bare pair. A comma, whitespace or a semicolon may separate them.
  final bare = RegExp(
    r'^\s*(-?\d{1,3}(?:\.\d+)?)\s*[,;\s]\s*(-?\d{1,3}(?:\.\d+)?)\s*$',
  ).firstMatch(cleaned);
  if (bare == null) return null;

  return _validated(
    double.parse(bare.group(1)!),
    double.parse(bare.group(2)!),
  );
}

ParsedCoordinate? _validated(double latitude, double longitude) {
  // Out of range is a typo, not a position to clamp. Silently moving a user
  // to the nearest valid point would be the confidently-wrong failure this
  // whole product is built to avoid.
  if (latitude.abs() > 90 || longitude.abs() > 180) return null;
  return ParsedCoordinate(
    latitude: latitude,
    longitude: longitude,
    format: CoordinateFormat.decimalDegrees,
  );
}
