import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/src/data/models.dart';
import 'package:fenrir/src/location/position_fix.dart';
import 'package:fenrir/src/share/position_message.dart';

void main() {
  PositionFix fix({
    double lat = 23.7461,
    double lon = 90.3742,
    double accuracy = 6,
  }) =>
      PositionFix(
        latitude: lat,
        longitude: lon,
        accuracyMeters: accuracy,
        timestamp: DateTime.utc(2026, 8, 15, 3, 30),
      );

  PlaceMatch match({
    String name = 'Dhanmondi',
    Proximity proximity = Proximity.inside,
    double distanceKm = 1.29,
  }) {
    return PlaceMatch(
      place: Place(
        id: 1,
        name: name,
        admin1: 'Dhaka Division',
        admin2: 'Dhaka',
        country: 'BD',
        latitude: 23.74,
        longitude: 90.385,
        population: 54210,
        timeZone: 'Asia/Dhaka',
      ),
      distanceKm: distanceKm,
      proximity: proximity,
    );
  }

  group('FR-7.1 message content', () {
    test('carries the place name, coordinates and Plus Code', () {
      final message = composePositionMessage(fix: fix(), match: match());

      expect(message.body, contains('Dhanmondi, Dhaka, Dhaka Division, BD'));
      expect(message.body, contains('23.746100, 90.374200'));
      expect(message.body, contains('Plus Code:'));
      expect(message.body, contains('6 m'));
    });

    test('leads with the place name, then the pasteable coordinates', () {
      // Ordered by what a recipient can act on fastest.
      final lines = composePositionMessage(fix: fix(), match: match())
          .body
          .split('\n');
      expect(lines.first, 'Dhanmondi, Dhaka, Dhaka Division, BD');
      expect(lines[1], '23.746100, 90.374200');
    });

    test('says "near" when the match is not close', () {
      // FR-3.2's honesty has to survive being sent to someone else.
      final message = composePositionMessage(
        fix: fix(),
        match: match(proximity: Proximity.near, distanceKm: 32),
      );
      expect(message.body, startsWith('Near Dhanmondi'));
    });

    test('works with no resolved place at all', () {
      // FR-3.3's open water. The coordinates are still worth sending.
      final message = composePositionMessage(fix: fix(lat: 30, lon: -40));
      expect(message.body, contains('30.000000, -40.000000'));
      expect(message.body, contains('Plus Code:'));
      expect(message.body, isNot(contains('Near')));
    });

    test('omits accuracy when the receiver did not report one', () {
      final message = composePositionMessage(fix: fix(accuracy: 0));
      expect(message.body, isNot(contains('Accurate to')));
    });

    test('always states the accuracy when there is one', () {
      // A position without it invites more confidence than it deserves, and
      // that does not stop mattering once it has been sent to someone else.
      final message = composePositionMessage(fix: fix(accuracy: 250));
      expect(message.body, contains('Accurate to about 250 m'));
    });

    test('an optional prefix leads the message', () {
      final message = composePositionMessage(
        fix: fix(),
        match: match(),
        prefix: 'Need help',
      );
      expect(message.body, startsWith('Need help\n'));
    });

    test('a blank prefix adds nothing', () {
      final plain = composePositionMessage(fix: fix(), match: match()).body;
      for (final blank in ['', '   ', '\n']) {
        expect(
          composePositionMessage(fix: fix(), match: match(), prefix: blank)
              .body,
          plain,
        );
      }
    });
  });

  group('SMS cost', () {
    test('a typical message fits in one segment', () {
      // SMS is billed and split in segments, so the wording is kept short on
      // purpose. A message that silently costs three times as much is a poor
      // way to tell someone where you are.
      final message = composePositionMessage(fix: fix(), match: match());
      expect(message.segmentCount, 1);
      expect(message.isUnicode, isFalse);
    });

    test('a non-Latin place name forces the costlier encoding', () {
      // Most of the world's place names are outside GSM-7, and the limit drops
      // from 160 characters to 70 when even one of them appears.
      final message = composePositionMessage(
        fix: fix(),
        match: match(name: '上海'),
      );
      expect(message.isUnicode, isTrue);
      expect(message.segmentCount, greaterThanOrEqualTo(2));
    });

    test('segment counting follows the GSM-7 and UCS-2 boundaries', () {
      expect(const PositionMessage('a').segmentCount, 1);
      expect(PositionMessage('a' * 160).segmentCount, 1);
      // Past 160 the headers cost seven characters per segment.
      expect(PositionMessage('a' * 161).segmentCount, 2);
      expect(PositionMessage('a' * 306).segmentCount, 2);
      expect(PositionMessage('a' * 307).segmentCount, 3);

      expect(const PositionMessage('上').segmentCount, 1);
      expect(PositionMessage('上' * 70).segmentCount, 1);
      expect(PositionMessage('上' * 71).segmentCount, 2);
    });

    test('a newline does not count as unicode', () {
      // The body is multi-line by design; treating that as UCS-2 would halve
      // the budget for no reason.
      expect(const PositionMessage('a\nb').isUnicode, isFalse);
    });
  });

  group('the sms: URI', () {
    test('encodes the body so the composer opens prefilled', () {
      final uri = smsUri(body: 'Hello there');
      expect(uri.scheme, 'sms');
      expect(uri.toString(), contains('body=Hello%20there'));
    });

    test('encodes a space as %20, never as a plus sign', () {
      // Uri.queryParameters would encode a space as "+", and several messaging
      // apps take that literally -- the recipient then gets a coordinate full
      // of plus signs, which is wrong and hard to diagnose afterwards.
      final uri = smsUri(body: '23.746100, 90.374200');
      expect(uri.toString(), contains('%20'));
      expect(uri.toString(), isNot(contains('+')));
    });

    test('survives newlines and punctuation', () {
      final body = composePositionMessage(fix: fix(), match: match()).body;
      final uri = smsUri(body: body);
      expect(uri.toString(), contains('%0A'));
      expect(() => Uri.parse(uri.toString()), returnsNormally);
      // And decodes back to exactly what was composed.
      expect(
        Uri.decodeComponent(uri.toString().split('body=').last),
        body,
      );
    });

    test('no recipient opens the composer for the user to choose', () {
      // The right default for a position that might go to anyone.
      expect(smsUri(body: 'x').toString(), startsWith('sms:?'));
      expect(smsUri(body: 'x', recipient: '   ').toString(),
          startsWith('sms:?'));
    });

    test('a recipient is placed before the query', () {
      expect(
        smsUri(body: 'x', recipient: '+8801700000000').toString(),
        startsWith('sms:+8801700000000?'),
      );
    });

    test('a non-Latin body round-trips', () {
      final uri = smsUri(body: '上海, 中国');
      expect(
        Uri.decodeComponent(uri.toString().split('body=').last),
        '上海, 中国',
      );
    });
  });
}
