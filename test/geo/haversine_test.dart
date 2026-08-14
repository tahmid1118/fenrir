import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/src/geo/haversine.dart';

void main() {
  group('distanceKm', () {
    test('is zero between identical points', () {
      expect(distanceKm(23.7461, 90.3742, 23.7461, 90.3742), 0.0);
      expect(distanceKm(-33.8688, 151.2093, -33.8688, 151.2093), 0.0);
    });

    test('matches the specification fixture for Dhanmondi', () {
      // FR-3.1 records 23.7461, 90.3742 resolving to Dhanmondi at 1.29 km.
      // Dhanmondi sits at 23.74, 90.385 in the bundled database, and this
      // distance is what the whole place-resolution feature is measured
      // against, so it is pinned here to four decimal places.
      expect(
        distanceKm(23.7461, 90.3742, 23.74, 90.385),
        closeTo(1.2917, 0.0005),
      );
    });

    test('one degree of latitude is a meridian arc, anywhere', () {
      // A degree of latitude is the same length everywhere on a sphere:
      // R * pi / 180.
      const expected = earthRadiusKm * 3.141592653589793 / 180.0;
      expect(distanceKm(0, 0, 1, 0), closeTo(expected, 1e-9));
      expect(distanceKm(50, 20, 51, 20), closeTo(expected, 1e-9));
      expect(distanceKm(-70, -140, -71, -140), closeTo(expected, 1e-9));
    });

    test('a degree of longitude shrinks with the cosine of latitude', () {
      // The place-resolution bounding box in Task 5 sizes its longitude span
      // as radius / (111.32 * cos(lat)). That approximation is the arc along
      // the *parallel*, which is not a great circle, so the true great-circle
      // distance is always slightly shorter. This test pins how much.
      final atEquator = distanceKm(0, 0, 0, 1);
      final atSixty = distanceKm(60, 0, 60, 1);
      final parallelArc = atEquator * 0.5; // cos(60 degrees) is exactly 0.5

      // Never longer than the parallel arc: a great circle is the shorter path.
      expect(atSixty, lessThan(parallelArc));

      // And close enough that a bounding box built on cos(lat) over-covers
      // rather than under-covers, which is the safe direction to be wrong in.
      expect(atSixty / parallelArc, closeTo(1.0, 1e-4));
    });

    test('the cosine approximation tightens as the span narrows', () {
      // The error is second order in the longitude delta, so the boxes used
      // for a 25 km search are far more accurate than this one-degree case.
      double relativeError(double lat, double deltaLon) {
        final actual = distanceKm(lat, 0, lat, deltaLon);
        final approx = distanceKm(0, 0, 0, deltaLon) *
            math.cos(lat * math.pi / 180.0);
        return (approx - actual).abs() / approx;
      }

      expect(relativeError(60, 1.0), lessThan(1e-4));
      expect(relativeError(60, 0.1), lessThan(1e-6));
    });

    test('crossing the antimeridian is a short hop, not a trip round the world',
        () {
      // The failure this guards against is naive longitude subtraction, which
      // turns 0.2 degrees into 359.8 and puts the user on the wrong side of the
      // planet. "Anywhere on Earth" in FR-4.1 includes here.
      final crossing = distanceKm(0, 179.9, 0, -179.9);
      final equivalent = distanceKm(0, -0.1, 0, 0.1);
      expect(crossing, closeTo(equivalent, 1e-9));
      expect(crossing, lessThan(25.0));
    });

    test('pole to pole is half the circumference', () {
      expect(
        distanceKm(90, 0, -90, 0),
        closeTo(earthRadiusKm * 3.141592653589793, 1e-6),
      );
    });

    test('is symmetric', () {
      expect(
        distanceKm(23.7461, 90.3742, 51.5074, -0.1278),
        closeTo(distanceKm(51.5074, -0.1278, 23.7461, 90.3742), 1e-9),
      );
    });

    test('stays precise at sub-metre separations', () {
      // Haversine is chosen over the spherical law of cosines precisely
      // because it does not lose precision on short distances. At the accuracy
      // radii FR-1.2 reports, this matters.
      final d = distanceKm(23.746100, 90.374200, 23.746109, 90.374200);
      expect(d, greaterThan(0.0));
      expect(d * 1000, closeTo(1.0, 0.01)); // roughly one metre
    });

    test('never returns NaN, including at antipodes', () {
      expect(distanceKm(0, 0, 0, 180).isNaN, isFalse);
      expect(distanceKm(45, 90, -45, -90).isNaN, isFalse);
      expect(distanceKm(0, 0, 0, 180), closeTo(earthRadiusKm * 3.14159265, 1e-4));
    });
  });

  group('bearingDeg', () {
    test('reports the cardinal directions', () {
      expect(bearingDeg(0, 0, 1, 0), closeTo(0.0, 1e-6)); // north
      expect(bearingDeg(0, 0, 0, 1), closeTo(90.0, 1e-6)); // east
      expect(bearingDeg(1, 0, 0, 0), closeTo(180.0, 1e-6)); // south
      expect(bearingDeg(0, 1, 0, 0), closeTo(270.0, 1e-6)); // west
    });

    test('is normalised to [0, 360)', () {
      final samples = <double>[];
      for (var lat = -80.0; lat <= 80.0; lat += 17.0) {
        for (var lon = -170.0; lon <= 170.0; lon += 37.0) {
          samples.add(bearingDeg(10, 20, lat, lon));
        }
      }
      for (final b in samples) {
        expect(b, greaterThanOrEqualTo(0.0));
        expect(b, lessThan(360.0));
      }
    });

    test('crossing the antimeridian eastward reads as east, not west', () {
      expect(bearingDeg(0, 179.9, 0, -179.9), closeTo(90.0, 1e-6));
      expect(bearingDeg(0, -179.9, 0, 179.9), closeTo(270.0, 1e-6));
    });
  });
}
