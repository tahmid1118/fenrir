import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/src/ui/theme.dart';

/// WCAG 2.1 relative luminance.
/// https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
double _relativeLuminance(Color c) {
  double channel(double v) {
    final s = v / 255.0;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * channel((c.r * 255).roundToDouble()) +
      0.7152 * channel((c.g * 255).roundToDouble()) +
      0.0722 * channel((c.b * 255).roundToDouble());
}

/// WCAG 2.1 contrast ratio between two opaque colours, from 1.0 to 21.0.
double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  // NFR-7 requires a minimum 4.5:1 contrast ratio. The fix-status colours carry
  // meaning on their own — a user must be able to read position confidence from
  // colour at a glance in poor conditions — so they are the colours that matter
  // most here, and the ones most easily broken by a casual palette tweak.
  const minimumRatio = 4.5;

  group('NFR-7 contrast', () {
    final theme = buildFenrirTheme();
    final surface = theme.colorScheme.surface;
    final fix = theme.extension<FixStatusColors>()!;

    test('fix status colours meet 4.5:1 against the surface', () {
      final cases = <String, Color>{
        'acquired': fix.acquired,
        'degraded': fix.degraded,
        'stale': fix.stale,
        'absent': fix.absent,
      };

      for (final entry in cases.entries) {
        final ratio = _contrastRatio(entry.value, surface);
        expect(
          ratio,
          greaterThanOrEqualTo(minimumRatio),
          reason: '${entry.key} contrast is ${ratio.toStringAsFixed(2)}:1 '
              'against the surface, below the $minimumRatio:1 floor',
        );
      }
    });

    test('body and primary text meet 4.5:1 against the surface', () {
      expect(
        _contrastRatio(theme.colorScheme.onSurface, surface),
        greaterThanOrEqualTo(minimumRatio),
      );
      expect(
        _contrastRatio(theme.colorScheme.onSurfaceVariant, surface),
        greaterThanOrEqualTo(minimumRatio),
      );
      expect(
        _contrastRatio(theme.colorScheme.primary, surface),
        greaterThanOrEqualTo(minimumRatio),
      );
    });

    test('fix states differ in luminance, not only in hue', () {
      // A conventional green/amber pair measures about 1.04:1 against each
      // other — identical brightness, differing only in hue, which is exactly
      // what red-green colour blindness collapses. Requiring separation in
      // luminance means the states stay readable without colour discrimination.
      //
      // 1.4 is near the practical ceiling: four colours all held above the
      // 4.5:1 surface floor cannot spread much further apart than this.
      const minimumSeparation = 1.4;

      final byName = <String, Color>{
        'absent': fix.absent,
        'stale': fix.stale,
        'degraded': fix.degraded,
        'acquired': fix.acquired,
      };
      final names = byName.keys.toList();

      for (var i = 0; i < names.length; i++) {
        for (var j = i + 1; j < names.length; j++) {
          final ratio = _contrastRatio(byName[names[i]]!, byName[names[j]]!);
          expect(
            ratio,
            greaterThanOrEqualTo(minimumSeparation),
            reason: '${names[i]} and ${names[j]} differ by only '
                '${ratio.toStringAsFixed(2)}:1 in luminance — too close to '
                'tell apart without colour vision',
          );
        }
      }
    });

    test('confidence reads as brightness: absent dimmest, acquired brightest',
        () {
      final ordered = [fix.absent, fix.stale, fix.degraded, fix.acquired]
          .map(_relativeLuminance)
          .toList();
      for (var i = 1; i < ordered.length; i++) {
        expect(
          ordered[i],
          greaterThan(ordered[i - 1]),
          reason: 'fix status luminance must increase with confidence',
        );
      }
    });
  });

  test('the theme is dark, and its surface is the scaffold background', () {
    final theme = buildFenrirTheme();
    expect(theme.colorScheme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
  });
}
