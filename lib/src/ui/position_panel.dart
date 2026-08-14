import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../data/models.dart';
import '../geo/coordinate_formats.dart';
import '../geo/plus_code.dart';
import '../location/position_fix.dart';

/// Shows the current position in one notation at a time, and lets the user
/// copy or share it (FR-2.1, FR-2.3).
class PositionPanel extends StatelessWidget {
  const PositionPanel({
    super.key,
    required this.fix,
    required this.format,
    required this.match,
    required this.onFormatChanged,
  });

  final PositionFix fix;
  final CoordinateFormat format;
  final PlaceMatch? match;
  final ValueChanged<CoordinateFormat> onFormatChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = formatCoordinate(fix.latitude, fix.longitude, format);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final option in CoordinateFormat.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(option.shortLabel),
                          selected: option == format,
                          onSelected: (_) => onFormatChanged(option),
                          visualDensity: VisualDensity.compact,
                          tooltip: option.label,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Semantics(
          label: '${format.label}: ${value.display}',
          excludeSemantics: true,
          child: SelectableText(
            value.display,
            style: theme.textTheme.titleMedium?.copyWith(
              fontFamily: 'monospace',
              color: value.isAvailable
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
              fontStyle: value.isAvailable ? null : FontStyle.italic,
            ),
          ),
        ),
        if (fix.altitudeMeters != null) ...[
          const SizedBox(height: 4),
          // FR-2.4 asks for altitude to be labelled with its accuracy. GNSS
          // altitude is markedly noisier than the horizontal fix, and showing
          // it bare would imply a confidence it does not have.
          Text(
            _altitude(fix),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        // Wrap rather than Row: at the text scales NFR-7 requires, two labelled
        // buttons no longer fit side by side and a Row clips the second one.
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton.icon(
              onPressed: value.isAvailable
                  ? () => _copy(context, value.text!)
                  : null,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('Copy'),
            ),
            TextButton.icon(
              onPressed: () => _share(context),
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('Share'),
            ),
          ],
        ),
      ],
    );
  }

  static String _altitude(PositionFix fix) {
    final metres = fix.altitudeMeters!.round();
    final accuracy = fix.altitudeAccuracyMeters;
    if (accuracy == null || accuracy <= 0) {
      return 'Altitude $metres m (accuracy unknown)';
    }
    return 'Altitude $metres m ±${accuracy.round()} m';
  }

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $text'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Builds a message a recipient with no special app can act on (FR-2.3).
  ///
  /// Plain decimal degrees leads the list because every mapping application and
  /// search engine accepts it. The Plus Code follows because it survives being
  /// read aloud over a voice call, which matters when there is no data
  /// connection — the situation this whole product is built for.
  String shareText() {
    final lines = <String>[];

    final place = match;
    if (place != null) {
      lines.add(place.proximity == Proximity.inside
          ? place.place.displayName
          : 'Near ${place.place.displayName}');
    }

    lines
      ..add(formatDecimalDegreesPlain(fix.latitude, fix.longitude))
      ..add('Plus Code: ${encodePlusCode(fix.latitude, fix.longitude)}');

    if (fix.accuracyMeters > 0) {
      lines.add('Accurate to about ${fix.accuracyMeters.round()} m');
    }
    return lines.join('\n');
  }

  Future<void> _share(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: shareText(),
        subject: 'My position',
        // Anchors the popover on iPad; without it the sheet has nowhere to
        // point and the presentation degrades.
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }
}
