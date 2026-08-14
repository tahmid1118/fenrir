import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/src/location/position_fix.dart';

void main() {
  final now = DateTime.utc(2026, 8, 14, 12, 0, 0);

  PositionFix fix({
    double accuracy = 5.0,
    Duration age = Duration.zero,
  }) {
    return PositionFix(
      latitude: 23.7461,
      longitude: 90.3742,
      accuracyMeters: accuracy,
      timestamp: now.subtract(age),
    );
  }

  group('FR-1.2 fix quality', () {
    test('fresh and precise is acquired', () {
      expect(fix().qualityAt(now), FixQuality.acquired);
      expect(
        fix(accuracy: 20.0, age: const Duration(seconds: 9))
            .qualityAt(now),
        FixQuality.acquired,
      );
    });

    test('a coarse accuracy radius is degraded however fresh it is', () {
      // A reading that arrived a moment ago with a 200 metre radius is not a
      // confident position, and FR-1.2 forbids presenting it as one.
      expect(fix(accuracy: 20.1).qualityAt(now), FixQuality.degraded);
      expect(fix(accuracy: 200.0).qualityAt(now), FixQuality.degraded);
    });

    test('a precise fix degrades as it ages, then goes stale', () {
      expect(
        fix(age: const Duration(seconds: 9)).qualityAt(now),
        FixQuality.acquired,
      );
      expect(
        fix(age: const Duration(seconds: 10)).qualityAt(now),
        FixQuality.degraded,
      );
      expect(
        fix(age: const Duration(seconds: 29)).qualityAt(now),
        FixQuality.degraded,
      );
      expect(
        fix(age: const Duration(seconds: 30)).qualityAt(now),
        FixQuality.stale,
      );
      expect(
        fix(age: const Duration(minutes: 5)).qualityAt(now),
        FixQuality.stale,
      );
    });

    test('staleness outranks precision', () {
      // The failure FR-1.2 names first: a pin-sharp reading from a minute ago
      // still describes where the user was, not where they are.
      expect(
        fix(accuracy: 1.0, age: const Duration(minutes: 1)).qualityAt(now),
        FixQuality.stale,
      );
    });

    test('quality is evaluated against the clock, not frozen at arrival', () {
      // This is why the service re-emits on a ticker: the same fix has to be
      // able to change quality without any new reading arriving.
      final f = fix();
      expect(f.qualityAt(now), FixQuality.acquired);
      expect(
        f.qualityAt(now.add(const Duration(seconds: 15))),
        FixQuality.degraded,
      );
      expect(
        f.qualityAt(now.add(const Duration(seconds: 45))),
        FixQuality.stale,
      );
    });

    test('a nonsensical accuracy is not treated as precise', () {
      // Some receivers report zero or a negative radius when they have no real
      // estimate. Reading that as "accurate to within zero metres" would be
      // the most confidently wrong answer available.
      expect(fix(accuracy: 0.0).qualityAt(now), FixQuality.degraded);
      expect(fix(accuracy: -1.0).qualityAt(now), FixQuality.degraded);
      expect(fix(accuracy: 0.0).isPrecise, isFalse);
    });

    test('the boundary values are inclusive as documented', () {
      expect(fix(accuracy: 20.0).isPrecise, isTrue);
      expect(fix(accuracy: 20.000001).isPrecise, isFalse);
    });
  });

  group('age', () {
    test('is measured from the reading timestamp', () {
      expect(
        fix(age: const Duration(seconds: 7)).ageAt(now),
        const Duration(seconds: 7),
      );
    });

    test('a clock that has gone backwards yields a negative age, not a crash',
        () {
      // Device clocks are adjusted, and a timestamp from the receiver can end
      // up slightly ahead of local time.
      final future = fix(age: const Duration(seconds: -5));
      expect(future.ageAt(now).isNegative, isTrue);
      expect(future.qualityAt(now), FixQuality.acquired);
    });
  });

  group('value semantics', () {
    test('identical readings compare equal', () {
      expect(fix(), fix());
      expect(fix().hashCode, fix().hashCode);
    });

    test('different readings do not', () {
      expect(fix(accuracy: 5), isNot(fix(accuracy: 6)));
      expect(fix(), isNot(fix(age: const Duration(seconds: 1))));
    });
  });

  group('NFR-6 location states', () {
    test('each state is distinct and compares by value', () {
      expect(const Searching(), const Searching());
      expect(const ServicesDisabled(), const ServicesDisabled());
      expect(
        const PermissionDenied(permanently: false),
        const PermissionDenied(permanently: false),
      );
      expect(
        const PermissionDenied(permanently: false),
        isNot(const PermissionDenied(permanently: true)),
      );
      expect(const Searching(), isNot(const ServicesDisabled()));
      expect(Located(fix()), Located(fix()));
    });

    test('the permanent denial distinction is preserved', () {
      // The two need different instructions: one can be re-prompted, the other
      // has to be changed in system settings.
      const soft = PermissionDenied(permanently: false);
      const hard = PermissionDenied(permanently: true);
      expect(soft.permanently, isFalse);
      expect(hard.permanently, isTrue);
    });

    test('switching over the states is exhaustive without a default', () {
      // If this stops compiling, a state was added and some UI is no longer
      // handling every case -- which is exactly what NFR-6 forbids.
      String describe(LocationState state) => switch (state) {
            PermissionDenied() => 'permission',
            ServicesDisabled() => 'services',
            Searching() => 'searching',
            Located() => 'located',
          };

      expect(describe(const Searching()), 'searching');
      expect(describe(const ServicesDisabled()), 'services');
      expect(describe(const PermissionDenied(permanently: true)), 'permission');
      expect(describe(Located(fix())), 'located');
    });
  });
}
