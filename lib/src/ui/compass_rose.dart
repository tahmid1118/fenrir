import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../location/heading_service.dart';

/// The compass rose (FR-4.3).
///
/// Points to north wherever north currently is on screen, and doubles as the
/// control for switching between north-up and heading-up. Tapping a compass to
/// reset the map is the convention every map application shares, so it is worth
/// following rather than inventing.
///
/// It states which north it means. Magnetic and true north differ by the local
/// declination — under a degree in some places, twenty in others — and a rose
/// that does not say which one it is showing is asking to be trusted further
/// than it has earned.
class CompassRose extends StatelessWidget {
  const CompassRose({
    super.key,
    required this.orientation,
    required this.heading,
    required this.mapRotationDegrees,
    required this.onTap,
    this.size = 44,
  });

  final MapOrientation orientation;

  /// The current reading, or null when there is no usable compass.
  final Heading? heading;

  /// The map's own rotation, so the needle can point at true screen north.
  final double mapRotationDegrees;

  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = orientation == MapOrientation.headingUp;
    final available = heading != null;

    return Semantics(
      button: true,
      label: available
          ? 'Compass, ${heading!.compassPoint}, '
              '${orientation == MapOrientation.headingUp ? 'heading up' : 'north up'}. '
              'Tap to switch.'
          : 'Compass unavailable on this device',
      excludeSemantics: true,
      child: Tooltip(
        message: available
            ? (active ? 'Heading up — tap for north up' : 'Tap for heading up')
            : 'No compass on this device',
        child: InkWell(
          onTap: available ? onTap : null,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _RosePainter(
                // The needle points at north on screen. In north-up that is
                // straight up; in heading-up the whole map has turned, so the
                // needle turns with it by the same amount.
                northOnScreenDegrees: mapRotationDegrees,
                colour: available
                    ? (active
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant)
                    : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                background: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.85),
                border: theme.dividerColor,
                reference: heading?.reference,
                labelStyle: theme.textTheme.labelSmall,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RosePainter extends CustomPainter {
  _RosePainter({
    required this.northOnScreenDegrees,
    required this.colour,
    required this.background,
    required this.border,
    required this.reference,
    required this.labelStyle,
  });

  final double northOnScreenDegrees;
  final Color colour;
  final Color background;
  final Color border;
  final HeadingReference? reference;
  final TextStyle? labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    canvas
      ..drawCircle(centre, radius, Paint()..color = background)
      ..drawCircle(
        centre,
        radius - 0.5,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );

    final radians = northOnScreenDegrees * math.pi / 180.0;
    canvas
      ..save()
      ..translate(centre.dx, centre.dy)
      ..rotate(radians);

    // A single tapered needle: the filled half points north, the outline half
    // south. Two halves make the direction unambiguous at a glance, which a
    // bare arrow does not.
    final needle = radius * 0.62;
    final width = radius * 0.26;

    canvas
      ..drawPath(
        Path()
          ..moveTo(0, -needle)
          ..lineTo(-width, 0)
          ..lineTo(width, 0)
          ..close(),
        Paint()..color = colour,
      )
      ..drawPath(
        Path()
          ..moveTo(0, needle)
          ..lineTo(-width, 0)
          ..lineTo(width, 0)
          ..close(),
        Paint()
          ..color = colour.withValues(alpha: 0.35)
          ..style = PaintingStyle.fill,
      )
      ..restore();

    // "N" sits outside the rotation so it stays upright and readable however
    // the map is turned; the needle alone carries the direction.
    final label = TextPainter(
      text: TextSpan(
        text: 'N',
        style: (labelStyle ?? const TextStyle()).copyWith(
          color: colour,
          fontWeight: FontWeight.w700,
          fontSize: radius * 0.42,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(
      canvas,
      Offset(centre.dx - label.width / 2, size.height - label.height - 1),
    );

    // Which north this is. Small, but the difference reaches twenty degrees.
    final marker = reference;
    if (marker != null) {
      final tag = TextPainter(
        text: TextSpan(
          text: marker.label,
          style: (labelStyle ?? const TextStyle()).copyWith(
            color: colour.withValues(alpha: 0.75),
            fontSize: radius * 0.28,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tag.paint(canvas, Offset(centre.dx - tag.width / 2, 2));
    }
  }

  @override
  bool shouldRepaint(_RosePainter old) =>
      old.northOnScreenDegrees != northOnScreenDegrees ||
      old.colour != colour ||
      old.reference != reference;
}
