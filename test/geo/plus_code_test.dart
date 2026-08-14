import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/src/geo/plus_code.dart';

/// Reads a fixture, dropping comment and blank lines.
List<List<String>> _rows(String name) {
  final file = File('test/geo/fixtures/$name');
  if (!file.existsSync()) {
    throw StateError('Missing fixture ${file.path}. These are the official '
        'vectors from google/open-location-code and must be committed.');
  }
  return file
      .readAsLinesSync()
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .map((l) => l.split(','))
      .toList();
}

void main() {
  // The whole reason for implementing Plus Codes rather than depending on a
  // package is that the algorithm is fully specified and externally graded.
  // These are the project's own vectors, so the correctness bar is Google's,
  // not ours.

  group('encoding vectors', () {
    final rows = _rows('encoding.csv');

    test('the fixture is present and substantial', () {
      expect(rows.length, greaterThan(250));
    });

    test('every vector encodes correctly from degrees', () {
      var checked = 0;
      for (final row in rows) {
        final lat = double.parse(row[0]);
        final lng = double.parse(row[1]);
        final length = int.parse(row[4]);
        final expected = row[5];

        expect(
          encodePlusCode(lat, lng, codeLength: length),
          expected,
          reason: 'encode($lat, $lng, length $length)',
        );
        checked++;
      }
      expect(checked, rows.length);
    });

    test('every vector encodes correctly from integers', () {
      // The fixture carries the integer form as well as degrees. Testing both
      // separates a fault in the digit arithmetic from a fault in the
      // degrees-to-integer conversion.
      for (final row in rows) {
        final latInt = int.parse(row[2]);
        final lngInt = int.parse(row[3]);
        final length = int.parse(row[4]);
        final expected = row[5];

        expect(
          encodePlusCodeIntegers(latInt, lngInt, codeLength: length),
          expected,
          reason: 'encodeIntegers($latInt, $lngInt, length $length)',
        );
      }
    });

    test('degrees and integers agree on the same input', () {
      for (final row in rows) {
        final lat = double.parse(row[0]);
        final lng = double.parse(row[1]);
        expect(locationToIntegers(lat, lng),
            (int.parse(row[2]), int.parse(row[3])),
            reason: 'locationToIntegers($lat, $lng)');
      }
    });
  });

  group('decoding vectors', () {
    final rows = _rows('decoding.csv');

    test('the fixture is present and substantial', () {
      expect(rows.length, greaterThan(350));
    });

    test('every vector decodes to the correct bounding box', () {
      // The fixture states bounds to a fixed number of places, so compare with
      // a tolerance rather than for exact equality.
      const tolerance = 1e-10;
      for (final row in rows) {
        final code = row[0];
        final length = int.parse(row[1]);
        final area = decodePlusCode(code);

        expect(area.codeLength, length, reason: 'length of $code');
        expect(area.latitudeLo, closeTo(double.parse(row[2]), tolerance),
            reason: 'latLo of $code');
        expect(area.longitudeLo, closeTo(double.parse(row[3]), tolerance),
            reason: 'lngLo of $code');
        expect(area.latitudeHi, closeTo(double.parse(row[4]), tolerance),
            reason: 'latHi of $code');
        expect(area.longitudeHi, closeTo(double.parse(row[5]), tolerance),
            reason: 'lngHi of $code');
      }
    });

    test('the centre lies inside the decoded box', () {
      for (final row in rows) {
        final area = decodePlusCode(row[0]);
        expect(area.latitudeCenter, greaterThanOrEqualTo(area.latitudeLo));
        expect(area.latitudeCenter, lessThanOrEqualTo(area.latitudeHi));
        expect(area.longitudeCenter, greaterThanOrEqualTo(area.longitudeLo));
        expect(area.longitudeCenter, lessThanOrEqualTo(area.longitudeHi));
      }
    });
  });

  group('validity vectors', () {
    final rows = _rows('validityTests.csv');

    test('the fixture is present', () {
      expect(rows.length, greaterThan(20));
    });

    test('validity, shortness and fullness all match', () {
      for (final row in rows) {
        final code = row[0];
        expect(isValidPlusCode(code), row[1] == 'true',
            reason: 'isValid($code)');
        expect(isShortPlusCode(code), row[2] == 'true',
            reason: 'isShort($code)');
        expect(isFullPlusCode(code), row[3] == 'true', reason: 'isFull($code)');
      }
    });
  });

  group('round trip', () {
    test('encoding then decoding recovers the original position', () {
      // Every decoded area must contain the position that produced it. This is
      // the property FR-2.2 actually depends on: a shared code has to lead a
      // recipient back to where the sender was.
      const samples = <(double, double)>[
        (23.7461, 90.3742), // the specification's Dhanmondi fixture
        (0.0, 0.0),
        (-33.8688, 151.2093),
        (64.1466, -21.9426),
        (-54.8019, -68.3030),
        (78.2232, 15.6469),
      ];

      // Decoding sums two floating-point divisions, so a position sitting
      // exactly on a box edge can land outside it by a few units in the last
      // place. At these latitudes 1e-9 degrees is about a tenth of a
      // millimetre -- far below anything the rest of the system can perceive,
      // and the official decoding vectors already pin the bounds to 1e-10.
      const epsilon = 1e-9;

      for (final (lat, lng) in samples) {
        for (final length in [2, 4, 6, 8, 10, 11, 12, 15]) {
          final code = encodePlusCode(lat, lng, codeLength: length);
          final area = decodePlusCode(code);
          expect(lat, greaterThanOrEqualTo(area.latitudeLo - epsilon),
              reason: '$lat not in $code');
          expect(lat, lessThanOrEqualTo(area.latitudeHi + epsilon),
              reason: '$lat not in $code');
          expect(lng, greaterThanOrEqualTo(area.longitudeLo - epsilon),
              reason: '$lng not in $code');
          expect(lng, lessThanOrEqualTo(area.longitudeHi + epsilon),
              reason: '$lng not in $code');
        }
      }
    });

    test('a longer code always describes a smaller area', () {
      double area(int length) {
        final a = decodePlusCode(encodePlusCode(23.7461, 90.3742, codeLength: length));
        return (a.latitudeHi - a.latitudeLo) * (a.longitudeHi - a.longitudeLo);
      }

      var previous = double.infinity;
      for (final length in [2, 4, 6, 8, 10, 11, 12, 13, 14, 15]) {
        final current = area(length);
        expect(current, lessThan(previous), reason: 'length $length');
        previous = current;
      }
    });
  });

  group('input handling', () {
    test('latitude is clamped and longitude wraps', () {
      // "Anywhere on Earth" includes inputs that have already been normalised
      // badly by something upstream.
      expect(() => encodePlusCode(91.0, 0.0), returnsNormally);
      expect(() => encodePlusCode(-91.0, 0.0), returnsNormally);
      expect(encodePlusCode(0.0, 181.0), encodePlusCode(0.0, -179.0));
      expect(encodePlusCode(0.0, -181.0), encodePlusCode(0.0, 179.0));
      expect(encodePlusCode(0.0, 360.0), encodePlusCode(0.0, 0.0));
    });

    test('the north pole still produces a decodable code', () {
      // Latitude exactly 90 has to be nudged south, or the code it produces
      // would describe a box that starts outside the world.
      final code = encodePlusCode(90.0, 0.0);
      expect(isFullPlusCode(code), isTrue);
      final area = decodePlusCode(code);
      expect(area.latitudeHi, lessThanOrEqualTo(90.0));
    });

    test('invalid code lengths are rejected', () {
      expect(() => encodePlusCode(0, 0, codeLength: 1),
          throwsA(isA<PlusCodeException>()));
      expect(() => encodePlusCode(0, 0, codeLength: 0),
          throwsA(isA<PlusCodeException>()));
      expect(() => encodePlusCode(0, 0, codeLength: -1),
          throwsA(isA<PlusCodeException>()));
      // Odd lengths below the pair section would give a 20:1 box.
      expect(() => encodePlusCode(0, 0, codeLength: 3),
          throwsA(isA<PlusCodeException>()));
      expect(() => encodePlusCode(0, 0, codeLength: 9),
          throwsA(isA<PlusCodeException>()));
      // Odd lengths above it are fine, and over-long ones are capped.
      expect(() => encodePlusCode(0, 0, codeLength: 11), returnsNormally);
      expect(encodePlusCode(0, 0, codeLength: 99).length,
          encodePlusCode(0, 0, codeLength: 15).length);
    });

    test('short codes cannot be decoded on their own', () {
      expect(() => decodePlusCode('+2VX'), throwsA(isA<PlusCodeException>()));
      expect(() => decodePlusCode('nonsense'),
          throwsA(isA<PlusCodeException>()));
    });

    test('the default length is the documented one', () {
      final code = encodePlusCode(23.7461, 90.3742);
      expect(code, encodePlusCode(23.7461, 90.3742, codeLength: defaultCodeLength));
      expect(decodePlusCode(code).codeLength, defaultCodeLength);
    });

    test('decoding accepts lower case', () {
      final upper = decodePlusCode('7FG49QCJ+2VX');
      final lower = decodePlusCode('7fg49qcj+2vx');
      expect(lower.latitudeLo, upper.latitudeLo);
      expect(lower.longitudeLo, upper.longitudeLo);
    });
  });
}
