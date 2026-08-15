import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_compass/flutter_compass.dart';
import 'package:meta/meta.dart';

/// Which north a heading is measured from.
///
/// The distinction is not pedantry. Magnetic north and true north differ by the
/// local magnetic declination, which is under a degree in Dhaka and London but
/// reaches twenty degrees across parts of North America. A map is drawn to true
/// north, so rotating it by a magnetic heading is wrong by exactly that much —
/// and wrong in a way the user cannot see. Saying which one is on screen is the
/// honest minimum until declination is actually corrected for.
enum HeadingReference {
  magnetic,
  trueNorth;

  String get label => this == HeadingReference.trueNorth ? 'TRUE' : 'MAG';
}

/// A compass reading.
@immutable
class Heading {
  const Heading({
    required this.degrees,
    required this.reference,
    this.accuracyDegrees,
  });

  /// Clockwise from [reference], normalised to `[0, 360)`.
  final double degrees;

  final HeadingReference reference;

  /// Reported uncertainty, where the platform gives one.
  final double? accuracyDegrees;

  /// Whether the reading is worth rotating a map by.
  ///
  /// An uncalibrated magnetometer — one that has been near a speaker, a car
  /// dashboard or a magnetic case — can be tens of degrees out while still
  /// producing perfectly steady numbers. Steadiness is not accuracy, so a
  /// reading the platform flags as poor is treated as no reading at all rather
  /// than quietly turning the map to face the wrong way.
  bool get isReliable {
    final accuracy = accuracyDegrees;
    return accuracy == null || (accuracy >= 0 && accuracy <= 30);
  }

  /// The compass point, for a label a person can act on.
  String get compassPoint {
    const points = [
      'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', //
      'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW',
    ];
    return points[(((degrees % 360) / 22.5) + 0.5).floor() % 16];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Heading &&
          degrees == other.degrees &&
          reference == other.reference &&
          accuracyDegrees == other.accuracyDegrees);

  @override
  int get hashCode => Object.hash(degrees, reference, accuracyDegrees);

  @override
  String toString() =>
      'Heading(${degrees.toStringAsFixed(1)}° ${reference.label})';
}

/// Where compass readings come from.
///
/// Behind an interface for the usual reason: a magnetometer cannot be faked in
/// a test, and the smoothing and mode logic are worth testing without one.
abstract class HeadingSource {
  /// Emits null when the device has no usable compass.
  Stream<Heading?> headings();
}

/// The real source, backed by the platform compass.
class CompassHeadingSource implements HeadingSource {
  const CompassHeadingSource();

  @override
  Stream<Heading?> headings() {
    final events = FlutterCompass.events;
    // Some devices genuinely have no magnetometer. A tablet without one should
    // fall back to north-up rather than pretend.
    if (events == null) return Stream<Heading?>.value(null);

    return events.map((event) {
      final degrees = event.heading;
      if (degrees == null) return null;
      return Heading(
        // Android reports magnetic north. iOS can report true north, but
        // flutter_compass does not distinguish, so the conservative label is
        // used and the difference is disclosed rather than assumed away.
        degrees: (degrees % 360 + 360) % 360,
        reference: HeadingReference.magnetic,
        accuracyDegrees: event.accuracy,
      );
    });
  }
}

/// Smooths a heading without the wraparound bug that plagues naive averaging.
///
/// A magnetometer jitters by several degrees, and rotating a map by the raw
/// value is unpleasant to look at. The obvious fix — averaging the angle — is
/// wrong: the mean of 359° and 1° is 180°, so the map spins to face south every
/// time the user points north. Averaging the unit vector instead and taking the
/// angle back out is correct at every angle, including that one.
class HeadingSmoother {
  HeadingSmoother({this.factor = 0.2})
      : assert(factor > 0 && factor <= 1, 'factor must be in (0, 1]');

  /// How much of each new reading is taken. Lower is smoother and laggier.
  final double factor;

  double? _x;
  double? _y;

  /// Feeds in a reading and returns the smoothed heading in `[0, 360)`.
  double add(double degrees) {
    final radians = degrees * math.pi / 180.0;
    final x = math.cos(radians);
    final y = math.sin(radians);

    final previousX = _x;
    final previousY = _y;
    if (previousX == null || previousY == null) {
      _x = x;
      _y = y;
    } else {
      _x = previousX + (x - previousX) * factor;
      _y = previousY + (y - previousY) * factor;
    }

    final smoothed = math.atan2(_y!, _x!) * 180.0 / math.pi;
    return (smoothed % 360 + 360) % 360;
  }

  /// Forgets history, so the next reading is taken whole.
  void reset() {
    _x = null;
    _y = null;
  }
}

/// How the map is oriented (FR-4.3).
enum MapOrientation {
  /// North stays at the top. Predictable, and the default.
  northUp,

  /// The map turns so that the direction the device faces is at the top.
  headingUp;

  MapOrientation get toggled =>
      this == MapOrientation.northUp
          ? MapOrientation.headingUp
          : MapOrientation.northUp;
}

/// Streams smoothed headings, and nothing at all when there is no usable
/// compass.
class HeadingService {
  HeadingService({HeadingSource? source, HeadingSmoother? smoother})
      : _source = source ?? const CompassHeadingSource(),
        _smoother = smoother ?? HeadingSmoother();

  final HeadingSource _source;
  final HeadingSmoother _smoother;

  /// Readings, smoothed, with unreliable ones dropped.
  Stream<Heading?> headings() {
    return _source.headings().map((raw) {
      if (raw == null || !raw.isReliable) {
        _smoother.reset();
        return null;
      }
      return Heading(
        degrees: _smoother.add(raw.degrees),
        reference: raw.reference,
        accuracyDegrees: raw.accuracyDegrees,
      );
    });
  }
}
