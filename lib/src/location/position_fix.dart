import 'package:meta/meta.dart';

/// How much a fix can be trusted right now (FR-1.2).
///
/// The requirement is blunt about the failure it exists to prevent: "The user
/// must never be shown a confident position that is actually a stale or coarse
/// estimate." Quality is therefore a function of the current time, not a
/// property fixed when the reading arrived — a fix that was excellent thirty
/// seconds ago is not excellent now.
enum FixQuality {
  /// Fresh and precise enough to act on.
  acquired,

  /// Real, but either coarse or beginning to age. Shown, visibly qualified.
  degraded,

  /// Old enough that the user may have moved away from it.
  stale,
}

/// A single reading from the GNSS receiver.
@immutable
class PositionFix {
  const PositionFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.timestamp,
    this.altitudeMeters,
    this.altitudeAccuracyMeters,
    this.isMocked = false,
  });

  final double latitude;
  final double longitude;

  /// Horizontal accuracy radius in metres — the number FR-1.2 requires be
  /// shown at all times, not only when it is flattering.
  final double accuracyMeters;

  /// When the receiver produced this reading.
  final DateTime timestamp;

  /// Altitude above the WGS84 ellipsoid, where the receiver reports one
  /// (FR-2.4).
  final double? altitudeMeters;

  /// Vertical accuracy. GNSS altitude is markedly noisier than the horizontal
  /// fix, which is why FR-2.4 asks for it to be labelled with its accuracy
  /// rather than presented as bare truth.
  final double? altitudeAccuracyMeters;

  /// Whether the platform flagged this as a simulated position.
  final bool isMocked;

  /// A fix newer than this is considered fresh.
  static const Duration freshFor = Duration(seconds: 10);

  /// A fix older than this can no longer be trusted to describe where the user
  /// is.
  static const Duration staleAfter = Duration(seconds: 30);

  /// An accuracy radius at or below this counts as precise.
  static const double preciseWithinMeters = 20.0;

  Duration ageAt(DateTime now) => now.difference(timestamp);

  /// Whether the accuracy radius is tight enough to call the fix precise.
  bool get isPrecise =>
      accuracyMeters > 0 && accuracyMeters <= preciseWithinMeters;

  /// Trustworthiness of this fix as of [now].
  ///
  /// Being called `acquired` requires being both fresh *and* precise. A
  /// pin-sharp reading from a minute ago and a fresh reading with a 200 metre
  /// radius are different problems, but they share a remedy: do not present
  /// either as certainty.
  FixQuality qualityAt(DateTime now) {
    final age = ageAt(now);
    if (age >= staleAfter) return FixQuality.stale;
    if (!isPrecise) return FixQuality.degraded;
    if (age >= freshFor) return FixQuality.degraded;
    return FixQuality.acquired;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PositionFix &&
          latitude == other.latitude &&
          longitude == other.longitude &&
          accuracyMeters == other.accuracyMeters &&
          timestamp == other.timestamp &&
          altitudeMeters == other.altitudeMeters &&
          altitudeAccuracyMeters == other.altitudeAccuracyMeters &&
          isMocked == other.isMocked);

  @override
  int get hashCode => Object.hash(
        latitude,
        longitude,
        accuracyMeters,
        timestamp,
        altitudeMeters,
        altitudeAccuracyMeters,
        isMocked,
      );

  @override
  String toString() => 'PositionFix($latitude, $longitude, '
      '+/-${accuracyMeters.toStringAsFixed(0)} m, $timestamp)';
}

/// Everything the position display can be showing (NFR-6).
///
/// Sealed so that adding a state is a compile error at every place that
/// renders one. NFR-6 requires each condition to have a defined, informative
/// UI state and forbids unexplained blanks; letting the compiler enforce the
/// exhaustiveness is cheaper than remembering to.
sealed class LocationState {
  const LocationState();
}

/// Location permission has not been granted.
class PermissionDenied extends LocationState {
  const PermissionDenied({required this.permanently});

  /// When true the system will no longer prompt, and the user has to change
  /// this in system settings. The distinction matters because the two states
  /// need different instructions.
  final bool permanently;

  @override
  bool operator ==(Object other) =>
      other is PermissionDenied && permanently == other.permanently;

  @override
  int get hashCode => permanently.hashCode;
}

/// Location services are switched off for the whole device.
///
/// Distinct from [PermissionDenied] because granting this app permission would
/// not help; the user has to turn the receiver on.
class ServicesDisabled extends LocationState {
  const ServicesDisabled();

  @override
  bool operator ==(Object other) => other is ServicesDisabled;

  @override
  int get hashCode => 0;
}

/// Permitted and listening, but no reading has arrived yet.
///
/// Expected to last longer here than in most apps: FR-1.1 forbids falling back
/// to network positioning, so there is nothing to show until the satellites
/// are actually acquired.
class Searching extends LocationState {
  const Searching();

  @override
  bool operator ==(Object other) => other is Searching;

  @override
  int get hashCode => 1;
}

/// A reading is available. How much it can be trusted is
/// [PositionFix.qualityAt].
class Located extends LocationState {
  const Located(this.fix);

  final PositionFix fix;

  @override
  bool operator ==(Object other) => other is Located && fix == other.fix;

  @override
  int get hashCode => fix.hashCode;
}
