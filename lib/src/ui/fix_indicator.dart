import 'package:flutter/material.dart';

import '../location/position_fix.dart';
import 'theme.dart';

/// Shows whether the position on screen can be trusted (FR-1.2).
///
/// The requirement is specific about the failure it prevents: the user must
/// never be shown a confident position that is actually a stale or coarse
/// estimate. So the accuracy radius is always visible — not only when it is
/// flattering — and the state is carried by an icon and a word as well as a
/// colour.
///
/// Colour alone would fail WCAG 1.4.1 and, more concretely, would fail the
/// roughly 8% of men with red-green colour blindness. The palette is ordered by
/// luminance for the same reason, but the label is what makes it unambiguous.
class FixIndicator extends StatelessWidget {
  const FixIndicator({super.key, required this.state, required this.now});

  final LocationState state;

  /// Passed in rather than read from the clock so the widget stays pure and
  /// its states are testable without waiting.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colours = theme.extension<FixStatusColors>()!;

    // The detail line stays short and does not repeat the explanation shown in
    // the sheet below. Saying the same sentence twice on one screen makes both
    // copies easier to skip.
    final (colour, icon, label, detail) = switch (state) {
      ServicesDisabled() => (
          colours.absent,
          Icons.location_disabled,
          'Location off',
          'Receiver disabled',
        ),
      PermissionDenied() => (
          colours.absent,
          Icons.lock_outline,
          'No permission',
          'Not granted',
        ),
      Searching() => (
          colours.absent,
          Icons.satellite_alt,
          'Searching',
          'No fix yet',
        ),
      Located(fix: final fix) => _describe(colours, fix, now),
    };

    return Semantics(
      liveRegion: true,
      label: '$label. $detail',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.85,
          ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colour.withValues(alpha: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: colour),
              const SizedBox(width: 7),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colour,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static (Color, IconData, String, String) _describe(
    FixStatusColors colours,
    PositionFix fix,
    DateTime now,
  ) {
    final radius = _metres(fix.accuracyMeters);
    switch (fix.qualityAt(now)) {
      case FixQuality.acquired:
        return (colours.acquired, Icons.gps_fixed, 'GPS fix', radius);
      case FixQuality.degraded:
        // Naming which of the two problems it is matters: waiting helps a
        // coarse fix, and only moving to open sky helps a fading one.
        final age = fix.ageAt(now);
        final reason = fix.isPrecise
            ? '$radius, ${_age(age)} old'
            : '$radius, low precision';
        return (colours.degraded, Icons.gps_not_fixed, 'Approximate', reason);
      case FixQuality.stale:
        return (
          colours.stale,
          Icons.gps_off,
          'Stale fix',
          'Last seen ${_age(fix.ageAt(now))} ago',
        );
    }
  }

  static String _metres(double accuracy) {
    if (accuracy <= 0) return 'Accuracy unknown';
    if (accuracy < 10) return '±${accuracy.toStringAsFixed(1)} m';
    return '±${accuracy.round()} m';
  }

  static String _age(Duration age) {
    if (age.inSeconds < 60) return '${age.inSeconds}s';
    if (age.inMinutes < 60) return '${age.inMinutes}m';
    return '${age.inHours}h';
  }
}
