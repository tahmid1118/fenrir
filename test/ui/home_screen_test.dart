import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:fenrir/src/data/bundled_asset.dart';
import 'package:fenrir/src/data/models.dart';
import 'package:fenrir/src/location/location_service.dart';
import 'package:fenrir/src/location/position_fix.dart';
import 'package:fenrir/src/map/mbtiles_tile_provider.dart';
import 'package:fenrir/src/ui/home_controller.dart';
import 'package:fenrir/src/ui/home_screen.dart';
import 'package:fenrir/src/ui/position_panel.dart';
import 'package:fenrir/src/ui/theme.dart';

class FakeSource implements LocationSource {
  FakeSource({
    this.servicesEnabled = true,
    this.permission = LocationPermission.whileInUse,
  });

  bool servicesEnabled;
  LocationPermission permission;
  final controller = StreamController<PositionFix>.broadcast();

  @override
  Future<bool> isLocationServiceEnabled() async => servicesEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async => permission;

  @override
  Stream<PositionFix> positions() => controller.stream;

  Future<void> close() => controller.close();
}

/// An in-memory stand-in for the bundled data.
///
/// No SQLite, no files, no isolates. `sqflite_common_ffi` runs the database in
/// a background isolate and talks to it over ports, and inside the fake-async
/// zone `testWidgets` installs those ports are never pumped — a real query made
/// from a widget test never returns at all. The shipped archives are exercised
/// by `place_repository_test` and `mbtiles_tile_provider_test` instead, which
/// use plain `test()`.
class FakeData implements HomeDataSource {
  FakeData({this.match, this.failWith});

  /// What every lookup resolves to. Null models FR-3.3's open water.
  PlaceMatch? match;

  /// When set, [prepare] throws it.
  final Object? failWith;

  int lookups = 0;

  @override
  MbTilesTileProvider? tileProvider;

  @override
  Future<void> prepare() async {
    final failure = failWith;
    if (failure != null) throw failure;
  }

  @override
  Future<PlaceMatch?> nearestPlace(double latitude, double longitude) async {
    lookups++;
    return match;
  }

  /// What every search returns, regardless of the query.
  List<PlaceSearchResult> searchResults = const [];

  String? lastQuery;

  @override
  Future<List<PlaceSearchResult>> searchPlaces(
    String query, {
    double? fromLatitude,
    double? fromLongitude,
  }) async {
    lastQuery = query;
    return searchResults;
  }

  /// Saved positions, held in memory.
  final List<Waypoint> saved = [];

  /// When set, [addWaypoint] throws it.
  Object? saveFailure;

  var _nextId = 1;

  @override
  Future<List<Waypoint>> waypoints() async =>
      saved.reversed.toList(growable: false);

  @override
  Future<Waypoint> addWaypoint(Waypoint waypoint) async {
    final failure = saveFailure;
    if (failure != null) throw failure;
    final stored = waypoint.copyWith(id: _nextId++);
    saved.add(stored);
    return stored;
  }

  @override
  Future<bool> removeWaypoint(int id) async {
    final before = saved.length;
    saved.removeWhere((w) => w.id == id);
    return saved.length != before;
  }

  @override
  Future<void> dispose() async {}
}

/// The FR-3.1 fixture, as the real database returns it.
final dhanmondi = PlaceMatch(
  place: const Place(
    id: 7683974,
    name: 'Dhanmondi',
    admin1: 'Dhaka Division',
    admin2: 'Dhaka',
    country: 'BD',
    latitude: 23.74,
    longitude: 90.385,
    population: 54210,
    timeZone: 'Asia/Dhaka',
  ),
  distanceKm: 1.2917,
  proximity: Proximity.inside,
);

void main() {
  // Both the service and the screen normally run their own periodic timer, and
  // flutter_test refuses to finish a test while one is pending. Driving them
  // from streams the test owns removes the timers and, more usefully, makes the
  // passage of time something the test states rather than waits for.
  late StreamController<void> serviceTicker;
  late StreamController<DateTime> screenClock;

  setUp(() {
    serviceTicker = StreamController<void>.broadcast();
    screenClock = StreamController<DateTime>.broadcast();
  });

  tearDown(() async {
    await serviceTicker.close();
    await screenClock.close();
  });

  HomeController controllerWith(
    FakeSource source, {
    FakeData? data,
  }) {
    return HomeController(
      locationService: LocationService(
        source: source,
        ticker: serviceTicker.stream,
      ),
      data: data ?? FakeData(match: dhanmondi),
    );
  }

  Future<HomeController> pumpHome(
    WidgetTester tester,
    FakeSource source, {
    FakeData? data,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final controller = controllerWith(source, data: data);
    addTearDown(controller.dispose);
    addTearDown(source.close);

    await controller.start();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFenrirTheme(),
        home: HomeScreen(controller: controller, clock: screenClock.stream),
      ),
    );
    await tester.pump();
    return controller;
  }

  group('NFR-6 every condition has a defined, informative state', () {
    testWidgets('services disabled explains what to switch on', (tester) async {
      await pumpHome(tester, FakeSource(servicesEnabled: false));

      expect(find.text('Location services are off'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      // Granting permission would not help, so the copy must not ask for it.
      expect(find.textContaining('permission'), findsNothing);
    });

    testWidgets('a soft permission denial offers to ask again', (tester) async {
      await pumpHome(
        tester,
        FakeSource(permission: LocationPermission.denied),
      );

      expect(find.text('Location permission needed'), findsOneWidget);
      expect(find.text('Allow location'), findsOneWidget);
      // FR-9.2 is a selling point, not fine print.
      expect(find.textContaining('never leaves the device'), findsOneWidget);
    });

    testWidgets('a permanent denial sends the user to settings',
        (tester) async {
      await pumpHome(
        tester,
        FakeSource(permission: LocationPermission.deniedForever),
      );

      expect(find.text('Location permission needed'), findsOneWidget);
      expect(find.textContaining('system settings'), findsOneWidget);
    });

    testWidgets('searching says why the first fix is slow', (tester) async {
      await pumpHome(tester, FakeSource());

      // The delay is a direct consequence of FR-1.1 forbidding network
      // positioning, so the UI explains it rather than looking broken.
      expect(find.text('Acquiring satellites'), findsOneWidget);
      expect(find.textContaining('GNSS receiver directly'), findsOneWidget);
    });

    testWidgets('an asset failure degrades rather than blanking',
        (tester) async {
      await pumpHome(
        tester,
        FakeSource(),
        data: FakeData(failWith: const BundledAssetException('disk full')),
      );

      expect(find.textContaining('disk full'), findsOneWidget);
      // Still a working screen, because coordinates are computed rather than
      // looked up.
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('a resolved position', () {
    testWidgets('shows the place, the coordinates and the fix quality',
        (tester) async {
      final source = FakeSource();
      await pumpHome(tester, source);

      source.controller.add(PositionFix(
        latitude: 23.7461,
        longitude: 90.3742,
        accuracyMeters: 6,
        timestamp: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('GPS fix'), findsOneWidget);
      expect(find.text('±6.0 m'), findsOneWidget);
      // The FR-3.1 fixture, resolved through the real database.
      expect(find.text('Dhanmondi, Dhaka, Dhaka Division, BD'), findsOneWidget);
      expect(find.text('23.746100°, 90.374200°'), findsOneWidget);
    });

    testWidgets('open water says so instead of naming a distant place',
        (tester) async {
      final source = FakeSource();
      // A null match is what the real repository returns here; the assertion
      // that 30.0,-40.0 actually produces one lives in place_repository_test.
      await pumpHome(tester, source, data: FakeData(match: null));

      // FR-3.3: the specification's mid-Atlantic fixture.
      source.controller.add(PositionFix(
        latitude: 30.0,
        longitude: -40.0,
        accuracyMeters: 8,
        timestamp: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('No known place nearby'), findsOneWidget);
    });

    testWidgets('a coarse fix is labelled approximate, not confident',
        (tester) async {
      final source = FakeSource();
      await pumpHome(tester, source);

      source.controller.add(PositionFix(
        latitude: 23.7461,
        longitude: 90.3742,
        accuracyMeters: 250,
        timestamp: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Approximate'), findsOneWidget);
      expect(find.textContaining('low precision'), findsOneWidget);
      expect(find.text('GPS fix'), findsNothing);
    });

    testWidgets('an aged fix is labelled stale', (tester) async {
      final source = FakeSource();
      await pumpHome(tester, source);

      source.controller.add(PositionFix(
        latitude: 23.7461,
        longitude: 90.3742,
        accuracyMeters: 5,
        timestamp: DateTime.now().subtract(const Duration(minutes: 2)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Stale fix'), findsOneWidget);
      expect(find.textContaining('Last seen'), findsOneWidget);
    });
  });

  group('FR-2.1 switching notation', () {
    testWidgets('every format is offered and switching re-renders',
        (tester) async {
      final source = FakeSource();
      await pumpHome(tester, source);

      source.controller.add(PositionFix(
        latitude: 48.8582,
        longitude: 2.2945,
        accuracyMeters: 5,
        timestamp: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('DD'), findsOneWidget);
      expect(find.text('DMS'), findsOneWidget);
      expect(find.text('UTM'), findsOneWidget);
      expect(find.text('MGRS'), findsOneWidget);
      expect(find.text('Plus Code'), findsOneWidget);

      await tester.tap(find.text('MGRS'));
      await tester.pump();
      expect(find.text('31U DQ 48251 11932'), findsOneWidget);

      await tester.tap(find.text('UTM'));
      await tester.pump();
      expect(find.text('31 N 448252 5411933'), findsOneWidget);
    });

    testWidgets('a notation undefined at this latitude says so', (tester) async {
      final source = FakeSource();
      await pumpHome(tester, source);

      // Beyond the UTM limit. geobase throws here; the UI must not.
      source.controller.add(PositionFix(
        latitude: 88.0,
        longitude: 0.0,
        accuracyMeters: 5,
        timestamp: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('UTM'));
      await tester.pump();

      expect(find.textContaining('Not defined above'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('FR-6.1 saving a position', () {
    testWidgets('captures the fix, its accuracy and the resolved place',
        (tester) async {
      final source = FakeSource();
      final data = FakeData(match: dhanmondi);
      await pumpHome(tester, source, data: data);

      source.controller.add(PositionFix(
        latitude: 23.7461,
        longitude: 90.3742,
        accuracyMeters: 6,
        timestamp: DateTime.now(),
        altitudeMeters: 27.4,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(data.saved, hasLength(1));
      final saved = data.saved.single;
      expect(saved.latitude, 23.7461);
      expect(saved.longitude, 90.3742);
      // A waypoint taken with a coarse fix means something different from one
      // taken with a sharp fix, so the accuracy is part of the record.
      expect(saved.accuracyMeters, 6);
      expect(saved.altitudeMeters, 27.4);
      // What the user saw when they decided the spot mattered.
      expect(saved.placeName, 'Dhanmondi, Dhaka, Dhaka Division, BD');
      expect(saved.savedAt.isUtc, isTrue);
    });

    testWidgets('confirms the save and offers to undo it', (tester) async {
      final source = FakeSource();
      final data = FakeData(match: dhanmondi);
      await pumpHome(tester, source, data: data);

      source.controller.add(PositionFix(
        latitude: 23.7461,
        longitude: 90.3742,
        accuracyMeters: 6,
        timestamp: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Saved Dhanmondi'), findsOneWidget);

      // Saving is one tap, so undoing it must be too.
      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(data.saved, isEmpty);
    });

    testWidgets('a save that fails says so rather than silently doing nothing',
        (tester) async {
      final source = FakeSource();
      final data = FakeData(match: dhanmondi)
        ..saveFailure = StateError('disk full');
      await pumpHome(tester, source, data: data);

      source.controller.add(PositionFix(
        latitude: 23.7461,
        longitude: 90.3742,
        accuracyMeters: 6,
        timestamp: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Could not save'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('open water saves with coordinates as the name',
        (tester) async {
      // FR-3.3's no-place-nearby case still has to be savable.
      final source = FakeSource();
      final data = FakeData(match: null);
      await pumpHome(tester, source, data: data);

      source.controller.add(PositionFix(
        latitude: 30.0,
        longitude: -40.0,
        accuracyMeters: 8,
        timestamp: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(data.saved, hasLength(1));
      expect(data.saved.single.placeName, isNull);
      expect(data.saved.single.displayLabel, '30.00000, -40.00000');
    });

    testWidgets('there is nothing to save without a fix', (tester) async {
      final source = FakeSource();
      final data = FakeData(match: dhanmondi);
      await pumpHome(tester, source, data: data);

      // Still searching: the panel, and so the save action, is not on screen.
      expect(find.widgetWithText(TextButton, 'Save'), findsNothing);
      expect(data.saved, isEmpty);
    });
  });

  group('FR-2.3 share payload', () {
    testWidgets('is usable by a recipient with no special app', (tester) async {
      final source = FakeSource();
      await pumpHome(tester, source);

      source.controller.add(PositionFix(
        latitude: 23.7461,
        longitude: 90.3742,
        accuracyMeters: 6,
        timestamp: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final panel = tester.widget<PositionPanel>(find.byType(PositionPanel));
      final text = panel.shareText();

      expect(text, contains('Dhanmondi'));
      // Bare decimal degrees: what every map and search engine accepts.
      expect(text, contains('23.746100, 90.374200'));
      expect(text, contains('Plus Code:'));
      expect(text, contains('6 m'));
      // No app-specific scheme that a recipient could not act on.
      expect(text, isNot(contains('fenrir://')));
    });
  });

  group('NFR-7 accessibility', () {
    testWidgets('survives 200% text scaling without overflowing',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final source = FakeSource();
      final controller = controllerWith(source);
      addTearDown(controller.dispose);
      addTearDown(source.close);
      await controller.start();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildFenrirTheme(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: HomeScreen(
              controller: controller,
              clock: screenClock.stream,
            ),
          ),
        ),
      );
      source.controller.add(PositionFix(
        latitude: 23.7461,
        longitude: 90.3742,
        accuracyMeters: 6,
        timestamp: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
    });

    testWidgets('the position readout is exposed as text', (tester) async {
      final source = FakeSource();
      await pumpHome(tester, source);

      source.controller.add(PositionFix(
        latitude: 23.7461,
        longitude: 90.3742,
        accuracyMeters: 6,
        timestamp: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // NFR-7 requires coordinates be readable as text, and SelectableText
      // means they can also be selected and copied by hand.
      expect(find.byType(SelectableText), findsWidgets);
    });
  });
}
