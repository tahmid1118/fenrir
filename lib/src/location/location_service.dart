import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:geolocator/geolocator.dart';

import 'position_fix.dart';

/// The platform capabilities this service needs.
///
/// geolocator exposes these as static methods, which cannot be substituted in
/// a test. Routing them through an interface means the state machine below is
/// testable without a device, an emulator, or a satellite.
abstract class LocationSource {
  Future<bool> isLocationServiceEnabled();
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();
  Stream<PositionFix> positions();
}

/// The real implementation, backed by geolocator.
class GeolocatorSource implements LocationSource {
  const GeolocatorSource();

  @override
  Future<bool> isLocationServiceEnabled() =>
      Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();

  @override
  Stream<PositionFix> positions() {
    return Geolocator.getPositionStream(locationSettings: _settings())
        .map(_toFix);
  }

  static LocationSettings _settings() {
    // FR-1.1: the app must not silently degrade to network- or IP-based
    // positioning. `forceLocationManager` makes geolocator use Android's
    // LocationManager instead of the fused provider, and the fused provider is
    // precisely the thing that blends in Wi-Fi and cell positioning without
    // saying so.
    //
    // The cost is a slower first fix, because there is no network estimate to
    // show while the satellites are acquired. That is the correct trade for
    // this product -- an app whose entire claim is working without a signal
    // must not quietly depend on one -- and it is not a performance bug to be
    // optimised away later.
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        forceLocationManager: true,
        distanceFilter: 0,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
    );
  }

  static PositionFix _toFix(Position p) {
    return PositionFix(
      latitude: p.latitude,
      longitude: p.longitude,
      accuracyMeters: p.accuracy,
      timestamp: p.timestamp,
      altitudeMeters: p.altitude,
      altitudeAccuracyMeters: p.altitudeAccuracy,
      isMocked: p.isMocked,
    );
  }
}

/// Turns platform permission and position events into the [LocationState] the
/// UI renders.
class LocationService {
  LocationService({
    LocationSource? source,
    Stream<void>? ticker,
  })  : _source = source ?? const GeolocatorSource(),
        _externalTicker = ticker;

  final LocationSource _source;
  final Stream<void>? _externalTicker;

  final _controller = StreamController<LocationState>.broadcast();
  StreamSubscription<PositionFix>? _positions;
  StreamSubscription<void>? _ticks;
  Timer? _ownTicker;

  LocationState _state = const Searching();

  /// The current state, also replayed to new listeners of [states].
  LocationState get state => _state;

  Stream<LocationState> get states => _controller.stream;

  /// Checks preconditions, requests permission if needed, and begins
  /// listening.
  ///
  /// Safe to call again after a denial: a user who grants permission in system
  /// settings and returns to the app should not have to restart it.
  Future<void> start() async {
    if (!await _source.isLocationServiceEnabled()) {
      _emit(const ServicesDisabled());
      return;
    }

    var permission = await _source.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await _source.requestPermission();
    }

    switch (permission) {
      case LocationPermission.denied:
        _emit(const PermissionDenied(permanently: false));
        return;
      case LocationPermission.deniedForever:
        _emit(const PermissionDenied(permanently: true));
        return;
      case LocationPermission.unableToDetermine:
        // Treated as a soft denial: prompting again is harmless and is more
        // useful than an error the user can do nothing about.
        _emit(const PermissionDenied(permanently: false));
        return;
      case LocationPermission.whileInUse:
      case LocationPermission.always:
        break;
    }

    _emit(const Searching());
    await _positions?.cancel();
    _positions = _source.positions().listen(
      (fix) => _emit(Located(fix)),
      onError: (Object _) {
        // A stream error means the receiver stopped delivering. Falling back to
        // searching is honest; keeping the last fix on screen indefinitely is
        // what FR-1.2 forbids.
        _emit(const Searching());
      },
    );

    _startTicker();
  }

  /// Re-emits the current state once a second while a fix is held.
  ///
  /// Without this a fix that stops updating stays on screen looking fresh
  /// forever, because nothing prompts the UI to re-evaluate its age. That is
  /// the precise failure FR-1.2 exists to prevent, so the passage of time has
  /// to be an event in its own right.
  void _startTicker() {
    _ticks?.cancel();
    _ownTicker?.cancel();

    if (_externalTicker != null) {
      _ticks = _externalTicker.listen((_) => _retick());
      return;
    }
    _ownTicker = Timer.periodic(const Duration(seconds: 1), (_) => _retick());
  }

  void _retick() {
    if (_state is Located && !_controller.isClosed) {
      _controller.add(_state);
    }
  }

  void _emit(LocationState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  Future<void> dispose() async {
    _ownTicker?.cancel();
    await _ticks?.cancel();
    await _positions?.cancel();
    await _controller.close();
  }
}
