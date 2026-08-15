import 'dart:async';
import 'package:convert/convert.dart';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'pack_store.dart';
import 'region_pack.dart';

/// Downloads regional packs, resumably (FR-5.1).
///
/// Packs run to hundreds of megabytes, so a download that had to restart from
/// zero after a dropped connection would be unusable on the sort of network
/// this app's users are likely to have. Progress is appended to a partial file
/// on disk and continued with an HTTP range request, which means a download
/// survives pausing, losing signal, and closing the app.
///
/// This is the one part of the product that needs a network, and it is entirely
/// optional: FR-5.2 guarantees that whatever has already been downloaded keeps
/// working forever without one.
class PackDownloader {
  PackDownloader({
    required this.store,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final PackStore store;
  final HttpClient Function() _clientFactory;

  final _progress = StreamController<PackProgress>.broadcast();
  final Map<String, _Download> _active = {};

  /// Progress for every pack being downloaded.
  Stream<PackProgress> get progress => _progress.stream;

  bool isDownloading(String packId) => _active.containsKey(packId);

  /// Starts or resumes a download.
  ///
  /// Safe to call for a pack already in flight; the existing download
  /// continues rather than a second one starting alongside it.
  Future<void> start(RegionPack pack) async {
    if (_active.containsKey(pack.id)) return;

    final download = _Download(pack);
    _active[pack.id] = download;

    try {
      await _run(download);
    } on Object catch (e) {
      if (!download.cancelled && !download.paused) {
        _emit(PackProgress(
          packId: pack.id,
          state: PackState.failed,
          receivedBytes: store.partialBytes(pack.id),
          totalBytes: pack.downloadBytes,
          error: '$e',
        ));
      }
    } finally {
      _active.remove(pack.id);
    }
  }

  /// Stops a download, keeping what has arrived so far.
  void pause(String packId) {
    final download = _active[packId];
    if (download == null) return;
    download.paused = true;
    download.subscription?.cancel();
    _emit(PackProgress(
      packId: packId,
      state: PackState.paused,
      receivedBytes: store.partialBytes(packId),
      totalBytes: download.pack.downloadBytes,
    ));
  }

  /// Stops a download and discards what has arrived.
  Future<void> cancel(String packId) async {
    final download = _active[packId];
    download?.cancelled = true;
    await download?.subscription?.cancel();
    _active.remove(packId);

    final partial = store.partialFor(packId);
    if (await partial.exists()) await partial.delete();

    _emit(PackProgress(packId: packId, state: PackState.available));
  }

  Future<void> _run(_Download download) async {
    final pack = download.pack;
    final partial = store.partialFor(pack.id);
    await partial.parent.create(recursive: true);

    var alreadyHave = await partial.exists() ? await partial.length() : 0;

    _emit(PackProgress(
      packId: pack.id,
      state: PackState.downloading,
      receivedBytes: alreadyHave,
      totalBytes: pack.downloadBytes,
    ));

    final client = _clientFactory();
    try {
      final request = await client.getUrl(pack.url);
      if (alreadyHave > 0) {
        // Ask only for what is missing. A server that ignores this answers 200
        // with the whole file, which is handled below by starting over rather
        // than appending a second copy onto the first.
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$alreadyHave-');
      }

      final response = await request.close();

      if (response.statusCode == HttpStatus.ok && alreadyHave > 0) {
        // Range was not honoured. Truncate and take the full body.
        alreadyHave = 0;
        if (await partial.exists()) await partial.delete();
      } else if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw HttpException(
          'Server returned ${response.statusCode}',
          uri: pack.url,
        );
      }

      final total = alreadyHave +
          (response.contentLength > 0
              ? response.contentLength
              : pack.downloadBytes - alreadyHave);

      final sink = partial.openWrite(mode: FileMode.append);
      var received = alreadyHave;
      final completer = Completer<void>();

      download.subscription = response.listen(
        (chunk) {
          sink.add(chunk);
          received += chunk.length;
          _emit(PackProgress(
            packId: pack.id,
            state: PackState.downloading,
            receivedBytes: received,
            totalBytes: total,
          ));
        },
        onDone: () => completer.complete(),
        onError: completer.completeError,
        cancelOnError: true,
      );

      try {
        await completer.future;
      } finally {
        await sink.flush();
        await sink.close();
      }

      if (download.cancelled || download.paused) return;

      await _finish(pack);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _finish(RegionPack pack) async {
    final expected = pack.sha256;
    if (expected != null && expected.isNotEmpty) {
      // A truncated or corrupted pack would otherwise be opened as a valid
      // archive and simply return no tiles, which looks like a blank map
      // rather than a failed download.
      final actual = await _digest(store.partialFor(pack.id));
      if (actual != expected.toLowerCase()) {
        await store.partialFor(pack.id).delete();
        throw StateError('Downloaded pack failed its checksum');
      }
    }

    await store.install(pack.id);

    _emit(PackProgress(
      packId: pack.id,
      state: PackState.installed,
      receivedBytes: store.bytesFor(pack.id),
      totalBytes: store.bytesFor(pack.id),
    ));
  }

  Future<String> _digest(File file) async {
    // Streamed rather than read whole: a pack can be larger than the memory
    // the app is allowed to hold.
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return output.events.single.toString();
  }

  void _emit(PackProgress progress) {
    if (!_progress.isClosed) _progress.add(progress);
  }

  Future<void> dispose() async {
    for (final download in _active.values) {
      download.cancelled = true;
      await download.subscription?.cancel();
    }
    _active.clear();
    await _progress.close();
  }
}

class _Download {
  _Download(this.pack);

  final RegionPack pack;
  StreamSubscription<List<int>>? subscription;
  bool paused = false;
  bool cancelled = false;
}
