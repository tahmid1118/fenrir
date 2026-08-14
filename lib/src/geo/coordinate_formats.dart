import 'package:geobase/geobase.dart';
import 'package:meta/meta.dart';

import 'plus_code.dart';

/// The coordinate notations the app can present (FR-2.1, FR-2.2).
///
/// Every conversion is computed locally. None of them consults a network
/// service, which is what makes them usable under NFR-1.
enum CoordinateFormat {
  decimalDegrees('Decimal degrees', 'DD'),
  degreesMinutesSeconds('Degrees, minutes, seconds', 'DMS'),
  utm('Universal Transverse Mercator', 'UTM'),
  mgrs('Military Grid Reference System', 'MGRS'),
  plusCode('Plus Code', 'Plus Code');

  const CoordinateFormat(this.label, this.shortLabel);

  /// Full name, for screen readers and settings (NFR-7).
  final String label;

  /// Compact name, for the format chip on the position panel.
  final String shortLabel;

  /// The next format in the cycle, for FR-2.1's one-tap switching.
  CoordinateFormat get next =>
      CoordinateFormat.values[(index + 1) % CoordinateFormat.values.length];
}

/// A coordinate rendered in one notation, or an explanation of why it cannot
/// be.
///
/// Not every notation is defined everywhere. UTM and MGRS are undefined in the
/// polar regions, and a formatter that threw there would take the position
/// panel down with it for a user in Antarctica. NFR-6 requires a defined,
/// informative state instead, so unavailability is a value the UI renders
/// rather than an exception it has to catch.
@immutable
class FormattedCoordinate {
  const FormattedCoordinate.value(String this.text)
      : unavailableReason = null;

  const FormattedCoordinate.unavailable(String this.unavailableReason)
      : text = null;

  /// The rendered coordinate, or null when this notation does not apply here.
  final String? text;

  /// Why this notation does not apply, or null when it does.
  final String? unavailableReason;

  bool get isAvailable => text != null;

  /// The text to show, whichever case applies.
  String get display => text ?? unavailableReason!;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FormattedCoordinate &&
          text == other.text &&
          unavailableReason == other.unavailableReason);

  @override
  int get hashCode => Object.hash(text, unavailableReason);

  @override
  String toString() => 'FormattedCoordinate($display)';
}

/// Wraps longitude into [-180, 180) and clamps latitude to [-90, 90].
///
/// A fix should never arrive outside these bounds, but the formatters are also
/// fed by pasted input in FR-8.2, and `geobase` rejects out-of-range values
/// outright.
(double, double) normalizePosition(double latitude, double longitude) {
  final lat = latitude.clamp(-90.0, 90.0);
  var lon = longitude;
  if (lon < -180.0 || lon >= 180.0) {
    lon = (lon + 180.0) % 360.0;
    if (lon < 0) lon += 360.0;
    lon -= 180.0;
  }
  return (lat, lon);
}

/// Signed decimal degrees, e.g. `23.746100°, 90.374200°`.
///
/// Six decimal places is about 0.11 m at the equator — finer than any GNSS fix
/// this app will see, so the notation never loses precision the receiver had.
String formatDecimalDegrees(
  double latitude,
  double longitude, {
  int decimals = 6,
}) {
  final (lat, lon) = normalizePosition(latitude, longitude);
  return '${lat.toStringAsFixed(decimals)}°, ${lon.toStringAsFixed(decimals)}°';
}

/// Bare signed decimal degrees, e.g. `23.746100, 90.374200`.
///
/// The form to put in a shared message (FR-2.3): every mapping application and
/// search engine accepts it, so a recipient with no special app can still act
/// on it.
String formatDecimalDegreesPlain(
  double latitude,
  double longitude, {
  int decimals = 6,
}) {
  final (lat, lon) = normalizePosition(latitude, longitude);
  return '${lat.toStringAsFixed(decimals)}, ${lon.toStringAsFixed(decimals)}';
}

/// Degrees, minutes and seconds, e.g. `23°44'46.0"N, 90°22'27.1"E`.
String formatDms(double latitude, double longitude) {
  final (lat, lon) = normalizePosition(latitude, longitude);
  final latText = _dmsComponent(lat, lat >= 0 ? 'N' : 'S');
  final lonText = _dmsComponent(lon, lon >= 0 ? 'E' : 'W');
  return '$latText, $lonText';
}

String _dmsComponent(double value, String hemisphere) {
  // Round to tenths of a second *before* splitting into components. Rounding
  // afterwards lets 59.96 seconds render as 60.0 instead of carrying into the
  // next minute.
  final totalTenths = (value.abs() * 36000).round();
  final degrees = totalTenths ~/ 36000;
  final minutes = (totalTenths % 36000) ~/ 600;
  final seconds = (totalTenths % 600) / 10.0;

  final m = minutes.toString().padLeft(2, '0');
  final s = seconds.toStringAsFixed(1).padLeft(4, '0');
  return '$degrees°$m\'$s"$hemisphere';
}

/// Renders [latitude], [longitude] in the requested notation.
FormattedCoordinate formatCoordinate(
  double latitude,
  double longitude,
  CoordinateFormat format,
) {
  final (lat, lon) = normalizePosition(latitude, longitude);

  switch (format) {
    case CoordinateFormat.decimalDegrees:
      return FormattedCoordinate.value(formatDecimalDegrees(lat, lon));

    case CoordinateFormat.degreesMinutesSeconds:
      return FormattedCoordinate.value(formatDms(lat, lon));

    case CoordinateFormat.utm:
      return _grid(lat, lon, mgrs: false);

    case CoordinateFormat.mgrs:
      return _grid(lat, lon, mgrs: true);

    case CoordinateFormat.plusCode:
      return FormattedCoordinate.value(encodePlusCode(lat, lon));
  }
}

/// Whether UTM and MGRS are defined at this latitude.
///
/// Both stop at 84°N and 80°S; the polar caps use the Universal Polar
/// Stereographic system instead, which is out of scope.
bool isUtmDefinedAt(double latitude) =>
    latitude >= minLatitudeUTM && latitude <= maxLatitudeUTM;

const String _polarReason =
    'Not defined above 84°N or below 80°S';

FormattedCoordinate _grid(double lat, double lon, {required bool mgrs}) {
  if (!isUtmDefinedAt(lat)) {
    return const FormattedCoordinate.unavailable(_polarReason);
  }
  try {
    final geographic = Geographic(lat: lat, lon: lon);
    final utm = geographic.toUtm();
    return FormattedCoordinate.value(
      mgrs ? utm.toMgrs().toText() : utm.toText(),
    );
  } on FormatException {
    // The latitude guard above should make this unreachable, but a projection
    // failure must still not be allowed to take down the position panel.
    return const FormattedCoordinate.unavailable(_polarReason);
  }
}
