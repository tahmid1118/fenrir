import 'package:flutter/material.dart';

/// Fenrir's visual theme.
///
/// The app is dark-only by design. It is built for field and night use, where
/// a bright screen destroys night vision and costs battery on OLED panels
/// (NFR-5). A system-following light theme would also mean tuning two palettes
/// for the 4.5:1 contrast floor NFR-7 requires, for a mode this product is not
/// used in.
///
/// Brand colour is deliberately cold and desaturated so it never competes with
/// the fix-status colours below. Those carry meaning — a user glancing at the
/// screen in poor conditions must be able to read position confidence from
/// colour alone, so nothing else in the UI is allowed to use them.
const _seed = Color(0xFF3DD6C0);

/// Background of the app behind the map. Near-black, but blue-shifted rather
/// than pure #000 so that elevation overlays remain visible.
const _surface = Color(0xFF0D1316);

ThemeData buildFenrirTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.dark,
    surface: _surface,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    extensions: const [FixStatusColors.standard],
    // Tabular figures matter here: coordinates update several times a second,
    // and proportional digits make the whole readout jitter as values change.
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
    ),
  );
}

/// Semantic colours for GPS fix quality (FR-1.2).
///
/// These are the only place in the app allowed to use green/amber/red. Keeping
/// them in a [ThemeExtension] rather than as loose constants means a widget
/// cannot accidentally reach for "some green" that happens to look similar but
/// carries no meaning.
///
/// Two properties are enforced by `test/ui/theme_test.dart`:
///
/// 1. Each colour clears 4.5:1 against [_surface], per NFR-7.
/// 2. The four are ordered by *luminance*, not just hue — dimmest for absent
///    through brightest for acquired. An earlier palette used a conventional
///    green/amber pair that measured 1.04:1 against each other: the same
///    brightness, differing only in hue, which is precisely the pair red-green
///    colour blindness collapses. Roughly 8% of men would have been unable to
///    tell a degraded fix from a good one.
///
/// Four colours cannot spread far in luminance while all staying above the
/// 4.5:1 floor — the ceiling is about 1.5x per adjacent step — so this palette
/// buys margin, not certainty. **Colour must never be the only channel.** Every
/// widget rendering fix state pairs it with an icon and a text label, per WCAG
/// 1.4.1; see `fix_indicator.dart`.
@immutable
class FixStatusColors extends ThemeExtension<FixStatusColors> {
  const FixStatusColors({
    required this.acquired,
    required this.degraded,
    required this.stale,
    required this.absent,
  });

  /// Fix is fresh and precise enough to trust.
  final Color acquired;

  /// Fix is real but coarse — shown, but visibly qualified.
  final Color degraded;

  /// Fix has aged out. The position on screen may no longer be where the user
  /// is, which is the failure FR-1.2 exists to prevent.
  final Color stale;

  /// No fix at all: permission denied, services off, or still searching.
  final Color absent;

  // Luminance rises with confidence: 0.227 -> 0.340 -> 0.595 -> 0.876.
  // Contrast against the surface: 4.94, 6.96, 11.49, 16.51.
  static const standard = FixStatusColors(
    acquired: Color(0xFFD1FAE5),
    degraded: Color(0xFFFCC22B),
    stale: Color(0xFFFB7185),
    absent: Color(0xFF76849A),
  );

  @override
  FixStatusColors copyWith({
    Color? acquired,
    Color? degraded,
    Color? stale,
    Color? absent,
  }) {
    return FixStatusColors(
      acquired: acquired ?? this.acquired,
      degraded: degraded ?? this.degraded,
      stale: stale ?? this.stale,
      absent: absent ?? this.absent,
    );
  }

  @override
  FixStatusColors lerp(ThemeExtension<FixStatusColors>? other, double t) {
    if (other is! FixStatusColors) return this;
    return FixStatusColors(
      acquired: Color.lerp(acquired, other.acquired, t)!,
      degraded: Color.lerp(degraded, other.degraded, t)!,
      stale: Color.lerp(stale, other.stale, t)!,
      absent: Color.lerp(absent, other.absent, t)!,
    );
  }
}
