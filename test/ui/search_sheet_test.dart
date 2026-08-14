import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/src/data/models.dart';
import 'package:fenrir/src/ui/search_sheet.dart';
import 'package:fenrir/src/ui/theme.dart';

PlaceSearchResult result(
  String name, {
  String country = 'BD',
  double? distanceKm,
  double? bearingDeg,
}) {
  return PlaceSearchResult(
    place: Place(
      id: name.hashCode,
      name: name,
      admin1: 'A Division',
      admin2: 'A District',
      country: country,
      latitude: 23.7,
      longitude: 90.4,
      population: 1000,
      timeZone: 'Asia/Dhaka',
    ),
    distanceKm: distanceKm,
    bearingDeg: bearingDeg,
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required Future<List<PlaceSearchResult>> Function(String) onSearch,
    ValueChanged<PlaceSearchResult>? onSelected,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildFenrirTheme(),
        home: Scaffold(
          body: SearchSheet(
            onSearch: onSearch,
            onSelected: onSelected ?? (_) {},
            // No debounce: the timer would otherwise still be pending when the
            // test ends, which flutter_test refuses to allow.
            debounce: Duration.zero,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('the empty state', () {
    testWidgets('invites a search and says it works offline', (tester) async {
      await pump(tester, onSearch: (_) async => const []);

      expect(find.text('Search 235,242 places'), findsOneWidget);
      // FR-9.2 is a selling point, so it is stated where the user is about to
      // type something they might not want leaving the device.
      expect(find.textContaining('Nothing is sent anywhere'), findsOneWidget);
    });
  });

  group('searching', () {
    testWidgets('shows results as the user types', (tester) async {
      await pump(
        tester,
        onSearch: (_) async => [result('Dhanmondi'), result('Dhaka')],
      );

      await tester.enterText(find.byType(TextField), 'dha');
      await tester.pump();
      await tester.pump();

      expect(find.text('Dhanmondi'), findsOneWidget);
      expect(find.text('Dhaka'), findsOneWidget);
    });

    testWidgets('passes the trimmed query through', (tester) async {
      final queries = <String>[];
      await pump(tester, onSearch: (q) async {
        queries.add(q);
        return const [];
      });

      await tester.enterText(find.byType(TextField), '  dhaka  ');
      await tester.pump();
      await tester.pump();

      expect(queries, ['dhaka']);
    });

    testWidgets('an empty query clears results without searching',
        (tester) async {
      var calls = 0;
      await pump(tester, onSearch: (_) async {
        calls++;
        return [result('Dhaka')];
      });

      await tester.enterText(find.byType(TextField), 'dha');
      await tester.pump();
      await tester.pump();
      expect(find.text('Dhaka'), findsOneWidget);
      final afterFirst = calls;

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.pump();

      expect(calls, afterFirst, reason: 'no query for empty input');
      expect(find.text('Dhaka'), findsNothing);
      expect(find.text('Search 235,242 places'), findsOneWidget);
    });

    testWidgets('says so when nothing matches', (tester) async {
      await pump(tester, onSearch: (_) async => const []);

      await tester.enterText(find.byType(TextField), 'zzzq');
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('No match for "zzzq"'), findsOneWidget);
      // Explains why, rather than leaving the user to guess.
      expect(find.textContaining('Only populated places'), findsOneWidget);
    });

    testWidgets('a slow earlier query cannot overwrite a later one',
        (tester) async {
      // Typing "d" then "dh" fires two searches. If the first resolves last,
      // a naive implementation shows results for a query the user has already
      // moved past.
      final slow = Completer<List<PlaceSearchResult>>();
      final fast = Completer<List<PlaceSearchResult>>();
      var call = 0;

      await pump(tester, onSearch: (_) async {
        call++;
        return call == 1 ? slow.future : fast.future;
      });

      await tester.enterText(find.byType(TextField), 'd');
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'dh');
      await tester.pump();

      fast.complete([result('Correct')]);
      await tester.pump();
      await tester.pump();
      expect(find.text('Correct'), findsOneWidget);

      slow.complete([result('Stale')]);
      await tester.pump();
      await tester.pump();

      expect(find.text('Stale'), findsNothing);
      expect(find.text('Correct'), findsOneWidget);
    });
  });

  group('FR-8.1 distance and bearing', () {
    testWidgets('are shown as a distance and a compass point', (tester) async {
      await pump(
        tester,
        onSearch: (_) async => [
          result('Northtown', distanceKm: 12.4, bearingDeg: 0),
          result('Eastville', distanceKm: 0.35, bearingDeg: 90),
        ],
      );

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      await tester.pump();

      // A compass point is what someone standing in a field can act on.
      expect(find.textContaining('12.4 km'), findsOneWidget);
      expect(find.textContaining('N'), findsWidgets);
      // Sub-kilometre distances read in metres.
      expect(find.textContaining('350 m'), findsOneWidget);
    });

    testWidgets('are omitted when there is no fix to measure from',
        (tester) async {
      await pump(tester, onSearch: (_) async => [result('Somewhere')]);

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      await tester.pump();

      // Searching before the receiver locks on is normal and still useful.
      expect(find.text('Somewhere'), findsOneWidget);
      final tile = tester.widget<ListTile>(find.byType(ListTile));
      expect(tile.trailing, isNull);
    });
  });

  group('selection', () {
    testWidgets('tapping a result reports it', (tester) async {
      PlaceSearchResult? selected;
      await pump(
        tester,
        onSearch: (_) async => [result('Dhanmondi')],
        onSelected: (r) => selected = r,
      );

      await tester.enterText(find.byType(TextField), 'dha');
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Dhanmondi'));
      await tester.pump();

      expect(selected, isNotNull);
      expect(selected!.place.name, 'Dhanmondi');
    });
  });

  group('NFR-7 accessibility', () {
    testWidgets('survives 200% text scaling', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildFenrirTheme(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: Scaffold(
              body: SearchSheet(
                onSearch: (_) async => [
                  result('A very long place name indeed',
                      distanceKm: 123.4, bearingDeg: 200),
                ],
                onSelected: (_) {},
                debounce: Duration.zero,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
