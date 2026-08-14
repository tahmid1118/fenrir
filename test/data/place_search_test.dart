import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fenrir/src/data/place_repository.dart';

void main() {
  late PlaceRepository repository;

  setUpAll(() async {
    sqfliteFfiInit();
    repository = await PlaceRepository.openAt(
      p.absolute('assets/db/places.db'),
      factory: databaseFactoryFfi,
    );
  });

  tearDownAll(() async => repository.close());

  group('building the MATCH expression', () {
    test('quotes each token and appends a prefix wildcard', () {
      expect(PlaceRepository.buildMatchExpression('dhaka'), '"dhaka"*');
      expect(
        PlaceRepository.buildMatchExpression('san francisco'),
        '"san"* "francisco"*',
      );
    });

    test('neutralises FTS5 operators a user might reasonably type', () {
      // Each of these is syntax in FTS5's query language. Passing them through
      // raw throws, which for a search box means an apostrophe crashes the
      // screen.
      const hostile = [
        '"',
        '""',
        '*',
        'a AND b',
        'a OR b',
        'NOT a',
        'a NEAR b',
        'foo:bar',
        '(unbalanced',
        'x^2',
        "O'Brien",
        'Saint-Denis',
        '^anchor',
        'a - b',
        '{}',
      ];
      for (final input in hostile) {
        final expression = PlaceRepository.buildMatchExpression(input);
        if (expression == null) continue;
        // Every token is quoted, so nothing can be read as an operator.
        expect(expression, matches(RegExp(r'^("[^"]+"\*)( "[^"]+"\*)*$')),
            reason: input);
      }
    });

    test('returns null when nothing searchable remains', () {
      for (final empty in ['', '   ', '!!!', '***', '()', '-']) {
        expect(PlaceRepository.buildMatchExpression(empty), isNull,
            reason: '"$empty"');
      }
    });

    test('keeps non-Latin and accented characters', () {
      // The database holds names like Şobḩān and 上海; stripping to ASCII would
      // make them unsearchable in their own script.
      expect(PlaceRepository.buildMatchExpression('上海'), '"上海"*');
      expect(PlaceRepository.buildMatchExpression('Şobḩān'), '"Şobḩān"*');
      expect(PlaceRepository.buildMatchExpression('Köln'), '"Köln"*');
    });
  });

  group('searching', () {
    test('hostile input never throws', () async {
      // The real proof: these go all the way to SQLite.
      const hostile = [
        '"',
        '*',
        'a AND b',
        'NOT x',
        "O'Brien",
        'foo:bar',
        '(((',
        '^',
        '',
        '   ',
      ];
      for (final input in hostile) {
        await expectLater(repository.searchPlaces(input), completes,
            reason: input);
      }
    });

    test('finds a place by its full name', () async {
      final results = await repository.searchPlaces('Dhanmondi');
      expect(results, isNotEmpty);
      expect(results.first.place.name, 'Dhanmondi');
      expect(results.first.place.country, 'BD');
    });

    test('matches on a prefix, so it works while still typing', () async {
      final results = await repository.searchPlaces('Dhanmon');
      expect(results.map((r) => r.place.name), contains('Dhanmondi'));
    });

    test('prefers the large place when a name is ambiguous', () async {
      // Someone typing "paris" almost always means the French one, not any of
      // the several dozen others. Ordering by relevance score alone would not
      // distinguish them at all.
      final results = await repository.searchPlaces('Paris');
      expect(results, isNotEmpty);
      expect(results.first.place.name, 'Paris');
      expect(results.first.place.country, 'FR');
    });

    test('promotes an exact name match above a larger prefix match', () async {
      // "York" must not be buried under New York.
      final results = await repository.searchPlaces('York');
      expect(results.first.place.name, 'York');
    });

    test('respects the result limit', () async {
      final results = await repository.searchPlaces('San', limit: 5);
      expect(results.length, lessThanOrEqualTo(5));
    });

    test('a query matching nothing returns an empty list, not an error',
        () async {
      final results =
          await repository.searchPlaces('zzzzzzqqqqqxxxxx');
      expect(results, isEmpty);
    });

    test('multiple tokens are combined with AND, not OR', () async {
      // Comparing result counts would prove nothing here: both queries match
      // far more than any sane limit, so both come back saturated. The
      // property that matters is that every hit satisfies every token.
      final results = await repository.searchPlaces('San Fran', limit: 100);
      expect(results, isNotEmpty);

      for (final result in results) {
        final name = result.place.name.toLowerCase();
        expect(name, contains('san'), reason: result.place.name);
        expect(name, contains('fran'), reason: result.place.name);
      }
    });
  });

  group('distance and bearing from the current position', () {
    test('are attached when an origin is given', () async {
      final results = await repository.searchPlaces(
        'Dhanmondi',
        fromLatitude: 23.7461,
        fromLongitude: 90.3742,
      );
      expect(results, isNotEmpty);

      final first = results.first;
      expect(first.distanceKm, isNotNull);
      expect(first.distanceKm, closeTo(1.2917, 0.001));
      expect(first.bearingDeg, isNotNull);
      expect(first.bearingDeg, inInclusiveRange(0, 360));
      expect(first.compassPoint, isNotNull);
    });

    test('are null without an origin', () async {
      // Searching before the receiver has locked on is normal, and the results
      // are still useful.
      final results = await repository.searchPlaces('Dhanmondi');
      expect(results.first.distanceKm, isNull);
      expect(results.first.bearingDeg, isNull);
      expect(results.first.compassPoint, isNull);
    });

    test('a bearing is reported as a compass point a person can walk on',
        () async {
      final north = await repository.searchPlaces(
        'Dhaka',
        fromLatitude: 20.0,
        fromLongitude: 90.40744,
      );
      // Dhaka is due north of a point directly south of it.
      expect(north.first.compassPoint, 'N');

      final east = await repository.searchPlaces(
        'Dhaka',
        fromLatitude: 23.7104,
        fromLongitude: 80.0,
      );
      expect(east.first.compassPoint, 'E');
    });
  });

  group('NFR-2 search latency', () {
    test('stays responsive enough to run on every keystroke', () async {
      const queries = ['d', 'dh', 'dha', 'dhak', 'dhaka', 'san', 'lon', 'new'];
      final samples = <int>[];
      final stopwatch = Stopwatch();

      for (var round = 0; round < 5; round++) {
        for (final q in queries) {
          stopwatch
            ..reset()
            ..start();
          await repository.searchPlaces(q, limit: 30);
          stopwatch.stop();
          samples.add(stopwatch.elapsedMicroseconds);
        }
      }

      samples.sort();
      final p95 = samples[(samples.length * 0.95).floor()] / 1000.0;
      // ignore: avoid_print
      print('FR-8.1 search: median '
          '${(samples[samples.length ~/ 2] / 1000).toStringAsFixed(2)} ms, '
          'p95 ${p95.toStringAsFixed(2)} ms over ${samples.length} queries');

      // A search box that redraws per keystroke needs to stay well under a
      // frame budget or typing feels sticky.
      expect(p95, lessThan(50.0));
    });
  });
}
