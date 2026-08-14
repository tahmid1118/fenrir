import 'package:meta/meta.dart';

import '../data/models.dart';
import '../geo/coordinate_formats.dart';
import '../geo/plus_code.dart';
import '../location/position_fix.dart';

/// Builds the messages the app sends about a position (FR-2.3, FR-7.1).
///
/// SMS is a first-class channel here rather than a fallback. FR-7.1 makes the
/// reasoning explicit: it rides the cellular voice network, so it works in
/// places a data connection does not — which is the situation this entire
/// product is built for. That has a practical consequence the wording has to
/// respect: a message is billed and split in 160-character segments, so it is
/// kept short and the most actionable line goes first.

/// A composed message and what it will cost to send.
@immutable
class PositionMessage {
  const PositionMessage(this.body);

  final String body;

  /// GSM-7 segment count, the unit an SMS is billed and split in.
  ///
  /// A single segment holds 160 characters; once a message spills over, each
  /// segment carries 153 because the rest is used for reassembly headers.
  /// Characters outside the GSM-7 alphabet — which includes most non-Latin
  /// place names — force the whole message into UCS-2, where the limits are 70
  /// and 67.
  int get segmentCount {
    final unicode = _needsUnicode(body);
    final single = unicode ? 70 : 160;
    final multi = unicode ? 67 : 153;
    if (body.length <= single) return 1;
    return (body.length / multi).ceil();
  }

  /// Whether the body forces the costlier encoding.
  bool get isUnicode => _needsUnicode(body);

  static bool _needsUnicode(String text) {
    // A deliberately conservative check: anything outside printable ASCII is
    // treated as forcing UCS-2. The real GSM-7 alphabet has a handful of extra
    // Latin characters, but guessing generously would understate the cost of a
    // message, and understating it is the direction that hurts.
    return text.runes.any((r) => r < 0x20 && r != 0x0A || r > 0x7E);
  }

  @override
  String toString() => body;
}

/// Composes the message body for a position.
///
/// Ordered by what a recipient can act on fastest: the place name says roughly
/// where, the decimal degrees paste into any map or search engine, and the Plus
/// Code survives being read aloud over a voice call — which matters when the
/// reason for sending it is that data is unavailable.
///
/// The accuracy is included because a position without it invites more
/// confidence than it deserves, which is the failure FR-1.2 exists to prevent
/// and does not stop mattering once the position has been sent to someone else.
PositionMessage composePositionMessage({
  required PositionFix fix,
  PlaceMatch? match,
  String? prefix,
}) {
  final lines = <String>[];

  if (prefix != null && prefix.trim().isNotEmpty) {
    lines.add(prefix.trim());
  }

  if (match != null) {
    lines.add(match.proximity == Proximity.inside
        ? match.place.displayName
        : 'Near ${match.place.displayName}');
  }

  lines.add(formatDecimalDegreesPlain(fix.latitude, fix.longitude));
  lines.add('Plus Code: ${encodePlusCode(fix.latitude, fix.longitude)}');

  if (fix.accuracyMeters > 0) {
    lines.add('Accurate to about ${fix.accuracyMeters.round()} m');
  }

  return PositionMessage(lines.join('\n'));
}

/// Builds the `sms:` URI that opens the platform composer.
///
/// The body is percent-encoded by hand rather than passed through
/// [Uri.queryParameters], which encodes a space as `+`. Several messaging apps
/// take that literally and the recipient receives a coordinate full of plus
/// signs, which is both wrong and hard to diagnose after the fact.
///
/// [recipient] is optional: with none, the composer opens and the user chooses
/// who to send to, which is the right default for a position you might send to
/// anyone.
Uri smsUri({required String body, String? recipient}) {
  final to = (recipient ?? '').trim();
  return Uri.parse('sms:$to?body=${Uri.encodeComponent(body)}');
}
