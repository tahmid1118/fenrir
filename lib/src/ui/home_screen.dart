import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../geo/coordinate_formats.dart';
import '../location/position_fix.dart';
import 'compass_rose.dart';
import 'fix_indicator.dart';
import 'home_controller.dart';
import 'map_view.dart';
import 'place_banner.dart';
import 'position_panel.dart';
import 'search_sheet.dart';
import 'waypoint_sheet.dart';

/// The single screen the app opens onto.
///
/// FR-9.1 requires that after granting location permission the user reaches a
/// working position display with no download, no account and no network, and
/// that no onboarding carousel gates the core function. That is satisfied as
/// much by what is absent here as by what is present: there is no route stack,
/// no wizard, no sign-in.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.controller, this.clock});

  /// Injected by tests; the app builds its own.
  final HomeController? controller;

  /// Ticks the clock that ages the fix on screen.
  ///
  /// Injectable so tests can advance time deliberately instead of waiting, and
  /// so the widget leaves no pending timer behind when it is torn down.
  final Stream<DateTime>? clock;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HomeController _controller;
  late final bool _ownsController;

  CoordinateFormat _format = CoordinateFormat.decimalDegrees;

  /// Drives the clock that ages the fix on screen.
  ///
  /// The controller re-emits the held reading once a second, but the *label*
  /// also has to be recomputed against the current time, which is why the
  /// screen keeps its own notion of now rather than reading the clock once.
  DateTime _now = DateTime.now();
  StreamSubscription<DateTime>? _clock;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? HomeController();
    _controller.addListener(_onChanged);
    if (_ownsController) unawaited(_controller.start());

    final clock = widget.clock ??
        Stream<DateTime>.periodic(
          const Duration(seconds: 1),
          (_) => DateTime.now(),
        );
    _clock = clock.listen((now) {
      if (mounted) setState(() => _now = now);
    });
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Opens offline search (FR-8.1).
  ///
  /// A sheet rather than a route: FR-9.1 is about the position display never
  /// being gated, and a modal the user can dismiss with a swipe keeps the map
  /// one gesture away.
  Future<void> _openSearch() async {
    final selected = await showModalBottomSheet<
        ({double latitude, double longitude, String label, String? detail})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.72,
          child: SearchSheet(
            onSearch: _controller.search,
            onSelected: (result) => Navigator.of(context).pop((
              latitude: result.place.latitude,
              longitude: result.place.longitude,
              label: result.place.name,
              detail: result.place.displayName,
            )),
            onCoordinate: (coordinate) => Navigator.of(context).pop((
              latitude: coordinate.latitude,
              longitude: coordinate.longitude,
              label: formatDecimalDegreesPlain(
                coordinate.latitude,
                coordinate.longitude,
              ),
              detail: coordinate.format.label,
            )),
          ),
        ),
      ),
    );

    if (selected != null && mounted) {
      setState(() => _searchTarget = selected);
    }
  }

  /// Saves the current position, then offers to name it (FR-6.1).
  ///
  /// Saved first, named second. The user pressed save because they are
  /// somewhere worth recording, and making the record depend on them finishing
  /// a dialogue risks losing the position to a dropped phone or a closed app.
  Future<void> _saveCurrentPosition() async {
    final Waypoint? saved;
    try {
      saved = await _controller.saveCurrentPosition();
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
      return;
    }
    if (saved == null || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved ${saved.displayLabel}'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(_controller.removeWaypoint(saved!.id!)),
        ),
      ),
    );
  }

  /// Shows saved positions (FR-6.1).
  Future<void> _openWaypoints() async {
    final waypoints = await _controller.waypoints();
    if (!mounted) return;

    final chosen = await showModalBottomSheet<Waypoint>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: StatefulBuilder(
          builder: (context, setSheetState) => WaypointSheet(
            waypoints: waypoints,
            fromLatitude: _controller.fix?.latitude,
            fromLongitude: _controller.fix?.longitude,
            onDelete: (w) async {
              await _controller.removeWaypoint(w.id!);
              setSheetState(() => waypoints.remove(w));
            },
            onSelected: (w) => Navigator.of(context).pop(w),
          ),
        ),
      ),
    );

    if (chosen != null && mounted) {
      setState(() {
        _searchTarget = (
          latitude: chosen.latitude,
          longitude: chosen.longitude,
          label: chosen.displayLabel,
          detail: 'Saved place',
        );
      });
    }
  }

  /// Something the user searched for, shown on the map until dismissed.
  ///
  /// Either a place from the database or a coordinate they pasted; the map
  /// treats both the same way.
  ({
    double latitude,
    double longitude,
    String label,
    String? detail,
  })? _searchTarget;

  @override
  void dispose() {
    unawaited(_clock?.cancel());
    _controller.removeListener(_onChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fix = _controller.fix;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: MapView(
              tileProvider: _controller.tileProvider,
              fix: fix,
              quality: _controller.qualityAt(_now),
              followPosition: _controller.followPosition,
              onUserPanned: () => _controller.setFollowPosition(false),
              rotationDegrees: _controller.mapRotationDegrees,
              target: _searchTarget == null
                  ? null
                  : (
                      latitude: _searchTarget!.latitude,
                      longitude: _searchTarget!.longitude,
                      label: _searchTarget!.label,
                    ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: FixIndicator(
                          state: _controller.locationState,
                          now: _now,
                        ),
                      ),
                      const Spacer(),
                      if (_controller.hasCompass) ...[
                        CompassRose(
                          orientation: _controller.orientation,
                          heading: _controller.heading,
                          mapRotationDegrees: _controller.mapRotationDegrees,
                          onTap: _controller.toggleOrientation,
                        ),
                        const SizedBox(width: 8),
                      ],
                      _SavedButton(onPressed: _openWaypoints),
                      const SizedBox(width: 8),
                      _SearchButton(onPressed: _openSearch),
                      if (fix != null && !_controller.followPosition) ...[
                        const SizedBox(width: 8),
                        _RecentreButton(onPressed: _controller.recentre),
                      ],
                    ],
                  ),
                  if (_searchTarget != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _TargetChip(
                        target: _searchTarget!,
                        onDismiss: () => setState(() => _searchTarget = null),
                      ),
                    ),
                  if (_controller.assetStatus != AssetStatus.ready)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _AssetNotice(
                        status: _controller.assetStatus,
                        error: _controller.assetError,
                      ),
                    ),
                  // The sheet sits at the bottom and scrolls if it cannot
                  // fit. At 200% text scaling NFR-7 asks for, the resolved
                  // place, the coordinates and the actions are taller than a
                  // phone screen, and a fixed layout clips them silently.
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: SingleChildScrollView(
                        child: _Sheet(child: _body(theme, fix)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme, PositionFix? fix) {
    // Every branch here is one of the states NFR-6 requires be defined. None
    // of them is a blank.
    switch (_controller.locationState) {
      case ServicesDisabled():
        return _Message(
          icon: Icons.location_disabled,
          title: 'Location services are off',
          body: 'Fenrir needs the device receiver switched on. Nothing is '
              'sent anywhere — the fix stays on this device.',
          action: 'Try again',
          onAction: _controller.retryLocation,
        );

      case PermissionDenied(permanently: final permanent):
        return _Message(
          icon: Icons.lock_outline,
          title: 'Location permission needed',
          body: permanent
              ? 'Permission was denied permanently. Enable location for '
                  'Fenrir in system settings, then come back.'
              : 'Fenrir shows where you are. Your position never leaves the '
                  'device unless you share it yourself.',
          action: permanent ? 'Try again' : 'Allow location',
          onAction: _controller.retryLocation,
        );

      case Searching():
        return const _Message(
          icon: Icons.satellite_alt,
          title: 'Acquiring satellites',
          body: 'Fenrir uses the GNSS receiver directly rather than nearby '
              'networks, so the first fix outdoors can take a moment.',
        );

      case Located(fix: final located):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            PlaceBanner(
              match: _controller.placeMatch,
              isResolving: _controller.isResolvingPlace,
            ),
            Divider(height: 22, color: theme.dividerColor),
            PositionPanel(
              fix: located,
              format: _format,
              match: _controller.placeMatch,
              onFormatChanged: (f) => setState(() => _format = f),
              onSave: _saveCurrentPosition,
            ),
          ],
        );
    }
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          body,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (action != null) ...[
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: onAction,
            child: Text(action!),
          ),
        ],
      ],
    );
  }
}

class _AssetNotice extends StatelessWidget {
  const _AssetNotice({required this.status, required this.error});

  final AssetStatus status;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preparing = status == AssetStatus.preparing;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.85,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (preparing)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: theme.colorScheme.error,
              ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                preparing
                    // First launch only. The place database is 25.8 MB and
                    // SQLite cannot read it out of the app bundle.
                    ? 'Preparing offline data…'
                    : error ?? 'Offline data unavailable',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Names the place a search marker refers to, and lets it be cleared.
///
/// A pin on the map with nothing explaining it is the kind of unexplained
/// state NFR-6 rules out.
class _TargetChip extends StatelessWidget {
  const _TargetChip({required this.target, required this.onDismiss});

  final ({double latitude, double longitude, String label, String? detail})
      target;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.92,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.tertiary
            .withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.place, size: 16, color: theme.colorScheme.tertiary),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    target.label,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (target.detail != null)
                    Text(
                      target.detail!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: 'Clear searched place',
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

class _SavedButton extends StatelessWidget {
  const _SavedButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // excludeSemantics stops TalkBack seeing this twice. IconButton's own
    // `tooltip` contributes its own semantics node on Android, so without it
    // a screen-reader swipe lands on "Saved places" from this Semantics and
    // then on a second, separate "Saved places" stop from the tooltip --
    // found by dumping the actual accessibility tree on a device, where a
    // widget test checking this Semantics node in isolation would not have
    // shown the duplicate.
    return Semantics(
      button: true,
      label: 'Saved places',
      excludeSemantics: true,
      child: IconButton.filledTonal(
        onPressed: onPressed,
        icon: const Icon(Icons.bookmarks_outlined, size: 20),
        tooltip: 'Saved places',
      ),
    );
  }
}

class _SearchButton extends StatelessWidget {
  const _SearchButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // See _SavedButton: without excludeSemantics this and the IconButton's
    // tooltip each produce a focus stop, and here with *different* wording
    // -- "Search places offline" from this label, "Search places" from the
    // tooltip -- which is worse than a plain duplicate.
    return Semantics(
      button: true,
      label: 'Search places offline',
      excludeSemantics: true,
      child: IconButton.filledTonal(
        onPressed: onPressed,
        icon: const Icon(Icons.search, size: 20),
        tooltip: 'Search places',
      ),
    );
  }
}

class _RecentreButton extends StatelessWidget {
  const _RecentreButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // See _SavedButton.
    return Semantics(
      button: true,
      label: 'Centre the map on my position',
      excludeSemantics: true,
      child: IconButton.filledTonal(
        onPressed: onPressed,
        icon: const Icon(Icons.my_location, size: 20),
        tooltip: 'Centre on my position',
      ),
    );
  }
}
