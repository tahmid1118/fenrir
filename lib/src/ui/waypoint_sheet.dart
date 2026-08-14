import 'package:flutter/material.dart';

import '../data/models.dart';
import '../geo/haversine.dart';

/// Saved positions (FR-6.1).
///
/// Local storage only. Nothing here is uploaded, synchronised or backed up to
/// anyone's server — FR-9.2 and OUT-3 both rule that out — which is worth
/// saying on the screen, because users have learned to assume the opposite.
class WaypointSheet extends StatelessWidget {
  const WaypointSheet({
    super.key,
    required this.waypoints,
    required this.onDelete,
    required this.onSelected,
    this.fromLatitude,
    this.fromLongitude,
  });

  final List<Waypoint> waypoints;
  final Future<void> Function(Waypoint) onDelete;
  final ValueChanged<Waypoint> onSelected;

  /// The current position, for showing how far away each saved spot is.
  final double? fromLatitude;
  final double? fromLongitude;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (waypoints.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bookmark_border,
              size: 28,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 10),
            Text('No saved places yet', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Save where you are and it stays on this device.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    final origin = fromLatitude != null && fromLongitude != null;

    return ListView.separated(
      shrinkWrap: true,
      itemCount: waypoints.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: theme.dividerColor),
      itemBuilder: (context, i) {
        final waypoint = waypoints[i];
        final distance = origin
            ? distanceKm(
                fromLatitude!,
                fromLongitude!,
                waypoint.latitude,
                waypoint.longitude,
              )
            : null;

        return Dismissible(
          key: ValueKey(waypoint.id ?? waypoint.savedAt.microsecondsSinceEpoch),
          direction: DismissDirection.endToStart,
          background: ColoredBox(
            color: theme.colorScheme.errorContainer,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 20),
                child: Icon(
                  Icons.delete_outline,
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ),
          // Deleting a saved position is not recoverable, and it is the one
          // thing in this app the user cannot get back by walking outside.
          confirmDismiss: (_) => _confirm(context, waypoint),
          onDismissed: (_) => onDelete(waypoint),
          child: ListTile(
            leading: const Icon(Icons.bookmark, size: 20),
            title: Text(
              waypoint.displayLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              _subtitle(waypoint),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: distance == null
                ? null
                : Text(
                    _distance(distance),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
            onTap: () => onSelected(waypoint),
          ),
        );
      },
    );
  }

  Future<bool> _confirm(BuildContext context, Waypoint waypoint) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete saved place?'),
        content: Text(
          '"${waypoint.displayLabel}" will be removed from this device. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// The note if there is one, otherwise when it was saved and how good the
  /// fix was at the time.
  static String _subtitle(Waypoint waypoint) {
    final note = waypoint.note?.trim();
    if (note != null && note.isNotEmpty) return note;

    final accuracy = waypoint.accuracyMeters > 0
        ? ' · ±${waypoint.accuracyMeters.round()} m'
        : '';
    return '${_when(waypoint.savedAt)}$accuracy';
  }

  static String _when(DateTime savedAt) {
    final local = savedAt.toLocal();
    final now = DateTime.now();
    final difference = now.difference(local);

    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} h ago';
    if (difference.inDays < 7) return '${difference.inDays} d ago';

    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }

  static String _distance(double km) {
    if (km < 1) return '${(km * 1000).round()} m';
    if (km < 100) return '${km.toStringAsFixed(1)} km';
    return '${km.round()} km';
  }
}
