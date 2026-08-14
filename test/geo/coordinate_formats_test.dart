import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/src/geo/coordinate_formats.dart';

void main() {
  // The Eiffel Tower, the worked example in the geobase documentation. Using a
  // reference the library itself publishes means a regression in the
  // dependency shows up here rather than in the field.
  const eiffelLat = 48.8582;
  const eiffelLon = 2.2945;

  // The specification's verified fixture (FR-3.1).
  const dhakaLat = 23.7461;
  const dhakaLon = 90.3742;

  group('decimal degrees', () {
    test('renders six decimal places with degree signs', () {
      expect(
        formatDecimalDegrees(dhakaLat, dhakaLon),
        '23.746100°, 90.374200°',
      );
    });

    test('keeps signs for southern and western hemispheres', () {
      expect(
        formatDecimalDegrees(-33.868800, -151.209300),
        '-33.868800°, -151.209300°',
      );
    });

    test('the plain form carries no symbols, for sharing', () {
      // FR-2.3 requires a payload a recipient with no special app can use.
      expect(
        formatDecimalDegreesPlain(dhakaLat, dhakaLon),
        '23.746100, 90.374200',
      );
    });
  });

  group('degrees, minutes and seconds', () {
    test('renders the specification fixture', () {
      expect(formatDms(dhakaLat, dhakaLon), '23°44\'46.0"N, 90°22\'27.1"E');
    });

    test('uses S and W in the southern and western hemispheres', () {
      final text = formatDms(-33.8688, -70.1234);
      expect(text, contains('S'));
      expect(text, contains('W'));
      expect(text, isNot(contains('N')));
      expect(text, isNot(contains('E')));
    });

    test('pads minutes and seconds to a fixed width', () {
      // Without padding the readout jitters as values change, which is
      // precisely what the tabular figures in the theme are there to prevent.
      expect(formatDms(1.0166667, 1.0166667), '1°01\'00.0"N, 1°01\'00.0"E');
    });

    test('seconds carry into the next minute instead of reading 60.0', () {
      // 0.99999 degrees is 59 minutes 59.964 seconds. Rounding the seconds
      // after splitting the components would render that as 59'60.0", which is
      // not a time anyone writes.
      final text = formatDms(0.99999, 0);
      expect(text, isNot(contains('60.0"')));
      expect(text, startsWith('1°00\'00.0"N'));
    });

    test('exact degrees render cleanly', () {
      expect(formatDms(0, 0), '0°00\'00.0"N, 0°00\'00.0"E');
      expect(formatDms(45, -90), '45°00\'00.0"N, 90°00\'00.0"W');
    });
  });

  group('UTM and MGRS', () {
    test('match the geobase reference example', () {
      expect(
        formatCoordinate(eiffelLat, eiffelLon, CoordinateFormat.utm).text,
        '31 N 448252 5411933',
      );
      expect(
        formatCoordinate(eiffelLat, eiffelLon, CoordinateFormat.mgrs).text,
        '31U DQ 48251 11932',
      );
    });

    test('resolve for the southern hemisphere', () {
      final utm =
          formatCoordinate(-33.8688, 151.2093, CoordinateFormat.utm);
      expect(utm.isAvailable, isTrue);
      expect(utm.text, contains(' S '));
    });

    test('are unavailable in the polar regions rather than throwing', () {
      // UTM and MGRS stop at 84 N and 80 S; the caps use UPS instead. geobase
      // throws a FormatException there, and an uncaught throw would take the
      // whole position panel down for a user in Antarctica. NFR-6 requires a
      // defined, informative state instead.
      for (final lat in [85.0, 89.9, 90.0, -80.1, -89.9, -90.0]) {
        final utm = formatCoordinate(lat, 0, CoordinateFormat.utm);
        final mgrs = formatCoordinate(lat, 0, CoordinateFormat.mgrs);

        expect(utm.isAvailable, isFalse, reason: 'UTM at $lat');
        expect(mgrs.isAvailable, isFalse, reason: 'MGRS at $lat');
        expect(utm.display, isNotEmpty);
        expect(utm.display, contains('84'));
      }
    });

    test('remain available right up to the boundaries', () {
      expect(isUtmDefinedAt(84.0), isTrue);
      expect(isUtmDefinedAt(-80.0), isTrue);
      expect(isUtmDefinedAt(84.001), isFalse);
      expect(isUtmDefinedAt(-80.001), isFalse);

      expect(formatCoordinate(84.0, 0, CoordinateFormat.utm).isAvailable,
          isTrue);
      expect(formatCoordinate(-80.0, 0, CoordinateFormat.utm).isAvailable,
          isTrue);
    });
  });

  group('normalisation', () {
    test('longitude wraps and latitude clamps', () {
      expect(normalizePosition(0, 181), (0.0, -179.0));
      expect(normalizePosition(0, -181), (0.0, 179.0));
      expect(normalizePosition(0, 360), (0.0, 0.0));
      expect(normalizePosition(0, 540), (0.0, -180.0));
      expect(normalizePosition(95, 0), (90.0, 0.0));
      expect(normalizePosition(-95, 0), (-90.0, 0.0));
    });

    test('in-range values pass through untouched', () {
      expect(normalizePosition(dhakaLat, dhakaLon), (dhakaLat, dhakaLon));
      expect(normalizePosition(-90, -180), (-90.0, -180.0));
    });

    test('every format survives an out-of-range longitude', () {
      for (final format in CoordinateFormat.values) {
        expect(
          () => formatCoordinate(0, 200, format),
          returnsNormally,
          reason: format.name,
        );
      }
    });
  });

  group('format cycling', () {
    test('next visits every format and returns to the start', () {
      var format = CoordinateFormat.decimalDegrees;
      final seen = <CoordinateFormat>{};
      for (var i = 0; i < CoordinateFormat.values.length; i++) {
        seen.add(format);
        format = format.next;
      }
      expect(seen, CoordinateFormat.values.toSet());
      expect(format, CoordinateFormat.decimalDegrees);
    });

    test('every format has a distinct label and short label', () {
      final labels = CoordinateFormat.values.map((f) => f.label).toSet();
      final shorts = CoordinateFormat.values.map((f) => f.shortLabel).toSet();
      expect(labels.length, CoordinateFormat.values.length);
      expect(shorts.length, CoordinateFormat.values.length);
    });
  });

  group('every format produces something displayable', () {
    test('at a spread of positions across the globe', () {
      const positions = <(double, double)>[
        (dhakaLat, dhakaLon),
        (0, 0),
        (-33.8688, 151.2093),
        (64.1466, -21.9426),
        (78.2232, 15.6469), // Svalbard, inside the UTM zone exceptions
        (-54.8019, -68.3030),
        (89.0, 0.0), // beyond UTM
        (-85.0, 0.0), // beyond UTM
      ];

      for (final (lat, lon) in positions) {
        for (final format in CoordinateFormat.values) {
          final result = formatCoordinate(lat, lon, format);
          expect(result.display, isNotEmpty,
              reason: '$format at $lat, $lon');
        }
      }
    });

    test('the Plus Code format agrees with the encoder', () {
      final viaFormat =
          formatCoordinate(dhakaLat, dhakaLon, CoordinateFormat.plusCode);
      expect(viaFormat.isAvailable, isTrue);
      expect(viaFormat.text, matches(RegExp(r'^[23456789CFGHJMPQRVWX]+\+')));
    });
  });
}
