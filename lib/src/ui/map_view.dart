import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../location/position_fix.dart';
import '../map/mbtiles_tile_provider.dart';
import 'theme.dart';

/// The offline map (FR-4.1).
///
/// Renders the bundled Tier 1 basemap with the user's position on it, from
/// first launch, anywhere on Earth, with no download and no network. That is
/// the product's differentiating claim against every competitor audited in the
/// specification, all of which show nothing useful until a region is
/// downloaded.
class MapView extends StatefulWidget {
  const MapView({
    super.key,
    required this.tileProvider,
    required this.fix,
    required this.quality,
    this.followPosition = true,
    this.onUserPanned,
    this.target,
    this.rotationDegrees = 0,
  });

  /// How far the map is turned from north-up, in degrees (FR-4.3).
  ///
  /// Applied as flutter_map's own rotation rather than by rotating a widget,
  /// so tiles, markers and the accuracy circle all turn together and stay
  /// registered with each other.
  final double rotationDegrees;

  /// A place chosen from search, marked so the user can see where it is
  /// relative to them (FR-8.1).
  final ({double latitude, double longitude, String label})? target;

  /// Null while the archive is still being extracted on first run.
  final MbTilesTileProvider? tileProvider;

  /// Null until the receiver produces a reading.
  final PositionFix? fix;

  final FixQuality? quality;

  /// Whether the map recentres itself as new readings arrive.
  final bool followPosition;

  /// Called when the user drags the map, so the caller can drop follow mode.
  final VoidCallback? onUserPanned;

  /// The zoom the bundled basemap actually contains.
  ///
  /// Beyond this the tiles are upscaled rather than replaced. FR-4.2 will fill
  /// the gap with regional packs; until then this is the seam.
  static const double bundledMaxZoom = 5;

  /// How far the user may zoom in past the bundled detail.
  ///
  /// The upscaled basemap turns soft well before this, but blocking the gesture
  /// is worse: the accuracy circle and the marker stay meaningful at close
  /// zoom, and an unresponsive map reads as broken.
  static const double interactiveMaxZoom = 16;

  static const double defaultZoom = 4;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final MapController _controller = MapController();
  bool _ready = false;

  @override
  void didUpdateWidget(MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;

    if (widget.rotationDegrees != oldWidget.rotationDegrees) {
      _controller.rotate(widget.rotationDegrees);
    }

    final fix = widget.fix;
    if (fix == null || !widget.followPosition) return;

    final moved = oldWidget.fix?.latitude != fix.latitude ||
        oldWidget.fix?.longitude != fix.longitude;
    if (moved) {
      _controller.move(
        LatLng(fix.latitude, fix.longitude),
        _controller.camera.zoom,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fix = widget.fix;
    final centre = fix == null
        ? const LatLng(20, 0)
        : LatLng(fix.latitude, fix.longitude);

    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: centre,
        // Without a fix there is nothing to centre on, so the map opens on the
        // world rather than an arbitrary place. NFR-6: a defined state, not a
        // blank one.
        initialZoom: fix == null ? 1.5 : MapView.defaultZoom,
        initialRotation: widget.rotationDegrees,
        minZoom: 0,
        maxZoom: MapView.interactiveMaxZoom,
        backgroundColor: theme.colorScheme.surface,
        // Deliberately unconstrained. Pinning the camera to the world bounds
        // asserts the moment the viewport is taller than the world, which
        // happens on a phone at low zoom, and flutter_map turns that into a
        // hard failure rather than a clamp. Panning past the poles simply
        // reveals the themed background, which is what every mainstream map
        // does and is a defined state rather than a blank one.
        interactionOptions: const InteractionOptions(
          // Rotation is deliberately off. FR-4.3 asks for a heading-up mode
          // with a compass rose, and a map that can be rotated by accident
          // without one leaves the user unable to find north again.
          flags: InteractiveFlag.drag |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.scrollWheelZoom |
              InteractiveFlag.flingAnimation,
        ),
        onMapReady: () => setState(() => _ready = true),
        onPointerDown: (_, _) => widget.onUserPanned?.call(),
      ),
      children: [
        if (widget.tileProvider != null)
          TileLayer(
            tileProvider: widget.tileProvider,
            // Past zoom 5 the bundled tiles are upscaled rather than absent.
            // Blurring is the graceful degradation NFR-6 wants; going blank is
            // exactly what it forbids.
            maxNativeZoom: MapView.bundledMaxZoom.toInt(),
            maxZoom: MapView.interactiveMaxZoom,
            tileDisplay: const TileDisplay.instantaneous(),
            // No network fallback exists, and none should: NFR-1 requires the
            // map to render with zero outbound requests.
            errorTileCallback: (_, _, _) {},
          ),
        if (widget.target != null) _targetLayer(theme, widget.target!),
        if (fix != null) ..._positionLayers(theme, fix),
        _attribution(theme),
      ],
    );
  }

  /// Marks a searched-for place, drawn beneath the position marker so it can
  /// never obscure where the user actually is.
  Widget _targetLayer(
    ThemeData theme,
    ({double latitude, double longitude, String label}) target,
  ) {
    return MarkerLayer(
      markers: [
        Marker(
          point: LatLng(target.latitude, target.longitude),
          width: 26,
          height: 26,
          child: Semantics(
            label: 'Searched place: ${target.label}',
            // A boundary of its own. Without it this merged into whatever
            // else sits in the map's Stack without an intervening semantics
            // container -- found on a device as "Your position, copyright
            // Natural Earth, copyright GeoNames..." read as one announcement,
            // the marker's label concatenated onto the attribution control's
            // text even though "Attributions" also exists as its own button.
            container: true,
            child: Icon(
              Icons.place,
              size: 26,
              color: theme.colorScheme.tertiary,
              shadows: [
                Shadow(color: theme.colorScheme.surface, blurRadius: 3),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _positionLayers(ThemeData theme, PositionFix fix) {
    final colours = theme.extension<FixStatusColors>()!;
    final colour = switch (widget.quality) {
      FixQuality.acquired => colours.acquired,
      FixQuality.degraded => colours.degraded,
      FixQuality.stale => colours.stale,
      null => colours.absent,
    };
    final point = LatLng(fix.latitude, fix.longitude);

    return [
      // The accuracy radius, drawn to scale in metres. FR-1.2 requires the user
      // never be shown a confident position that is actually coarse, and a
      // circle sized in real metres says that more directly than any number.
      CircleLayer(
        circles: [
          CircleMarker(
            point: point,
            radius: fix.accuracyMeters,
            useRadiusInMeter: true,
            color: colour.withValues(alpha: 0.12),
            borderColor: colour.withValues(alpha: 0.45),
            borderStrokeWidth: 1,
          ),
        ],
      ),
      MarkerLayer(
        markers: [
          Marker(
            point: point,
            width: 22,
            height: 22,
            child: Semantics(
              label: 'Your position',
              // See the searched-place marker above: without its own
              // boundary this merges with unrelated semantics sharing the
              // map's Stack.
              container: true,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colour,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 3,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  /// Attribution is a licence obligation, not decoration.
  ///
  /// GeoNames is CC BY 4.0 and requires it; Open Location Code is Apache 2.0
  /// and requires notice. Natural Earth is public domain and asks only as a
  /// courtesy. See NOTICE.md.
  Widget _attribution(ThemeData theme) {
    return RichAttributionWidget(
      alignment: AttributionAlignment.bottomLeft,
      showFlutterMapAttribution: false,
      animationConfig: const ScaleRAWA(),
      attributions: [
        TextSourceAttribution(
          'Natural Earth',
          onTap: null,
        ),
        TextSourceAttribution(
          'GeoNames (CC BY 4.0)',
          onTap: null,
        ),
        TextSourceAttribution(
          'Plus Codes (Apache 2.0)',
          onTap: null,
        ),
      ],
    );
  }
}
