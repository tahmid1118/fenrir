import 'package:flutter/material.dart';

import '../data/models.dart';

/// Names where the user is, and says how confident that name is (FR-3.2).
///
/// The coverage measured in the specification is the reason this widget is not
/// simply a label: Bangladesh has 161 places in the database to the United
/// States' 21,782, so a rural user can easily be tens of kilometres from the
/// nearest one. Printing that name unqualified would be confidently wrong.
///
/// Three states, all defined per NFR-6: resolved and close, resolved but
/// distant, and nothing nearby at all.
class PlaceBanner extends StatelessWidget {
  const PlaceBanner({super.key, required this.match, this.isResolving = false});

  /// Null means no known place within the search ceiling — over open water, or
  /// deep in a region the dataset does not cover. Not an error (FR-3.3).
  final PlaceMatch? match;

  final bool isResolving;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final match = this.match;

    final String primary;
    final String? secondary;
    final IconData icon;

    if (isResolving) {
      primary = 'Locating…';
      secondary = null;
      icon = Icons.more_horiz;
    } else if (match == null) {
      // Stated plainly. A distant false match would be worse than admitting
      // there is nothing to say.
      primary = 'No known place nearby';
      secondary = 'You are away from any place in the offline database';
      icon = Icons.explore_off;
    } else if (match.proximity == Proximity.inside) {
      primary = match.place.displayName;
      secondary = _distance(match.distanceKm);
      icon = Icons.place;
    } else {
      // "Near" rather than "in". This is the whole point of FR-3.2.
      primary = 'Near ${match.place.displayName}';
      secondary = '${_distance(match.distanceKm)} away';
      icon = Icons.near_me_outlined;
    }

    return Semantics(
      liveRegion: true,
      label: secondary == null ? primary : '$primary. $secondary',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              icon,
              size: 18,
              color: match == null && !isResolving
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  primary,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (secondary != null)
                  Text(
                    secondary,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Distances are rounded to what the fix can actually support. Reporting
  /// 1.29 km when the accuracy radius is 30 m implies precision that is not
  /// there.
  static String _distance(double km) {
    if (km < 1) return '${(km * 1000).round()} m';
    if (km < 10) return '${km.toStringAsFixed(1)} km';
    return '${km.round()} km';
  }
}
