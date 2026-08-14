import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:fenrir/src/location/location_service.dart';
import 'package:fenrir/src/location/position_fix.dart';

class FakeSource implements LocationSource {
  FakeSource({
    this.servicesEnabled = true,
    this.permission = LocationPermission.whileInUse,
    this.permissionAfterRequest,
  });

  bool servicesEnabled;
  LocationPermission permission;
  LocationPermission? permissionAfterRequest;

  int requestCount = 0;
  final positionController = StreamController<PositionFix>.broadcast();

  @override
  Future<bool> isLocationServiceEnabled() async => servicesEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requestCount++;
    return permissionAfterRequest ?? permission;
  }

  @override
  Stream<PositionFix> positions() => positionController.stream;

  Future<void> close() => positionController.close();
}

void main() {
  PositionFix aFix({double accuracy = 5.0, DateTime? at}) => PositionFix(
        latitude: 23.7461,
        longitude: 90.3742,
        accuracyMeters: accuracy,
        timestamp: at ?? DateTime.now(),
      );

  group('preconditions', () {
    test('services switched off yields ServicesDisabled', () async {
      final source = FakeSource(servicesEnabled: false);
      final service = LocationService(source: source);
      addTearDown(service.dispose);
      addTearDown(source.close);

      await service.start();

      expect(service.state, const ServicesDisabled());
      // Granting permission would not help here, so the app must not ask.
      expect(source.requestCount, 0);
    });

    test('a denied permission is requested once, then reported', () async {
      final source = FakeSource(permission: LocationPermission.denied);
      final service = LocationService(source: source);
      addTearDown(service.dispose);
      addTearDown(source.close);

      await service.start();

      expect(source.requestCount, 1);
      expect(service.state, const PermissionDenied(permanently: false));
    });

    test('a permanently denied permission is not re-requested', () async {
      final source = FakeSource(permission: LocationPermission.deniedForever);
      final service = LocationService(source: source);
      addTearDown(service.dispose);
      addTearDown(source.close);

      await service.start();

      // Prompting again does nothing on either platform; the user has to go to
      // system settings, and the UI has to say so.
      expect(source.requestCount, 0);
      expect(service.state, const PermissionDenied(permanently: true));
    });

    test('granting at the prompt proceeds to searching', () async {
      final source = FakeSource(
        permission: LocationPermission.denied,
        permissionAfterRequest: LocationPermission.whileInUse,
      );
      final service = LocationService(source: source);
      addTearDown(service.dispose);
      addTearDown(source.close);

      await service.start();

      expect(source.requestCount, 1);
      expect(service.state, const Searching());
    });

    test('start can be retried after a denial', () async {
      // A user who grants permission in system settings and comes back should
      // not have to restart the app.
      final source = FakeSource(permission: LocationPermission.deniedForever);
      final service = LocationService(source: source);
      addTearDown(service.dispose);
      addTearDown(source.close);

      await service.start();
      expect(service.state, const PermissionDenied(permanently: true));

      source.permission = LocationPermission.always;
      await service.start();
      expect(service.state, const Searching());
    });
  });

  group('fixes', () {
    test('a reading moves the state to Located', () async {
      final source = FakeSource();
      final service = LocationService(source: source);
      addTearDown(service.dispose);
      addTearDown(source.close);

      await service.start();
      expect(service.state, const Searching());

      final fix = aFix();
      source.positionController.add(fix);
      await pumpEventQueue();

      expect(service.state, Located(fix));
    });

    test('states are broadcast to listeners in order', () async {
      final source = FakeSource();
      final service = LocationService(source: source);
      addTearDown(service.dispose);
      addTearDown(source.close);

      final seen = <LocationState>[];
      service.states.listen(seen.add);

      await service.start();
      final fix = aFix();
      source.positionController.add(fix);
      await pumpEventQueue();

      expect(seen, [const Searching(), Located(fix)]);
    });

    test('a stream error falls back to searching rather than freezing',
        () async {
      final source = FakeSource();
      final service = LocationService(source: source);
      addTearDown(service.dispose);
      addTearDown(source.close);

      await service.start();
      source.positionController.add(aFix());
      await pumpEventQueue();
      expect(service.state, isA<Located>());

      source.positionController.addError(StateError('receiver stopped'));
      await pumpEventQueue();

      // Leaving the last fix on screen indefinitely is what FR-1.2 forbids.
      expect(service.state, const Searching());
    });
  });

  group('the staleness ticker', () {
    test('re-emits the held fix so its age can be re-evaluated', () async {
      // Without this, a fix that stops updating stays on screen looking fresh
      // forever, because nothing prompts the UI to recompute its age.
      final ticker = StreamController<void>.broadcast();
      final source = FakeSource();
      final service = LocationService(source: source, ticker: ticker.stream);
      addTearDown(service.dispose);
      addTearDown(source.close);
      addTearDown(ticker.close);

      await service.start();

      final emissions = <LocationState>[];
      service.states.listen(emissions.add);

      final fix = aFix(at: DateTime.now().subtract(const Duration(minutes: 1)));
      source.positionController.add(fix);
      await pumpEventQueue();
      emissions.clear();

      ticker.add(null);
      ticker.add(null);
      await pumpEventQueue();

      expect(emissions, [Located(fix), Located(fix)]);
      // And the fix it re-emits is one the UI will now render as stale.
      expect(fix.qualityAt(DateTime.now()), FixQuality.stale);
    });

    test('does not tick while there is no fix to age', () async {
      final ticker = StreamController<void>.broadcast();
      final source = FakeSource();
      final service = LocationService(source: source, ticker: ticker.stream);
      addTearDown(service.dispose);
      addTearDown(source.close);
      addTearDown(ticker.close);

      await service.start();

      final emissions = <LocationState>[];
      service.states.listen(emissions.add);

      ticker.add(null);
      ticker.add(null);
      await pumpEventQueue();

      expect(emissions, isEmpty);
    });
  });

  group('disposal', () {
    test('stops emitting and releases its subscriptions', () async {
      final ticker = StreamController<void>.broadcast();
      final source = FakeSource();
      final service = LocationService(source: source, ticker: ticker.stream);
      addTearDown(source.close);
      addTearDown(ticker.close);

      await service.start();
      source.positionController.add(aFix());
      await pumpEventQueue();

      await service.dispose();

      // Emitting after disposal would throw on a closed controller.
      expect(
        () {
          source.positionController.add(aFix());
          ticker.add(null);
        },
        returnsNormally,
      );
      await pumpEventQueue();
    });

    test('disposing without starting is safe', () async {
      final service = LocationService(source: FakeSource());
      await expectLater(service.dispose(), completes);
    });
  });
}
