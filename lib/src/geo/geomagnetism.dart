import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'wmm_coefficients.dart';

/// The World Magnetic Model, evaluated offline.
///
/// A compass measures magnetic north; a map is drawn to true north. The angle
/// between them — the magnetic declination — is under a degree in Dhaka and
/// London but exceeds twenty degrees across parts of North America, so a
/// heading-up map rotated by a raw magnetic reading is visibly wrong over much
/// of the world.
///
/// The declination is not looked up. It is computed from a spherical harmonic
/// expansion of degree and order twelve, which is ninety coefficients and some
/// arithmetic — no dataset to ship beyond those numbers, no network, valid on
/// every square metre of the planet. That is the same reasoning the
/// requirements apply to Plus Codes in section 2.4: anything that can be
/// computed should be.
///
/// This follows the algorithm in the WMM technical report and the reference
/// implementation NOAA publishes alongside it. Correctness is checked against
/// NOAA's own published test values rather than against itself.
@immutable
class MagneticField {
  const MagneticField({
    required this.declinationDegrees,
    required this.inclinationDegrees,
    required this.horizontalIntensity,
    required this.totalIntensity,
    required this.north,
    required this.east,
    required this.down,
  });

  /// Degrees east of true north. Add to a magnetic heading to get a true one.
  final double declinationDegrees;

  /// Dip angle, positive downward.
  final double inclinationDegrees;

  /// Horizontal field strength, nanotesla.
  final double horizontalIntensity;

  /// Total field strength, nanotesla.
  final double totalIntensity;

  final double north;
  final double east;
  final double down;

  @override
  String toString() =>
      'MagneticField(D ${declinationDegrees.toStringAsFixed(2)}°)';
}

/// One spherical harmonic coefficient pair and its annual drift.
@immutable
class _Coefficient {
  const _Coefficient(this.g, this.h, this.gDot, this.hDot);
  final double g;
  final double h;
  final double gDot;
  final double hDot;
}

/// The magnetic model, parsed once and reused.
class GeomagneticModel {
  GeomagneticModel._(this.epoch, this.name, this._coefficients, this.maxDegree);

  /// The model as shipped.
  static final GeomagneticModel wmm2025 = parse(wmmCoefficients);

  /// Decimal year the coefficients are referenced to.
  final double epoch;

  final String name;

  /// Degree and order of the expansion. Twelve for the WMM.
  final int maxDegree;

  /// Indexed by `n * (n + 1) / 2 + m`.
  final List<_Coefficient> _coefficients;

  /// Geomagnetic reference radius, kilometres.
  ///
  /// Deliberately not the WGS84 semi-major axis. The harmonic expansion is
  /// defined against 6371.2 km, and using 6378.137 here instead is a classic
  /// way to be quietly wrong by a fraction of a degree everywhere.
  static const double _referenceRadiusKm = 6371.2;

  /// WGS84, for the geodetic to geocentric conversion.
  static const double _semiMajorAxisKm = 6378.137;
  static const double _eccentricitySquared = 0.0066943799901413165;

  /// The WMM is fitted for five years and is not valid outside that window.
  double get validUntil => epoch + 5.0;

  bool isExpiredAt(DateTime when) => decimalYear(when) >= validUntil;

  static GeomagneticModel parse(String cof) {
    final lines = cof
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('9999'))
        .toList();

    final header = lines.first.split(RegExp(r'\s+'));
    final epoch = double.parse(header[0]);
    final name = header.length > 1 ? header[1] : 'WMM';

    var maxDegree = 0;
    final parsed = <int, _Coefficient>{};

    for (final line in lines.skip(1)) {
      final f = line.split(RegExp(r'\s+'));
      if (f.length < 6) continue;
      final n = int.parse(f[0]);
      final m = int.parse(f[1]);
      if (n > maxDegree) maxDegree = n;
      parsed[n * (n + 1) ~/ 2 + m] = _Coefficient(
        double.parse(f[2]),
        double.parse(f[3]),
        double.parse(f[4]),
        double.parse(f[5]),
      );
    }

    final size = (maxDegree + 1) * (maxDegree + 2) ~/ 2;
    final coefficients = List<_Coefficient>.generate(
      size,
      (i) => parsed[i] ?? const _Coefficient(0, 0, 0, 0),
    );

    return GeomagneticModel._(epoch, name, coefficients, maxDegree);
  }

  /// Fractional year, which is how the model expresses time.
  static double decimalYear(DateTime when) {
    final utc = when.toUtc();
    final startOfYear = DateTime.utc(utc.year);
    final startOfNext = DateTime.utc(utc.year + 1);
    final elapsed = utc.difference(startOfYear).inSeconds;
    final total = startOfNext.difference(startOfYear).inSeconds;
    return utc.year + elapsed / total;
  }

  /// The field at a position and time.
  ///
  /// [heightKm] is above the WGS84 ellipsoid.
  MagneticField fieldAt({
    required double latitude,
    required double longitude,
    double heightKm = 0,
    DateTime? when,
  }) {
    final t = decimalYear(when ?? DateTime.now()) - epoch;

    // Geodetic to geocentric spherical. The two latitudes differ by up to
    // about 0.19 degrees, and the field components have to be rotated back at
    // the end by exactly that difference.
    final latRad = latitude * math.pi / 180.0;
    final lonRad = longitude * math.pi / 180.0;
    final sinLat = math.sin(latRad);
    final cosLat = math.cos(latRad);

    final rc = _semiMajorAxisKm /
        math.sqrt(1 - _eccentricitySquared * sinLat * sinLat);
    final xp = (rc + heightKm) * cosLat;
    final zp = (rc * (1 - _eccentricitySquared) + heightKm) * sinLat;

    final r = math.sqrt(xp * xp + zp * zp);
    final geocentricLatRad = math.asin(zp / r);

    final sinPhi = math.sin(geocentricLatRad);
    final cosPhi = math.cos(geocentricLatRad);

    final legendre = _legendre(sinPhi, cosPhi);
    final p = legendre.p;
    final dp = legendre.dp;

    // (a / r)^(n + 2), built up rather than raised each time.
    final radiusPower = List<double>.filled(maxDegree + 1, 0);
    final ratio = _referenceRadiusKm / r;
    radiusPower[0] = ratio * ratio;
    for (var n = 1; n <= maxDegree; n++) {
      radiusPower[n] = radiusPower[n - 1] * ratio;
    }

    final cosMLambda = List<double>.filled(maxDegree + 1, 0);
    final sinMLambda = List<double>.filled(maxDegree + 1, 0);
    cosMLambda[0] = 1;
    sinMLambda[0] = 0;
    if (maxDegree >= 1) {
      cosMLambda[1] = math.cos(lonRad);
      sinMLambda[1] = math.sin(lonRad);
      for (var m = 2; m <= maxDegree; m++) {
        cosMLambda[m] =
            cosMLambda[m - 1] * cosMLambda[1] - sinMLambda[m - 1] * sinMLambda[1];
        sinMLambda[m] =
            cosMLambda[m - 1] * sinMLambda[1] + sinMLambda[m - 1] * cosMLambda[1];
      }
    }

    var bx = 0.0;
    var by = 0.0;
    var bz = 0.0;

    for (var n = 1; n <= maxDegree; n++) {
      for (var m = 0; m <= n; m++) {
        final index = n * (n + 1) ~/ 2 + m;
        final c = _coefficients[index];
        // Coefficients drift, which is why the model carries an annual rate
        // and an expiry rather than being a fixed table.
        final g = c.g + t * c.gDot;
        final h = c.h + t * c.hDot;

        final common = radiusPower[n] * (g * cosMLambda[m] + h * sinMLambda[m]);
        bz -= common * (n + 1) * p[index];
        bx -= common * dp[index];
        by += radiusPower[n] *
            (g * sinMLambda[m] - h * cosMLambda[m]) *
            m *
            p[index];
      }
    }

    // At the geographic poles the east component divides by a vanishing
    // cosine. Declination is meaningless there anyway -- every direction is
    // south -- so it is clamped rather than allowed to blow up.
    if (cosPhi.abs() > 1.0e-10) {
      by = by / cosPhi;
    } else {
      by = 0;
    }

    // Rotate the field from geocentric back to geodetic.
    final psi = geocentricLatRad - latRad;
    final north = bx * math.cos(psi) - bz * math.sin(psi);
    final down = bx * math.sin(psi) + bz * math.cos(psi);
    final east = by;

    final horizontal = math.sqrt(north * north + east * east);
    final total = math.sqrt(horizontal * horizontal + down * down);

    return MagneticField(
      declinationDegrees: math.atan2(east, north) * 180.0 / math.pi,
      inclinationDegrees: math.atan2(down, horizontal) * 180.0 / math.pi,
      horizontalIntensity: horizontal,
      totalIntensity: total,
      north: north,
      east: east,
      down: down,
    );
  }

  /// Magnetic declination in degrees east of true north.
  double declinationAt({
    required double latitude,
    required double longitude,
    double heightKm = 0,
    DateTime? when,
  }) =>
      fieldAt(
        latitude: latitude,
        longitude: longitude,
        heightKm: heightKm,
        when: when,
      ).declinationDegrees;

  /// Schmidt semi-normalised associated Legendre functions and their
  /// derivatives with respect to geocentric latitude.
  ///
  /// Computed by recursion rather than from factorials: the factorials
  /// overflow well before degree twelve, and the recursion is what every
  /// reference implementation uses.
  ({List<double> p, List<double> dp}) _legendre(double x, double z) {
    final size = (maxDegree + 1) * (maxDegree + 2) ~/ 2;
    final p = List<double>.filled(size, 0);
    final dp = List<double>.filled(size, 0);

    p[0] = 1;
    dp[0] = 0;

    for (var n = 1; n <= maxDegree; n++) {
      for (var m = 0; m <= n; m++) {
        final index = n * (n + 1) ~/ 2 + m;
        if (n == m) {
          final index1 = (n - 1) * n ~/ 2 + m - 1;
          p[index] = z * p[index1];
          dp[index] = z * dp[index1] + x * p[index1];
        } else if (n == 1 && m == 0) {
          final index1 = (n - 1) * n ~/ 2 + m;
          p[index] = x * p[index1];
          dp[index] = x * dp[index1] - z * p[index1];
        } else {
          final index1 = (n - 2) * (n - 1) ~/ 2 + m;
          final index2 = (n - 1) * n ~/ 2 + m;
          if (m > n - 2) {
            p[index] = x * p[index2];
            dp[index] = x * dp[index2] - z * p[index2];
          } else {
            final k = ((n - 1) * (n - 1) - m * m) /
                ((2 * n - 1) * (2 * n - 3)).toDouble();
            p[index] = x * p[index2] - k * p[index1];
            dp[index] = x * dp[index2] - z * p[index2] - k * dp[index1];
          }
        }
      }
    }

    // Convert from fully normalised to Schmidt quasi-normalised.
    final norm = List<double>.filled(size, 0);
    norm[0] = 1;
    for (var n = 1; n <= maxDegree; n++) {
      final index = n * (n + 1) ~/ 2;
      final index1 = (n - 1) * n ~/ 2;
      norm[index] = norm[index1] * (2 * n - 1) / n;
      for (var m = 1; m <= n; m++) {
        final i = n * (n + 1) ~/ 2 + m;
        final i1 = n * (n + 1) ~/ 2 + m - 1;
        norm[i] = norm[i1] *
            math.sqrt(
              (n - m + 1) * (m == 1 ? 2 : 1) / (n + m).toDouble(),
            );
      }
    }

    for (var i = 0; i < size; i++) {
      p[i] *= norm[i];
      // Negated because the recursion differentiates with respect to the
      // colatitude while the summation wants latitude.
      dp[i] *= -norm[i];
    }

    return (p: p, dp: dp);
  }
}
