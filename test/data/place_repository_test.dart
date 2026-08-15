import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fenrir/src/data/models.dart';
import 'package:fenrir/src/data/place_repository.dart';

void main() {
  // These run against the real shipped 25.8 MB database, not a fixture and not
  // a mock. The verified results in the requirements specification are only
  // meaningful as tests if they are checked against the bytes that ship.
  late PlaceRepository repository;

  setUpAll(() async {
    sqfliteFfiInit();
    // A relative path resolves against sqflite_common_ffi's own databases
    // directory rather than the project root, so it must be absolute.
    repository = await PlaceRepository.openAt(
      p.absolute('assets/db/places.db'),
      factory: databaseFactoryFfi,
    );
  });

  tearDownAll(() async => repository.close());

  group('FR-3.1 resolving a position to a place', () {
    test('the specification fixture resolves exactly as recorded', () async {
      // "Verified working: 23.7461, 90.3742 resolves to Dhanmondi, Dhaka,
      // Dhaka Division, BD at 1.29 km."
      final match = await repository.nearestPlace(23.7461, 90.3742);

      expect(match, isNotNull);
      expect(match!.place.name, 'Dhanmondi');
      expect(match.place.admin2, 'Dhaka');
      expect(match.place.admin1, 'Dhaka Division');
      expect(match.place.country, 'BD');
      expect(match.distanceKm, closeTo(1.2917, 0.001));
      expect(match.proximity, Proximity.inside);
      expect(
        match.place.displayName,
        'Dhanmondi, Dhaka, Dhaka Division, BD',
      );
    });

    test('resolves across a spread of populated regions', () async {
      const positions = <(String, double, double)>[
        ('central London', 51.5074, -0.1278),
        ('Manhattan', 40.7580, -73.9855),
        ('Sydney', -33.8688, 151.2093),
        ('Nairobi', -1.2921, 36.8219),
        ('Reykjavik', 64.1466, -21.9426),
        ('Sao Paulo', -23.5505, -46.6333),
      ];

      for (final (label, lat, lon) in positions) {
        final match = await repository.nearestPlace(lat, lon);
        expect(match, isNotNull, reason: label);
        expect(match!.place.name, isNotEmpty, reason: label);
        expect(match.place.country.length, 2, reason: label);
        expect(match.distanceKm, lessThan(25.0), reason: label);
      }
    });

    test('the returned distance is the true haversine distance', () async {
      final match = await repository.nearestPlace(48.8582, 2.2945);
      expect(match, isNotNull);
      // Recomputing independently guards against the distance being carried
      // over from the bounding-box approximation rather than measured.
      const earthRadiusKm = 6371.0088;
      final lat1 = 48.8582 * math.pi / 180;
      final lat2 = match!.place.latitude * math.pi / 180;
      final dLat = lat2 - lat1;
      final dLon = (match.place.longitude - 2.2945) * math.pi / 180;
      final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
          math.cos(lat1) *
              math.cos(lat2) *
              math.sin(dLon / 2) *
              math.sin(dLon / 2);
      final expected =
          earthRadiusKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
      expect(match.distanceKm, closeTo(expected, 1e-9));
    });
  });

  group('FR-3.2 reporting distance honestly', () {
    test('a position on top of a place reads as inside it', () async {
      final match = await repository.nearestPlace(23.74, 90.385);
      expect(match, isNotNull);
      expect(match!.distanceKm, lessThan(PlaceRepository.insideRadiusKm));
      expect(match.proximity, Proximity.inside);
    });

    test('a remote position reads as near, not inside', () async {
      // The Sundarbans: inside Bangladesh, but far from any of the 161 places
      // GeoNames records for the country. This is the coverage gap that makes
      // FR-3.2 necessary, exercised against real data.
      final match = await repository.nearestPlace(21.95, 89.18);
      expect(match, isNotNull);
      expect(match!.distanceKm,
          greaterThan(PlaceRepository.insideRadiusKm));
      expect(match.proximity, Proximity.near);
    });

    test('a real neighbourhood the database does not cover reads as near',
        () async {
      // Rampura/Banasree, Dhaka. Neither is in the bundled database -- exactly
      // the coverage gap FR-3.4 exists to eventually close -- so the nearest
      // entry is Paltan, 3.458 km away. A user there was shown "Paltan, Dhaka,
      // Dhaka Division, BD" with no qualifier, reading as if they were
      // standing in it. That is the failure FR-3.2 exists to prevent, just at
      // city scale rather than the rural scale the specification's own
      // worked example worries about.
      final match = await repository.nearestPlace(23.765824, 90.424765);
      expect(match, isNotNull);
      expect(match!.place.name, 'Paltan');
      expect(match.distanceKm, closeTo(3.458, 0.01));
      expect(match.proximity, Proximity.near,
          reason: '3.5 km away is a different neighbourhood, not "in" '
              'the matched place');
    });

    test('proximity always agrees with the reported distance', () async {
      const positions = <(double, double)>[
        (23.7461, 90.3742),
        (21.95, 89.18),
        (51.5074, -0.1278),
        (-25.0, 130.0), // central Australian desert
        (68.0, 100.0), // Siberian interior
      ];

      for (final (lat, lon) in positions) {
        final match = await repository.nearestPlace(lat, lon);
        if (match == null) continue;
        final expected = match.distanceKm <= PlaceRepository.insideRadiusKm
            ? Proximity.inside
            : Proximity.near;
        expect(match.proximity, expected, reason: '$lat, $lon');
      }
    });
  });

  group('FR-3.3 returning nothing over open water', () {
    test('the mid-Atlantic fixture resolves to nothing', () async {
      // "Verified: 30.0, -40.0 correctly returns nothing." The nearest place
      // on Earth is in the Azores, 1,317 km away; anything other than null
      // here is the confidently-wrong failure the requirement forbids.
      expect(await repository.nearestPlace(30.0, -40.0), isNull);
    });

    test('other open ocean resolves to nothing', () async {
      const openWater = <(String, double, double)>[
        ('South Pacific gyre', -40.0, -140.0),
        ('central Indian Ocean', -20.0, 80.0),
        ('North Pacific', 40.0, -170.0),
        ('Southern Ocean', -60.0, 0.0),
      ];

      for (final (label, lat, lon) in openWater) {
        expect(await repository.nearestPlace(lat, lon), isNull,
            reason: label);
      }
    });

    test('nothing is ever returned beyond the search ceiling', () async {
      const probes = <(double, double)>[
        (30.0, -40.0),
        (-40.0, -140.0),
        (0.0, -150.0),
        (-85.0, 0.0),
      ];
      for (final (lat, lon) in probes) {
        final match = await repository.nearestPlace(lat, lon);
        if (match != null) {
          expect(match.distanceKm,
              lessThanOrEqualTo(PlaceRepository.searchRadiiKm.last),
              reason: '$lat, $lon');
        }
      }
    });
  });

  group('the database is the one the specification measured', () {
    test('row count and country counts match exactly', () async {
      // A guard against the asset being swapped or rebuilt differently. Every
      // distance fixture above rests on this being the same data.
      final db = await databaseFactoryFfi.openDatabase(
        p.absolute('assets/db/places.db'),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      addTearDown(db.close);

      Future<int> count(String where) async {
        final rows = await db.rawQuery('SELECT count(*) AS n FROM place $where');
        return rows.first['n']! as int;
      }

      expect(await count(''), 235242);
      expect(await count("WHERE country='BD'"), 161);
      expect(await count("WHERE country='US'"), 21782);
    });
  });

  group('anywhere on Earth', () {
    test('the antimeridian is searched on both sides', () {
      // A single lon_e5 BETWEEN cannot express a wrapped range: +179 to -179
      // selects nothing at all, which would silently report no place nearby
      // for everyone near the 180th meridian.
      final boxes = PlaceRepository.boundingBoxes(-16.5, 179.9, 25.0);
      expect(boxes.length, 2);
      expect(boxes.any((b) => b.maxLonE5 >= 18000000), isTrue);
      expect(boxes.any((b) => b.minLonE5 <= -18000000), isTrue);
    });

    test('resolves either side of the antimeridian', () async {
      // Taveuni in Fiji sits almost exactly on the 180th meridian.
      final east = await repository.nearestPlace(-16.8, 179.98);
      final west = await repository.nearestPlace(-16.8, -179.98);
      expect(east, isNotNull);
      expect(west, isNotNull);
      expect(east!.distanceKm, lessThan(250.0));
      expect(west!.distanceKm, lessThan(250.0));
    });

    test('polar positions widen to every longitude instead of overflowing',
        () {
      for (final lat in [89.9, -89.9, 90.0, -90.0]) {
        final boxes = PlaceRepository.boundingBoxes(lat, 0, 25.0);
        expect(boxes.length, 1, reason: 'at $lat');
        expect(boxes.first.minLonE5, lessThanOrEqualTo(-18000000),
            reason: 'at $lat');
        expect(boxes.first.maxLonE5, greaterThanOrEqualTo(18000000),
            reason: 'at $lat');
      }
    });

    test('polar and extreme positions never throw', () async {
      const extremes = <(double, double)>[
        (90.0, 0.0),
        (-90.0, 0.0),
        (89.99, 179.99),
        (-89.99, -179.99),
        (0.0, 180.0),
        (0.0, -180.0),
      ];
      for (final (lat, lon) in extremes) {
        await expectLater(repository.nearestPlace(lat, lon), completes,
            reason: '$lat, $lon');
      }
    });

    test('the box over-covers rather than under-covers', () {
      // Being too generous costs a few extra rows; being too small silently
      // loses the correct answer.
      const lat = 60.0;
      const radiusKm = 25.0;
      final box = PlaceRepository.boundingBoxes(lat, 10.0, radiusKm).single;
      final halfSpanDegLat = (box.maxLatE5 - box.minLatE5) / 2 / 100000;
      expect(halfSpanDegLat * 111.32, greaterThanOrEqualTo(radiusKm));
    });
  });

  group('display formatting', () {
    test('a null second-level division does not leave a doubled comma',
        () async {
      const place = Place(
        id: 1,
        name: 'Somewhere',
        admin1: 'A Region',
        admin2: null,
        country: 'XX',
        latitude: 0,
        longitude: 0,
        population: 0,
        timeZone: 'UTC',
      );
      expect(place.displayName, 'Somewhere, A Region, XX');
      expect(place.displayName, isNot(contains(', ,')));
    });

    test('a repeated component is collapsed', () async {
      // Dhaka carries Dhaka as both its own name and its second-level
      // division, which would otherwise render as "Dhaka, Dhaka, Dhaka
      // Division, BD". Asserting the whole string rather than the absence of a
      // substring: "Dhaka, Dhaka" is a prefix of the correct output too, so a
      // substring check would fail on a perfectly good result.
      final match = await repository.nearestPlace(23.7104, 90.4074);
      expect(match, isNotNull);
      expect(match!.place.name, 'Dhaka');
      expect(match.place.admin2, 'Dhaka');
      expect(match.place.displayName, 'Dhaka, Dhaka Division, BD');
    });

    test('similar but distinct components both survive', () {
      const place = Place(
        id: 2,
        name: 'Dhaka',
        admin1: 'Dhaka Division',
        admin2: 'Dhaka',
        country: 'BD',
        latitude: 0,
        longitude: 0,
        population: 0,
        timeZone: 'Asia/Dhaka',
      );
      expect(place.displayName, 'Dhaka, Dhaka Division, BD');
    });

    test('no resolved place ever renders an empty name', () async {
      const positions = <(double, double)>[
        (23.7461, 90.3742),
        (51.5074, -0.1278),
        (-33.8688, 151.2093),
        (35.6762, 139.6503),
      ];
      for (final (lat, lon) in positions) {
        final match = await repository.nearestPlace(lat, lon);
        expect(match!.place.displayName, isNotEmpty);
        expect(match.place.displayName.trim(), match.place.displayName);
      }
    });
  });

  group('NFR-2 place resolution latency', () {
    test('95th percentile is under 50 ms', () async {
      // Deliberately biased toward inhabited longitudes and latitudes, so the
      // measurement reflects the work a real user causes rather than mostly
      // timing empty ocean queries.
      final random = math.Random(20260814);
      final samples = <int>[];
      final stopwatch = Stopwatch();

      for (var i = 0; i < 300; i++) {
        final lat = -55.0 + random.nextDouble() * 125.0;
        final lon = -180.0 + random.nextDouble() * 360.0;
        stopwatch
          ..reset()
          ..start();
        await repository.nearestPlace(lat, lon);
        stopwatch.stop();
        samples.add(stopwatch.elapsedMicroseconds);
      }

      samples.sort();
      final p95 = samples[(samples.length * 0.95).floor()] / 1000.0;
      final median = samples[samples.length ~/ 2] / 1000.0;
      final worst = samples.last / 1000.0;

      // Recorded so the numbers appear in CI output as evidence, not just as a
      // pass or fail.
      // ignore: avoid_print
      print('NFR-2: median ${median.toStringAsFixed(2)} ms, '
          'p95 ${p95.toStringAsFixed(2)} ms, '
          'worst ${worst.toStringAsFixed(2)} ms over ${samples.length} lookups');

      expect(p95, lessThan(50.0));
    });

    test('the dense-city case stays fast', () async {
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 50; i++) {
        await repository.nearestPlace(51.5074, -0.1278);
      }
      stopwatch.stop();
      final perLookup = stopwatch.elapsedMicroseconds / 50 / 1000.0;
      expect(perLookup, lessThan(50.0));
    });
  });
}
