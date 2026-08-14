import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../geo/coordinate_formats.dart';
import '../share/position_message.dart';
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
    this.onSave,
  });

  final PositionFix fix;
  final CoordinateFormat format;
  final PlaceMatch? match;
  final ValueChanged<CoordinateFormat> onFormatChanged;

  /// Saves this position (FR-6.1). Null hides the action.
  final VoidCallback? onSave;

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
            TextButton.icon(
              onPressed: () => _sendSms(context),
              icon: const Icon(Icons.sms_outlined, size: 18),
              label: const Text('SMS'),
            ),
            if (onSave != null)
              TextButton.icon(
                onPressed: onSave,
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: const Text('Save'),
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

  /// The message a recipient with no special app can act on (FR-2.3, FR-7.1).
  ///
  /// The same body goes to the share sheet and to SMS. There is no reason for
  /// the two to differ, and one composer means the wording can be reasoned
  /// about — and length-checked against the SMS segment limit — in one place.
  String shareText() =>
      composePositionMessage(fix: fix, match: match).body;

  /// Opens the platform SMS composer, prefilled (FR-7.1).
  ///
  /// The message is composed here and handed over; it is never sent
  /// automatically. FR-9.2 requires that position data leave the device only
  /// through an action the user explicitly initiates, and the send button in
  /// the messaging app is that action.
  Future<void> _sendSms(BuildContext context) async {
    final message = composePositionMessage(fix: fix, match: match);
    final uri = smsUri(body: message.body);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final opened = await launchUrl(uri);
      if (!opened && context.mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('No messaging app is available on this device'),
          ),
        );
      }
    } on Object {
      // A device with no SMS capability at all -- a tablet, say -- throws
      // rather than returning false. Either way the user needs telling, not a
      // silent no-op.
      if (!context.mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No messaging app is available on this device'),
        ),
      );
    }
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
