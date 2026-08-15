import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import 'mbtiles_archive.dart';

/// Serves tiles from several MBTiles archives, most detailed first (FR-4.2).
///
/// Regional packs are consulted before the bundled world basemap, so where a
/// pack is installed the map draws its full detail and where it is not the
/// basemap still answers. The user sees one map that gets sharper in places
/// they have downloaded, rather than two maps with a seam between them.
///
/// Archives that cannot contain a tile — wrong zoom, wrong part of the world —
/// are skipped without a query, which is what keeps the cost flat as packs
/// accumulate.
class LayeredTileProvider extends TileProvider {
  LayeredTileProvider(this._archives);

  /// Ordered most detailed first. The basemap belongs last.
  final List<MbTilesArchive> _archives;

  /// Replaces the archive list, for when a pack is installed or deleted.
  ///
  /// Closes the archives being dropped. The provider owns them, and installing
  /// or deleting packs a few times over a session would otherwise leak a
  /// SQLite connection and an open file handle each time — which on a desktop
  /// merely holds the file open, and on a phone eventually exhausts the
  /// per-process descriptor limit.
  ///
  /// An archive that appears in both lists is kept open, so a caller can hand
  /// back instances it still intends to use.
  Future<void> setArchives(List<MbTilesArchive> archives) async {
    final retained = archives.toSet();
    final dropped =
        _archives.where((a) => !retained.contains(a)).toList(growable: false);

    _archives
      ..clear()
      ..addAll(archives);

    for (final archive in dropped) {
      await archive.close();
    }
  }

  /// The highest zoom any installed archive provides for this position.
  ///
  /// Drives the "more detail is available" hint FR-4.2 asks for: if the best
  /// available zoom here is the bundled ceiling, the user is looking at
  /// upscaled tiles and might want a pack.
  int bestZoomAt(double latitude, double longitude) {
    var best = 0;
    for (final archive in _archives) {
      final bounds = archive.metadata.bounds;
      final inside = bounds == null ||
          (longitude >= bounds.west &&
              longitude <= bounds.east &&
              latitude >= bounds.south &&
              latitude <= bounds.north);
      if (inside && archive.metadata.maxZoom > best) {
        best = archive.metadata.maxZoom;
      }
    }
    return best;
  }

  /// The first archive that has this tile, or null.
  Future<Uint8List?> tileBytes(int zoom, int x, int y) async {
    for (final archive in _archives) {
      if (!archive.covers(zoom, x, y)) continue;
      final bytes = await archive.tileBytes(zoom, x, y);
      // An archive that covers the area but lacks this particular tile is not
      // the end of the search: a regional pack may have a hole the basemap
      // underneath can fill.
      if (bytes != null && bytes.isNotEmpty) return bytes;
    }
    return null;
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return _LayeredTileImage(this, coordinates.z, coordinates.x, coordinates.y);
  }

  @override
  Future<void> dispose() async {
    for (final archive in _archives) {
      await archive.close();
    }
    _archives.clear();
    super.dispose();
  }
}

/// Resolves a single tile across the layered archives.
///
/// A tile no archive holds resolves to a transparent image rather than
/// throwing. flutter_map requests tiles speculatively around the viewport and
/// past the edges of the world, so absence is ordinary; raising would put an
/// error box on the map, which NFR-6 forbids.
@immutable
class _LayeredTileImage extends ImageProvider<_LayeredTileImage> {
  const _LayeredTileImage(this.provider, this.z, this.x, this.y);

  final LayeredTileProvider provider;
  final int z;
  final int x;
  final int y;

  @override
  Future<_LayeredTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_LayeredTileImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _LayeredTileImage key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      _load(key, decode),
      informationCollector: () => [
        DiagnosticsProperty<String>('Tile', 'z$z/x$x/y$y'),
      ],
    );
  }

  Future<ImageInfo> _load(
    _LayeredTileImage key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await key.provider.tileBytes(key.z, key.x, key.y);
    if (bytes == null || bytes.isEmpty) {
      return ImageInfo(image: await _transparentTile());
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await decode(buffer);
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _LayeredTileImage &&
          other.provider == provider &&
          other.z == z &&
          other.x == x &&
          other.y == y);

  @override
  int get hashCode => Object.hash(provider, z, x, y);

  @override
  String toString() => 'LayeredTileImage(z$z/x$x/y$y)';
}

ui.Image? _transparentCache;

Future<ui.Image> _transparentTile() async {
  final cached = _transparentCache;
  if (cached != null) return cached;

  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 1, 1),
    Paint()..color = const Color(0x00000000),
  );
  final image = await recorder.endRecording().toImage(1, 1);
  return _transparentCache = image;
}
