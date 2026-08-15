import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/src/geo/geomagnetism.dart';

/// One row of NOAA's published test values.
class _Vector {
  _Vector(List<String> f)
      : year = double.parse(f[0]),
        heightKm = double.parse(f[1]),
        latitude = double.parse(f[2]),
        longitude = double.parse(f[3]),
        declination = double.parse(f[4]),
        inclination = double.parse(f[5]),
        horizontal = double.parse(f[6]),
        north = double.parse(f[7]),
        east = double.parse(f[8]),
        down = double.parse(f[9]),
        total = double.parse(f[10]);

  final double year;
  final double heightKm;
  final double latitude;
  final double longitude;
  final double declination;
  final double inclination;
  final double horizontal;
  final double north;
  final double east;
  final double down;
  final double total;

  /// The model takes a DateTime; the fixture gives a decimal year.
  DateTime get when {
    final y = year.floor();
    final start = DateTime.utc(y);
    final next = DateTime.utc(y + 1);
    final seconds =
        (next.difference(start).inSeconds * (year - y)).round();
    return start.add(Duration(seconds: seconds));
  }

  @override
  String toString() => '$year, ${heightKm}km, $latitude, $longitude';
}

void main() {
  final model = GeomagneticModel.wmm2025;

  List<_Vector> loadVectors() {
    final file = File('test/geo/fixtures/wmm2025_test_values.txt');
    if (!file.existsSync()) {
      throw StateError('Missing ${file.path}. These are NOAA\'s published '
          'test values and must be committed.');
    }
    return file
        .readAsLinesSync()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .map((l) => _Vector(l.split(RegExp(r'\s+'))))
        .toList();
  }

  group('the coefficient table', () {
    test('parsed the whole model', () {
      expect(model.epoch, 2025.0);
      expect(model.maxDegree, 12);
      expect(model.name, contains('WMM'));
    });

    test('is valid for five years and knows when it is not', () {
      // The WMM is fitted for a five-year window. Using it past that is not a
      // small error, so the expiry is a property of the model rather than a
      // note in a document.
      expect(model.validUntil, 2030.0);
      expect(model.isExpiredAt(DateTime.utc(2026, 8, 15)), isFalse);
      expect(model.isExpiredAt(DateTime.utc(2029, 12, 31)), isFalse);
      expect(model.isExpiredAt(DateTime.utc(2030, 1, 2)), isTrue);
    });
  });

  group("NOAA's published test values", () {
    final vectors = loadVectors();

    test('the fixture is present and complete', () {
      expect(vectors.length, greaterThanOrEqualTo(100));
    });

    test('declination matches every published value', () {
      // This is the number the app actually uses. NOAA publishes it to two
      // decimal places, so agreement to 0.01 degrees is agreement to the
      // limit of the fixture.
      for (final v in vectors) {
        final actual = model.declinationAt(
          latitude: v.latitude,
          longitude: v.longitude,
          heightKm: v.heightKm,
          when: v.when,
        );
        expect(actual, closeTo(v.declination, 0.01), reason: '$v');
      }
    });

    test('inclination matches every published value', () {
      for (final v in vectors) {
        final field = model.fieldAt(
          latitude: v.latitude,
          longitude: v.longitude,
          heightKm: v.heightKm,
          when: v.when,
        );
        expect(field.inclinationDegrees, closeTo(v.inclination, 0.01),
            reason: '$v');
      }
    });

    test('the field components match every published value', () {
      // Checking the vector components as well as the angles catches a whole
      // class of error that a correct-looking declination can hide: two
      // components wrong by the same factor still divide to the right angle.
      for (final v in vectors) {
        final field = model.fieldAt(
          latitude: v.latitude,
          longitude: v.longitude,
          heightKm: v.heightKm,
          when: v.when,
        );
        expect(field.north, closeTo(v.north, 0.5), reason: 'X at $v');
        expect(field.east, closeTo(v.east, 0.5), reason: 'Y at $v');
        expect(field.down, closeTo(v.down, 0.5), reason: 'Z at $v');
        expect(field.horizontalIntensity, closeTo(v.horizontal, 0.5),
            reason: 'H at $v');
        expect(field.totalIntensity, closeTo(v.total, 0.5), reason: 'F at $v');
      }
    });

    test('covers altitude and epoch variation, not just sea level in 2025', () {
      // Guards the fixture itself: if it only held one year at one height, the
      // tests above would pass while the time and altitude terms were broken.
      expect(vectors.map((v) => v.year).toSet().length, greaterThan(1));
      expect(vectors.map((v) => v.heightKm).toSet().length, greaterThan(1));
    });
  });

  group('declination where it matters', () {
    test('is small in Dhaka and large in North America', () {
      // The reason this exists at all. Under a degree here, and enough to
      // rotate a map visibly wrong over there.
      final dhaka = model.declinationAt(
        latitude: 23.7461,
        longitude: 90.3742,
        when: DateTime.utc(2026, 8, 15),
      );
      expect(dhaka.abs(), lessThan(2.0));

      final seattle = model.declinationAt(
        latitude: 47.6062,
        longitude: -122.3321,
        when: DateTime.utc(2026, 8, 15),
      );
      expect(seattle.abs(), greaterThan(10.0));

      // Sign convention: east of true north is positive. Seattle's is east.
      expect(seattle, greaterThan(0));
    });

    test('London is close to zero, as it has been for a decade', () {
      final london = model.declinationAt(
        latitude: 51.5074,
        longitude: -0.1278,
        when: DateTime.utc(2026, 8, 15),
      );
      expect(london.abs(), lessThan(3.0));
    });
  });

  group('behaves everywhere on Earth', () {
    test('never returns NaN, including at the poles', () {
      const probes = <(double, double)>[
        (90, 0),
        (-90, 0),
        (89.9999, 179.9999),
        (-89.9999, -179.9999),
        (0, 180),
        (0, -180),
        (0, 0),
      ];
      for (final (lat, lon) in probes) {
        final d = model.declinationAt(
          latitude: lat,
          longitude: lon,
          when: DateTime.utc(2026),
        );
        expect(d.isNaN, isFalse, reason: '$lat, $lon');
        expect(d.isFinite, isTrue, reason: '$lat, $lon');
        expect(d, inInclusiveRange(-180, 180));
      }
    });

    test('is continuous across the antimeridian', () {
      final east = model.declinationAt(
        latitude: 20,
        longitude: 179.99,
        when: DateTime.utc(2026),
      );
      final west = model.declinationAt(
        latitude: 20,
        longitude: -179.99,
        when: DateTime.utc(2026),
      );
      expect((east - west).abs(), lessThan(0.1));
    });

    test('altitude changes the answer, but only slightly', () {
      final sea = model.declinationAt(
        latitude: 47.6, longitude: -122.3, when: DateTime.utc(2026));
      final high = model.declinationAt(
        latitude: 47.6,
        longitude: -122.3,
        heightKm: 10,
        when: DateTime.utc(2026),
      );
      expect(sea, isNot(high));
      expect((sea - high).abs(), lessThan(1.0));
    });

    test('drifts over time, which is why the model expires', () {
      final now = model.declinationAt(
        latitude: 47.6, longitude: -122.3, when: DateTime.utc(2025));
      final later = model.declinationAt(
        latitude: 47.6, longitude: -122.3, when: DateTime.utc(2029));
      expect((now - later).abs(), greaterThan(0.1));
    });
  });

  group('performance', () {
    test('is fast enough to run on every compass reading', () {
      // The compass emits several times a second. If this were expensive it
      // would have to be cached against position, which is more state to get
      // wrong.
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        model.declinationAt(
          latitude: 23.7 + i % 10,
          longitude: 90.4,
          when: DateTime.utc(2026),
        );
      }
      stopwatch.stop();
      final each = stopwatch.elapsedMicroseconds / 1000;
      // ignore: avoid_print
      print('WMM: ${each.toStringAsFixed(1)} us per evaluation');
      expect(each, lessThan(2000));
    });
  });
}
