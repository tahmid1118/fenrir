import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/main.dart';

void main() {
  testWidgets('the app builds and reaches the home screen', (tester) async {
    await tester.pumpWidget(const FenrirApp());

    expect(find.text('Fenrir'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FR-9.1: no onboarding gate stands between launch and content',
      (tester) async {
    await tester.pumpWidget(const FenrirApp());
    // A single pump, not pumpAndSettle: content must be on screen immediately,
    // not after a carousel, a splash animation or a sign-in round trip.
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('Know where you are. No signal required.'), findsOneWidget);
  });

  testWidgets('NFR-7: layout survives 200% text scaling', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: const FenrirApp(),
      ),
    );

    // No overflow exceptions are recorded during layout.
    expect(tester.takeException(), isNull);
  });
}
