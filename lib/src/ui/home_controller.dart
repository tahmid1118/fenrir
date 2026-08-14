import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/bundled_asset.dart';
import '../data/models.dart';
import '../data/place_repository.dart';
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

  Future<void> dispose();
}

/// The real data source: bundled assets extracted to storage.
class BundledHomeDataSource implements HomeDataSource {
  BundledHomeDataSource({
    BundledAssetStore? assets,
    Future<PlaceRepository> Function(String path)? openPlaces,
    Future<MbTilesTileProvider> Function(String path)? openBasemap,
  })  : _assets = assets ?? BundledAssetStore(),
        _openPlaces = openPlaces ?? PlaceRepository.openAt,
        _openBasemap = openBasemap ?? MbTilesTileProvider.openAt;

  final BundledAssetStore _assets;
  final Future<PlaceRepository> Function(String path) _openPlaces;
  final Future<MbTilesTileProvider> Function(String path) _openBasemap;

  PlaceRepository? _places;

  @override
  MbTilesTileProvider? tileProvider;

  @override
  Future<void> prepare() async {
    final places = await _assets.ensure(BundledAssetStore.places);
    final basemap = await _assets.ensure(BundledAssetStore.basemap);
    _places = await _openPlaces(places.path);
    tileProvider = await _openBasemap(basemap.path);
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
  Future<void> dispose() async {
    await _places?.close();
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
  })  : _location = locationService ?? LocationService(),
        _data = data ?? BundledHomeDataSource();

  final LocationService _location;
  final HomeDataSource _data;

  StreamSubscription<LocationState>? _states;

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
    unawaited(_location.dispose());
    unawaited(_data.dispose());
    super.dispose();
  }
}
