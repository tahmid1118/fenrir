import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/bundled_asset.dart';
import '../data/models.dart';
import '../data/place_repository.dart';
import '../data/waypoint_store.dart';
import '../location/heading_service.dart';
import '../location/location_service.dart';
import '../location/position_fix.dart';
import '../map/mbtiles_tile_provider.dart';

/// How far the app has got with getting its bundled data onto disk.
enum AssetStatus { preparing, ready, failed }

/// Everything the home screen needs that touches storage.
///
/// Behind an interface so widget tests can supply one with no I/O at all.
/// That is not tidiness for its own sake: `sqflite_common_ffi` runs SQLite in a
/// background isolate and talks to it over ports, and inside the fake-async
/// zone `testWidgets` installs, those ports are never pumped — a real query
/// made from a widget test simply never returns. The real implementation is
/// covered by `place_repository_test` and `mbtiles_tile_provider_test`, which
/// use plain `test()` and hit the shipped archives directly.
abstract class HomeDataSource {
  /// Extracts the bundled assets and opens them.
  Future<void> prepare();

  /// Null until [prepare] succeeds, and after a failure.
  MbTilesTileProvider? get tileProvider;

  Future<PlaceMatch?> nearestPlace(double latitude, double longitude);

  /// Full-text search over place names (FR-8.1).
  Future<List<PlaceSearchResult>> searchPlaces(
    String query, {
    double? fromLatitude,
    double? fromLongitude,
  });

  /// Saved positions, newest first (FR-6.1).
  Future<List<Waypoint>> waypoints();

  Future<Waypoint> addWaypoint(Waypoint waypoint);

  Future<bool> removeWaypoint(int id);

  Future<void> dispose();
}

/// The real data source: bundled assets extracted to storage.
class BundledHomeDataSource implements HomeDataSource {
  BundledHomeDataSource({
    BundledAssetStore? assets,
    Future<PlaceRepository> Function(String path)? openPlaces,
    Future<MbTilesTileProvider> Function(String path)? openBasemap,
    Future<WaypointStore> Function()? openWaypoints,
  })  : _assets = assets ?? BundledAssetStore(),
        _openPlaces = openPlaces ?? PlaceRepository.openAt,
        _openBasemap = openBasemap ?? MbTilesTileProvider.openAt,
        _openWaypoints = openWaypoints ?? WaypointStore.open;

  final BundledAssetStore _assets;
  final Future<PlaceRepository> Function(String path) _openPlaces;
  final Future<MbTilesTileProvider> Function(String path) _openBasemap;
  final Future<WaypointStore> Function() _openWaypoints;

  PlaceRepository? _places;
  WaypointStore? _waypoints;

  @override
  MbTilesTileProvider? tileProvider;

  @override
  Future<void> prepare() async {
    final places = await _assets.ensure(BundledAssetStore.places);
    final basemap = await _assets.ensure(BundledAssetStore.basemap);
    _places = await _openPlaces(places.path);
    tileProvider = await _openBasemap(basemap.path);
    _waypoints = await _openWaypoints();
  }

  @override
  Future<PlaceMatch?> nearestPlace(double latitude, double longitude) async {
    return _places?.nearestPlace(latitude, longitude);
  }

  @override
  Future<List<PlaceSearchResult>> searchPlaces(
    String query, {
    double? fromLatitude,
    double? fromLongitude,
  }) async {
    return await _places?.searchPlaces(
          query,
          fromLatitude: fromLatitude,
          fromLongitude: fromLongitude,
        ) ??
        const [];
  }

  @override
  Future<List<Waypoint>> waypoints() async =>
      await _waypoints?.all() ?? const [];

  @override
  Future<Waypoint> addWaypoint(Waypoint waypoint) async {
    final store = _waypoints;
    if (store == null) {
      throw StateError('Saved places are not available on this device');
    }
    return store.add(waypoint);
  }

  @override
  Future<bool> removeWaypoint(int id) async =>
      await _waypoints?.remove(id) ?? false;

  @override
  Future<void> dispose() async {
    await _places?.close();
    await _waypoints?.close();
    await tileProvider?.dispose();
  }
}

/// Owns everything the home screen shows.
///
/// Kept apart from the widget so the state transitions NFR-6 enumerates can be
/// driven and asserted without pumping frames or touching a device.
class HomeController extends ChangeNotifier {
  HomeController({
    LocationService? locationService,
    HomeDataSource? data,
    HeadingService? headingService,
  })  : _location = locationService ?? LocationService(),
        _data = data ?? BundledHomeDataSource(),
        _heading = headingService ?? HeadingService();

  final LocationService _location;
  final HomeDataSource _data;
  final HeadingService _heading;

  StreamSubscription<LocationState>? _states;
  StreamSubscription<Heading?>? _headings;

  /// The latest compass reading, or null when there is no usable compass.
  Heading? heading;

  /// How the map is oriented (FR-4.3).
  MapOrientation orientation = MapOrientation.northUp;

  /// How far the map should be turned from north-up.
  ///
  /// Negative of the heading: to put the direction the device faces at the top
  /// of the screen, the map underneath has to turn the opposite way.
  double get mapRotationDegrees {
    if (orientation != MapOrientation.headingUp) return 0;
    final current = heading;
    return current == null ? 0 : -current.degrees;
  }

  /// Whether heading-up is offered at all. A device with no magnetometer
  /// should not be shown a control that cannot do anything.
  bool get hasCompass => heading != null;

  /// Switches between north-up and heading-up.
  void toggleOrientation() {
    if (!hasCompass) return;
    orientation = orientation.toggled;
    notifyListeners();
  }

  AssetStatus assetStatus = AssetStatus.preparing;
  String? assetError;

  LocationState locationState = const Searching();

  PlaceMatch? placeMatch;
  bool isResolvingPlace = false;

  /// Whether the map recentres as new readings arrive. Dropped as soon as the
  /// user drags the map, because fighting a user for control of the viewport
  /// is worse than losing the lock.
  bool followPosition = true;

  MbTilesTileProvider? get tileProvider => _data.tileProvider;

  PositionFix? get fix => switch (locationState) {
        Located(fix: final f) => f,
        _ => null,
      };

  FixQuality? qualityAt(DateTime now) => fix?.qualityAt(now);

  /// Prepares assets and starts listening for positions.
  ///
  /// Assets first: without the database there is nothing to resolve a position
  /// against, and without the archive there is no map to draw it on.
  Future<void> start() async {
    await _prepareAssets();
    _headings = _heading.headings().listen(_onHeading);
    _states = _location.states.listen(_onLocationState);
    await _location.start();
  }

  Future<void> _prepareAssets() async {
    try {
      await _data.prepare();
      assetStatus = AssetStatus.ready;
    } on Object catch (e) {
      // NFR-6: a defined, informative state. The map and the place name are
      // both gone here, but coordinates and Plus Codes are computed rather
      // than looked up, so the app is degraded rather than useless.
      assetStatus = AssetStatus.failed;
      assetError = e is BundledAssetException ? e.message : '$e';
    }
    notifyListeners();
  }

  void _onHeading(Heading? next) {
    heading = next;
    // A compass that stops being reliable while heading-up is on must not
    // freeze the map at whatever angle it happened to be. Falling back to
    // north-up is predictable, and predictable beats stuck.
    if (next == null && orientation == MapOrientation.headingUp) {
      orientation = MapOrientation.northUp;
    }
    notifyListeners();
  }

  void _onLocationState(LocationState state) {
    final previous = fix;
    locationState = state;
    notifyListeners();

    final current = fix;
    if (current == null) return;
    // The ticker re-emits the same reading once a second so its age can be
    // re-evaluated. Re-resolving the place each time would be sixty pointless
    // queries a minute.
    if (previous != null &&
        previous.latitude == current.latitude &&
        previous.longitude == current.longitude) {
      return;
    }
    unawaited(_resolvePlace(current));
  }

  Future<void> _resolvePlace(PositionFix fix) async {
    if (assetStatus != AssetStatus.ready) return;

    isResolvingPlace = true;
    notifyListeners();
    try {
      // A null match is the FR-3.3 result, not a failure, and must overwrite
      // any previous match. Otherwise walking out to sea leaves the last known
      // place on screen indefinitely.
      placeMatch = await _data.nearestPlace(fix.latitude, fix.longitude);
    } on Object {
      placeMatch = null;
    } finally {
      isResolvingPlace = false;
      notifyListeners();
    }
  }

  /// Re-runs the permission flow, for the user who granted it in system
  /// settings and came back.
  Future<void> retryLocation() => _location.start();

  /// Saves the current position (FR-6.1).
  ///
  /// Captures the accuracy and the resolved place name as they stand right
  /// now. Both are part of the record: a waypoint taken with a 200 metre fix
  /// means something different from one taken with a 4 metre fix, and the
  /// place name is what the user saw when they decided this spot mattered.
  ///
  /// Returns null when there is no fix to save.
  Future<Waypoint?> saveCurrentPosition({String? label, String? note}) async {
    final current = fix;
    if (current == null) return null;

    final saved = await _data.addWaypoint(Waypoint(
      label: label,
      note: note,
      latitude: current.latitude,
      longitude: current.longitude,
      accuracyMeters: current.accuracyMeters,
      altitudeMeters: current.altitudeMeters,
      placeName: placeMatch?.place.displayName,
      savedAt: DateTime.now().toUtc(),
    ));
    notifyListeners();
    return saved;
  }

  Future<List<Waypoint>> waypoints() => _data.waypoints();

  Future<bool> removeWaypoint(int id) async {
    final removed = await _data.removeWaypoint(id);
    if (removed) notifyListeners();
    return removed;
  }

  /// Searches place names, measuring from the current fix when there is one.
  Future<List<PlaceSearchResult>> search(String query) {
    final current = fix;
    return _data.searchPlaces(
      query,
      fromLatitude: current?.latitude,
      fromLongitude: current?.longitude,
    );
  }

  void setFollowPosition(bool value) {
    if (followPosition == value) return;
    followPosition = value;
    notifyListeners();
  }

  void recentre() {
    followPosition = true;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_states?.cancel());
    unawaited(_headings?.cancel());
    unawaited(_location.dispose());
    unawaited(_data.dispose());
    super.dispose();
  }
}
