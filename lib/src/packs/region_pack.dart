import 'package:meta/meta.dart';

/// A downloadable regional map pack (Tier 2).
///
/// Nothing here records an expiry, a lease, a licence check or a last-validated
/// timestamp, and that is deliberate. FR-5.2 requires that downloaded data
/// never expires and is never capped, in direct response to Maps.me's regions
/// going stale after a failed refresh. The cleanest way to guarantee a thing
/// cannot happen is to give the code no way to express it.
@immutable
class RegionPack {
  const RegionPack({
    required this.id,
    required this.name,
    required this.country,
    required this.downloadBytes,
    required this.url,
    required this.maxZoom,
    this.sha256,
    this.installedBytes,
    this.installedAt,
  });

  /// Stable identifier, also the file name on disk.
  final String id;

  /// What the user sees, e.g. `Bangladesh`.
  final String name;

  /// ISO 3166-1 alpha-2.
  final String country;

  /// Compressed download size.
  ///
  /// FR-5.1 requires the size be stated before the user commits, so it is part
  /// of the catalogue rather than something discovered once a download starts.
  final int downloadBytes;

  final Uri url;

  /// The detail this pack adds, against the bundled ceiling of zoom 5.
  final int maxZoom;

  /// Expected digest, for verifying a completed download.
  final String? sha256;

  /// Size on disk once installed. Null when it is not.
  final int? installedBytes;

  /// When it finished downloading.
  ///
  /// Recorded for the storage screen only. Nothing reads it to decide whether
  /// the pack is still usable, because the answer is always yes.
  final DateTime? installedAt;

  bool get isInstalled => installedAt != null;

  /// A human size, for a screen where the number is the whole point.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} kB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String get downloadSizeLabel => formatBytes(downloadBytes);

  RegionPack copyWith({
    int? installedBytes,
    DateTime? installedAt,
    bool clearInstalled = false,
  }) {
    return RegionPack(
      id: id,
      name: name,
      country: country,
      downloadBytes: downloadBytes,
      url: url,
      maxZoom: maxZoom,
      sha256: sha256,
      installedBytes: clearInstalled ? null : (installedBytes ?? this.installedBytes),
      installedAt: clearInstalled ? null : (installedAt ?? this.installedAt),
    );
  }

  factory RegionPack.fromJson(Map<String, Object?> json) {
    return RegionPack(
      id: json['id']! as String,
      name: json['name']! as String,
      country: (json['country'] as String?) ?? '',
      downloadBytes: (json['bytes'] as num?)?.toInt() ?? 0,
      url: Uri.parse(json['url']! as String),
      maxZoom: (json['maxZoom'] as num?)?.toInt() ?? 14,
      sha256: json['sha256'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is RegionPack && id == other.id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'RegionPack($id, $downloadSizeLabel)';
}

/// Where a pack is in its lifecycle (FR-5.1).
enum PackState {
  available,
  queued,
  downloading,
  paused,
  installed,
  failed;

  bool get isActive => this == downloading || this == queued;
}

/// Progress of one download.
@immutable
class PackProgress {
  const PackProgress({
    required this.packId,
    required this.state,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
  });

  final String packId;
  final PackState state;
  final int receivedBytes;
  final int totalBytes;
  final String? error;

  double get fraction =>
      totalBytes <= 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  @override
  String toString() =>
      'PackProgress($packId, ${state.name}, '
      '${(fraction * 100).toStringAsFixed(0)}%)';
}
