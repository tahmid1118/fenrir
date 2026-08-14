import 'dart:math' as math;

/// Mean Earth radius, IUGG arithmetic mean, in kilometres.
///
/// The Earth is an oblate spheroid, so no single radius is correct everywhere;
/// this value trades a worst case of roughly 0.5% error for arithmetic that
/// costs nothing. That is far inside the accuracy the GNSS receiver reports
/// (FR-1.2), and inside the precision at which distances are shown to the user,
/// so a geodesic solution would buy nothing a user could perceive.
const double earthRadiusKm = 6371.0088;

const double _degToRad = math.pi / 180.0;
const double _radToDeg = 180.0 / math.pi;

/// Great-circle distance between two WGS84 positions, in kilometres.
///
/// Uses the haversine formula rather than the spherical law of cosines. The
/// law of cosines loses precision catastrophically at short distances — the
/// exact range this app spends its time in, since FR-3.2 reports distances of
/// a kilometre or two and FR-1.2 reports accuracy radii in metres.
///
/// Longitude difference is handled by the formula's own periodicity, so a pair
/// straddling the antimeridian gives the short distance across it, not a trip
/// most of the way round the planet.
double distanceKm(double lat1, double lon1, double lat2, double lon2) {
  final phi1 = lat1 * _degToRad;
  final phi2 = lat2 * _degToRad;
  final deltaPhi = (lat2 - lat1) * _degToRad;
  final deltaLambda = (lon2 - lon1) * _degToRad;

  final sinHalfPhi = math.sin(deltaPhi / 2);
  final sinHalfLambda = math.sin(deltaLambda / 2);

  final a = sinHalfPhi * sinHalfPhi +
      math.cos(phi1) * math.cos(phi2) * sinHalfLambda * sinHalfLambda;

  // Clamping guards the antipodal case, where accumulated floating-point error
  // can push `a` a hair above 1 and make sqrt(1 - a) NaN.
  final clamped = a.clamp(0.0, 1.0);
  final c = 2 * math.atan2(math.sqrt(clamped), math.sqrt(1 - clamped));

  return earthRadiusKm * c;
}

/// Initial great-circle bearing from the first position to the second, in
/// degrees clockwise from true north, normalised to `[0, 360)`.
///
/// This is the forward azimuth at the start of the path. On a sphere the
/// bearing changes continuously along a great circle, so it is not the same as
/// the bearing measured at the destination.
double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final phi1 = lat1 * _degToRad;
  final phi2 = lat2 * _degToRad;
  final deltaLambda = (lon2 - lon1) * _degToRad;

  final y = math.sin(deltaLambda) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(deltaLambda);

  final theta = math.atan2(y, x) * _radToDeg;
  return (theta + 360.0) % 360.0;
}
