import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'region_pack.dart';

/// Installed regional packs on disk (FR-5.2, FR-5.3).
///
/// Packs live in their own directory, separate from the bundled assets and from
/// saved waypoints. FR-5.3 requires that deleting a pack never touch Tier 1 or
/// user data, and separate directories make that structural rather than a rule
/// someone has to remember.
///
/// There is no expiry, no cap on how many packs may be kept, and no
/// revalidation. FR-5.2 asks for exactly that, and the store simply has no
/// mechanism for any of it.
class PackStore {
  PackStore(this.directory);

  final Directory directory;

  static const String _partialSuffix = '.part';

  static Future<PackStore> open({Directory? directory}) async {
    final resolved = directory ??
        Directory(p.join(
          (await getApplicationSupportDirectory()).path,
          'packs',
        ));
    await resolved.create(recursive: true);
    return PackStore(resolved);
  }

  File fileFor(String packId) =>
      File(p.join(directory.path, '$packId.mbtiles'));

  /// Where a download in progress accumulates.
  ///
  /// Kept beside the final file rather than in a temporary directory: a
  /// half-finished pack can be hundreds of megabytes, and the platform is free
  /// to clear temporary storage at any moment, which would silently discard a
  /// download the user has been waiting on.
  File partialFor(String packId) =>
      File('${fileFor(packId).path}$_partialSuffix');

  bool isInstalled(String packId) => fileFor(packId).existsSync();

  /// Bytes already downloaded for a paused or interrupted pack.
  int partialBytes(String packId) {
    final partial = partialFor(packId);
    return partial.existsSync() ? partial.lengthSync() : 0;
  }

  /// Every installed pack file, whether or not the catalogue still lists it.
  ///
  /// Listing the disk rather than a manifest means a pack whose catalogue entry
  /// has gone is still visible and still deletable, instead of becoming
  /// invisible storage the user cannot reclaim.
  List<String> installedIds() {
    if (!directory.existsSync()) return const [];
    return directory
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .where((n) => n.endsWith('.mbtiles'))
        .map((n) => n.substring(0, n.length - '.mbtiles'.length))
        .toList()
      ..sort();
  }

  int bytesFor(String packId) {
    final file = fileFor(packId);
    return file.existsSync() ? file.lengthSync() : 0;
  }

  /// Total bytes used by packs, including partial downloads (FR-5.3).
  ///
  /// Partial downloads are counted because they occupy the disk. A storage
  /// screen that omitted them would understate usage by however much the user
  /// had downloaded before pausing.
  int totalBytes() {
    if (!directory.existsSync()) return 0;
    var total = 0;
    for (final entity in directory.listSync()) {
      if (entity is File) total += entity.lengthSync();
    }
    return total;
  }

  DateTime? installedAt(String packId) {
    final file = fileFor(packId);
    return file.existsSync() ? file.statSync().modified : null;
  }

  /// Removes a pack and any partial download for it.
  ///
  /// Returns whether anything was removed. Touches only this pack's files.
  Future<bool> remove(String packId) async {
    var removed = false;
    for (final file in [fileFor(packId), partialFor(packId)]) {
      if (await file.exists()) {
        await file.delete();
        removed = true;
      }
    }
    return removed;
  }

  /// Promotes a completed download to an installed pack.
  ///
  /// Renames rather than copies: a rename is atomic, so an interruption can
  /// never leave a half-file sitting at the real path where it would be opened
  /// as a valid archive.
  Future<File> install(String packId) async {
    final partial = partialFor(packId);
    if (!await partial.exists()) {
      throw StateError('No completed download for $packId');
    }
    final target = fileFor(packId);
    if (await target.exists()) await target.delete();
    return partial.rename(target.path);
  }

  /// Reads a catalogue of available packs from JSON.
  ///
  /// The catalogue is data, not code, so the set of packs on offer can change
  /// without an app update.
  static List<RegionPack> parseCatalogue(String json) {
    final decoded = jsonDecode(json);
    final list = decoded is Map<String, Object?>
        ? (decoded['packs'] as List<Object?>? ?? const [])
        : (decoded as List<Object?>);
    return list
        .whereType<Map<String, Object?>>()
        .map(RegionPack.fromJson)
        .toList();
  }

  /// Merges catalogue entries with what is actually on disk.
  List<RegionPack> withInstallState(List<RegionPack> catalogue) {
    return catalogue.map((pack) {
      if (!isInstalled(pack.id)) return pack;
      return pack.copyWith(
        installedBytes: bytesFor(pack.id),
        installedAt: installedAt(pack.id),
      );
    }).toList();
  }
}
