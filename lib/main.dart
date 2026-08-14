import 'package:flutter/material.dart';

import 'src/ui/home_screen.dart';
import 'src/ui/theme.dart';

void main() {
  runApp(const FenrirApp());
}

/// Root of the application.
///
/// There is no analytics initialisation, no crash reporter, no remote config
/// and no advertising identifier here, and there never should be: FR-9.2
/// requires that position data leave the device only through an action the
/// user explicitly initiates. An SDK wired up in this constructor would breach
/// that before the first frame is drawn.
class FenrirApp extends StatelessWidget {
  const FenrirApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fenrir',
      debugShowCheckedModeBanner: false,
      theme: buildFenrirTheme(),
      home: const HomeScreen(),
    );
  }
}
