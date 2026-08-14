import 'dart:io';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A large read-only file shipped inside the app binary that has to exist on
/// the filesystem before it can be used.
///
/// SQLite cannot open a database out of `rootBundle` — it needs a real path —
/// and that applies to both Tier 1 payloads: the place database and the
/// basemap. Extraction is the price of bundling them.
@immutable
class BundledAsset {
  const BundledAsset({
    required this.assetPath,
    required this.fileName,
    required this.version,
  });

  /// Path as declared in `pubspec.yaml`.
  final String assetPath;

  /// Name to give the extracted copy.
  final String fileName;

  /// Bumped whenever the bundled bytes change, to force re-extraction.
  ///
  /// The database ships with `PRAGMA user_version` set to 0, so there is no
  /// stamp inside the file to compare against. This number, recorded beside
  /// the extracted copy, is the mechanism instead.
  final int version;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BundledAsset &&
          assetPath == other.assetPath &&
          fileName == other.fileName &&
          version == other.version);

  @override
  int get hashCode => Object.hash(assetPath, fileName, version);
}

/// Raised when an asset cannot be made available on disk.
class BundledAssetException implements Exception {
  const BundledAssetException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() =>
      'BundledAssetException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Copies bundled assets out of the app binary and onto the filesystem.
///
/// The loader and directory resolver are injectable so the extraction logic
/// can be tested without a device, a real asset bundle, or platform channels.
class BundledAssetStore {
  BundledAssetStore({
    Future<ByteData> Function(String assetPath)? loadAsset,
    Future<Directory> Function()? resolveDirectory,
  })  : _loadAsset = loadAsset ?? rootBundle.load,
        _resolveDirectory = resolveDirectory ?? getApplicationSupportDirectory;

  final Future<ByteData> Function(String assetPath) _loadAsset;
  final Future<Directory> Function() _resolveDirectory;

  /// The Tier 1 place database: 235,242 places behind FR-3.1.
  static const places = BundledAsset(
    assetPath: 'assets/db/places.db',
    fileName: 'places.db',
    version: 1,
  );

  /// The Tier 1 world basemap: 1,365 tiles, zoom 0-5, behind FR-4.1.
  ///
  /// Bump [BundledAsset.version] whenever `tools/build_basemap.dart` is re-run
  /// with different output, or devices that already extracted the old archive
  /// will keep using it.
  static const basemap = BundledAsset(
    assetPath: 'assets/map/basemap.mbtiles',
    fileName: 'basemap.mbtiles',
    version: 1,
  );

  /// Ensures [asset] exists on disk and returns it.
  ///
  /// Does nothing when an up-to-date copy is already present, which is the
  /// case on every launch after the first.
  Future<File> ensure(BundledAsset asset) async {
    final Directory directory;
    try {
      directory = await _resolveDirectory();
    } on Object catch (e) {
      throw BundledAssetException(
        'Could not resolve a directory to extract ${asset.fileName} into',
        e,
      );
    }

    final target = File(p.join(directory.path, asset.fileName));
    final marker = File('${target.path}.version');

    if (await _isUpToDate(target, marker, asset)) return target;

    return _extract(asset, target, marker);
  }

  /// Whether the extracted copy is present, complete and current.
  Future<bool> _isUpToDate(
    File target,
    File marker,
    BundledAsset asset,
  ) async {
    if (!await target.exists() || !await marker.exists()) return false;

    final String contents;
    try {
      contents = await marker.readAsString();
    } on FileSystemException {
      return false;
    }

    // Format is "<version>:<byte length>". The length is what catches a copy
    // that was interrupted midway -- by the process dying, or the device
    // running out of space -- and left a file that exists but is truncated.
    final parts = contents.trim().split(':');
    if (parts.length != 2) return false;

    final version = int.tryParse(parts[0]);
    final expectedLength = int.tryParse(parts[1]);
    if (version != asset.version || expectedLength == null) return false;

    return await target.length() == expectedLength;
  }

  Future<File> _extract(
    BundledAsset asset,
    File target,
    File marker,
  ) async {
    final ByteData data;
    try {
      data = await _loadAsset(asset.assetPath);
    } on Object catch (e) {
      throw BundledAssetException(
        'Could not read ${asset.assetPath} from the app bundle',
        e,
      );
    }

    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );

    try {
      await target.parent.create(recursive: true);

      // Write to a temporary file and rename it into place. A rename is atomic
      // on both platforms, so an interrupted extraction can never leave a
      // half-written file sitting at the real path. The marker is written last,
      // so a copy without a marker is always treated as absent.
      final temp = File('${target.path}.tmp');
      if (await temp.exists()) await temp.delete();
      await temp.writeAsBytes(bytes, flush: true);

      if (await marker.exists()) await marker.delete();
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);

      await marker.writeAsString(
        '${asset.version}:${bytes.length}',
        flush: true,
      );
    } on FileSystemException catch (e) {
      throw BundledAssetException(
        'Could not write ${asset.fileName} to storage. The device may be out '
        'of space.',
        e,
      );
    }

    return target;
  }
}
