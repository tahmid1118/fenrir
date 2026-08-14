import 'package:flutter/material.dart';

/// The single screen the app opens onto.
///
/// FR-9.1 requires that after granting location permission the user reaches a
/// working position display with no download, no account and no network, and
/// that no onboarding carousel gates the core function. That requirement is
/// satisfied as much by what is absent from this screen as by what is on it,
/// so there is deliberately no route stack, no wizard and no splash beyond the
/// platform one.
///
/// Currently a placeholder shell. Task 10 assembles the real screen from
/// `map_view.dart`, `place_banner.dart`, `position_panel.dart` and
/// `fix_indicator.dart`.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Fenrir',
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Know where you are. No signal required.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
