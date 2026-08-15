import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/src/location/heading_service.dart';

class FakeHeadingSource implements HeadingSource {
  FakeHeadingSource([this.controller]);

  final StreamController<Heading?>? controller;

  @override
  Stream<Heading?> headings() =>
      controller?.stream ?? const Stream<Heading?>.empty();
}

void main() {
  Heading heading(double degrees, {double? accuracy}) => Heading(
        degrees: degrees,
        reference: HeadingReference.magnetic,
        accuracyDegrees: accuracy,
      );

  group('circular smoothing', () {
    test('the first reading is taken whole', () {
      final smoother = HeadingSmoother(factor: 0.2);
      expect(smoother.add(90), closeTo(90, 1e-9));
    });

    test('crossing north does not swing the map to face south', () {
      // The bug this exists to prevent: the arithmetic mean of 359 and 1 is
      // 180. Averaging the unit vector instead is correct at every angle.
      final smoother = HeadingSmoother(factor: 0.5);
      smoother.add(359);
      final result = smoother.add(1);

      // The true midpoint is 0, not 180.
      final distanceFromNorth = math.min(result, 360 - result);
      expect(distanceFromNorth, lessThan(1.0),
          reason: 'smoothed to $result, expected near 0');
    });

    test('converges toward a steady reading', () {
      final smoother = HeadingSmoother(factor: 0.3);
      smoother.add(0);
      double last = 0;
      for (var i = 0; i < 40; i++) {
        last = smoother.add(90);
      }
      expect(last, closeTo(90, 0.5));
    });

    test('lags a sudden change, which is the point', () {
      final smoother = HeadingSmoother(factor: 0.2);
      smoother.add(0);
      final afterOne = smoother.add(90);
      // A single reading must not snap the map round.
      expect(afterOne, greaterThan(0));
      expect(afterOne, lessThan(45));
    });

    test('always returns a value in [0, 360)', () {
      final smoother = HeadingSmoother(factor: 0.4);
      for (final input in [0.0, 45.0, 180.0, 270.0, 359.9, 360.0, 720.0]) {
        final result = smoother.add(input);
        expect(result, greaterThanOrEqualTo(0));
        expect(result, lessThan(360));
      }
    });

    test('reset forgets history', () {
      final smoother = HeadingSmoother(factor: 0.1);
      smoother.add(0);
      smoother.reset();
      // Taken whole again rather than dragged from the old value.
      expect(smoother.add(270), closeTo(270, 1e-9));
    });

    test('rejects a factor outside (0, 1]', () {
      expect(() => HeadingSmoother(factor: 0), throwsA(isA<AssertionError>()));
      expect(() => HeadingSmoother(factor: 1.5), throwsA(isA<AssertionError>()));
      expect(() => HeadingSmoother(factor: 1), returnsNormally);
    });
  });

  group('reliability', () {
    test('an unknown accuracy is trusted', () {
      // Most Android devices report nothing; refusing to work without a figure
      // would disable the compass on the majority of phones.
      expect(heading(90).isReliable, isTrue);
    });

    test('a poor accuracy is not trusted', () {
      // An uncalibrated magnetometer produces perfectly steady numbers that
      // are tens of degrees wrong. Steadiness is not accuracy.
      expect(heading(90, accuracy: 5).isReliable, isTrue);
      expect(heading(90, accuracy: 30).isReliable, isTrue);
      expect(heading(90, accuracy: 45).isReliable, isFalse);
      expect(heading(90, accuracy: 180).isReliable, isFalse);
    });

    test('a negative accuracy, which Android uses for unknown, is not trusted',
        () {
      expect(heading(90, accuracy: -1).isReliable, isFalse);
    });
  });

  group('compass points', () {
    test('name the direction a person can act on', () {
      expect(heading(0).compassPoint, 'N');
      expect(heading(90).compassPoint, 'E');
      expect(heading(180).compassPoint, 'S');
      expect(heading(270).compassPoint, 'W');
      expect(heading(45).compassPoint, 'NE');
      expect(heading(22.5).compassPoint, 'NNE');
    });

    test('wrap around north correctly', () {
      expect(heading(359).compassPoint, 'N');
      expect(heading(337.5).compassPoint, 'NNW');
      // 348.75 is exactly the NNW/N boundary and belongs to N.
      expect(heading(348.75).compassPoint, 'N');
      expect(heading(348.7).compassPoint, 'NNW');
    });
  });

  group('the reference is stated, not assumed', () {
    test('magnetic and true are labelled differently', () {
      // A map is drawn to true north. Rotating it by a magnetic heading is
      // wrong by the local declination, which reaches twenty degrees in parts
      // of North America, so which one is on screen has to be visible.
      expect(HeadingReference.magnetic.label, 'MAG');
      expect(HeadingReference.trueNorth.label, 'TRUE');
    });
  });

  group('HeadingService', () {
    test('smooths readings as they arrive', () async {
      final controller = StreamController<Heading?>();
      final service = HeadingService(
        source: FakeHeadingSource(controller),
        smoother: HeadingSmoother(factor: 0.5),
      );

      final results = <Heading?>[];
      final subscription = service.headings().listen(results.add);
      addTearDown(subscription.cancel);

      controller.add(heading(0));
      controller.add(heading(90));
      await pumpEventQueue();

      expect(results, hasLength(2));
      expect(results.first!.degrees, closeTo(0, 1e-9));
      // Smoothed, so partway rather than snapped.
      expect(results.last!.degrees, greaterThan(0));
      expect(results.last!.degrees, lessThan(90));

      await controller.close();
    });

    test('drops unreliable readings rather than turning the map wrongly',
        () async {
      final controller = StreamController<Heading?>();
      final service = HeadingService(source: FakeHeadingSource(controller));

      final results = <Heading?>[];
      final subscription = service.headings().listen(results.add);
      addTearDown(subscription.cancel);

      controller.add(heading(90, accuracy: 120));
      controller.add(null);
      await pumpEventQueue();

      expect(results, [null, null]);
      await controller.close();
    });

    test('an unreliable reading resets the smoother', () async {
      // Otherwise the first good reading after a bad patch is dragged toward a
      // value the app has already decided not to trust.
      final controller = StreamController<Heading?>();
      final service = HeadingService(
        source: FakeHeadingSource(controller),
        smoother: HeadingSmoother(factor: 0.1),
      );

      final results = <Heading?>[];
      final subscription = service.headings().listen(results.add);
      addTearDown(subscription.cancel);

      controller.add(heading(0));
      controller.add(heading(0, accuracy: 90));
      controller.add(heading(270));
      await pumpEventQueue();

      expect(results.last!.degrees, closeTo(270, 1e-9));
      await controller.close();
    });

    test('a device with no compass emits nothing rather than failing',
        () async {
      final service = HeadingService(source: FakeHeadingSource());
      expect(await service.headings().toList(), isEmpty);
    });
  });

  group('declination correction', () {
    test('reports magnetic until a position is known', () async {
      // There is nowhere to evaluate the model at before the first fix, and a
      // guessed correction presented as true north is worse than an honest
      // magnetic heading.
      final controller = StreamController<Heading?>();
      final service = HeadingService(
        source: FakeHeadingSource(controller),
        smoother: HeadingSmoother(factor: 1),
      );

      final results = <Heading?>[];
      final subscription = service.headings().listen(results.add);
      addTearDown(subscription.cancel);

      controller.add(heading(90));
      await pumpEventQueue();

      expect(results.single!.reference, HeadingReference.magnetic);
      expect(results.single!.degrees, closeTo(90, 1e-6));
      expect(service.declinationDegrees, isNull);
      await controller.close();
    });

    test('corrects to true north once a position is known', () async {
      final controller = StreamController<Heading?>();
      final service = HeadingService(
        source: FakeHeadingSource(controller),
        smoother: HeadingSmoother(factor: 1),
      );

      // Seattle, where declination is large enough to matter: about +15 east.
      service.setPosition(latitude: 47.6062, longitude: -122.3321);

      final results = <Heading?>[];
      final subscription = service.headings().listen(results.add);
      addTearDown(subscription.cancel);

      controller.add(heading(0));
      await pumpEventQueue();

      final result = results.single!;
      expect(result.reference, HeadingReference.trueNorth);
      // Pointing at magnetic north there means facing appreciably east of
      // true north, which is exactly the error this corrects.
      expect(result.degrees, greaterThan(10));
      expect(result.degrees, lessThan(20));
      expect(service.declinationDegrees, isNotNull);
      await controller.close();
    });

    test('barely changes the heading where declination is small', () async {
      final controller = StreamController<Heading?>();
      final service = HeadingService(
        source: FakeHeadingSource(controller),
        smoother: HeadingSmoother(factor: 1),
      );
      service.setPosition(latitude: 23.7461, longitude: 90.3742);

      final results = <Heading?>[];
      final subscription = service.headings().listen(results.add);
      addTearDown(subscription.cancel);

      controller.add(heading(90));
      await pumpEventQueue();

      expect(results.single!.degrees, closeTo(90, 2.0));
      await controller.close();
    });

    test('wraps rather than exceeding 360', () async {
      final controller = StreamController<Heading?>();
      final service = HeadingService(
        source: FakeHeadingSource(controller),
        smoother: HeadingSmoother(factor: 1),
      );
      service.setPosition(latitude: 47.6062, longitude: -122.3321);

      final results = <Heading?>[];
      final subscription = service.headings().listen(results.add);
      addTearDown(subscription.cancel);

      // 355 plus a positive declination crosses north.
      controller.add(heading(355));
      await pumpEventQueue();

      expect(results.single!.degrees, greaterThanOrEqualTo(0));
      expect(results.single!.degrees, lessThan(360));
      await controller.close();
    });
  });

  group('MapOrientation', () {
    test('toggles between the two modes', () {
      expect(MapOrientation.northUp.toggled, MapOrientation.headingUp);
      expect(MapOrientation.headingUp.toggled, MapOrientation.northUp);
    });
  });
}

