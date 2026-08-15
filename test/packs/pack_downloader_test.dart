import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/src/packs/pack_downloader.dart';
import 'package:fenrir/src/packs/pack_store.dart';
import 'package:fenrir/src/packs/region_pack.dart';

/// A real server, so range requests are exercised rather than imagined.
class TestServer {
  TestServer(this._server, this.payload);

  final HttpServer _server;
  final Uint8List payload;

  /// Set to refuse range requests, as some CDNs do.
  bool honourRanges = true;

  /// Set to cut the connection partway through the body.
  int? truncateAfter;

  int requestCount = 0;
  final List<String?> rangeHeaders = [];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/pack.mbtiles');

  static Future<TestServer> start(Uint8List payload) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final test = TestServer(server, payload);
    unawaited(test._serve());
    return test;
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      requestCount++;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      rangeHeaders.add(range);

      var from = 0;
      if (range != null && honourRanges) {
        from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $from-${payload.length - 1}/${payload.length}',
        );
      } else {
        request.response.statusCode = HttpStatus.ok;
      }

      var body = payload.sublist(from);
      final cut = truncateAfter;
      if (cut != null && body.length > cut) {
        body = body.sublist(0, cut);
      }

      request.response.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
    }
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late Directory temp;
  late PackStore store;
  late TestServer server;
  late Uint8List payload;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fenrir_pack_test');
    store = PackStore(Directory('${temp.path}/packs'));
    await store.directory.create(recursive: true);
    payload = Uint8List.fromList(
      List.generate(64 * 1024, (i) => (i * 31) % 256),
    );
    server = await TestServer.start(payload);
  });

  tearDown(() async {
    await server.stop();
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  RegionPack packFor({String? digest}) => RegionPack(
        id: 'bangladesh',
        name: 'Bangladesh',
        country: 'BD',
        downloadBytes: payload.length,
        url: server.url,
        maxZoom: 14,
        sha256: digest,
      );

  group('FR-5.1 downloading', () {
    test('downloads a pack and installs it', () async {
      final downloader = PackDownloader(store: store);
      addTearDown(downloader.dispose);

      final states = <PackState>[];
      downloader.progress.listen((p) => states.add(p.state));

      await downloader.start(packFor());
      await pumpEventQueue();

      expect(store.isInstalled('bangladesh'), isTrue);
      expect(store.bytesFor('bangladesh'), payload.length);
      expect(states.last, PackState.installed);
      // The partial file is gone; it was renamed, not copied.
      expect(store.partialFor('bangladesh').existsSync(), isFalse);
    });

    test('reports progress as bytes arrive', () async {
      final downloader = PackDownloader(store: store);
      addTearDown(downloader.dispose);

      final fractions = <double>[];
      downloader.progress.listen((p) {
        if (p.state == PackState.downloading) fractions.add(p.fraction);
      });

      await downloader.start(packFor());
      await pumpEventQueue();

      expect(fractions, isNotEmpty);
      expect(fractions.last, closeTo(1.0, 0.001));
      // Monotonic: a progress bar that goes backwards is worse than none.
      for (var i = 1; i < fractions.length; i++) {
        expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
      }
    });

    test('resumes from a partial download with a range request', () async {
      // The reason this matters: packs run to hundreds of megabytes, and
      // restarting from zero after a dropped connection would be unusable on
      // the networks this app's users are likely to have.
      final partial = store.partialFor('bangladesh');
      await partial.writeAsBytes(payload.sublist(0, 20000), flush: true);

      final downloader = PackDownloader(store: store);
      addTearDown(downloader.dispose);

      await downloader.start(packFor());
      await pumpEventQueue();

      expect(server.rangeHeaders.last, 'bytes=20000-');
      expect(store.bytesFor('bangladesh'), payload.length);
      // And the result is the original file, not a spliced-together mess.
      expect(await store.fileFor('bangladesh').readAsBytes(), payload);
    });

    test('starts over when the server ignores the range request', () async {
      // Some CDNs answer 200 with the whole body. Appending that onto what was
      // already downloaded would produce a file larger than the original and
      // corrupt from the join onward.
      await store
          .partialFor('bangladesh')
          .writeAsBytes(payload.sublist(0, 20000), flush: true);
      server.honourRanges = false;

      final downloader = PackDownloader(store: store);
      addTearDown(downloader.dispose);

      await downloader.start(packFor());
      await pumpEventQueue();

      expect(store.bytesFor('bangladesh'), payload.length);
      expect(await store.fileFor('bangladesh').readAsBytes(), payload);
    });

    test('a server error is reported, not swallowed', () async {
      final downloader = PackDownloader(store: store);
      addTearDown(downloader.dispose);

      final failures = <PackProgress>[];
      downloader.progress
          .where((p) => p.state == PackState.failed)
          .listen(failures.add);

      await downloader.start(RegionPack(
        id: 'missing',
        name: 'Missing',
        country: 'XX',
        downloadBytes: 100,
        url: Uri.parse('http://127.0.0.1:1/nope'),
        maxZoom: 14,
      ));
      await pumpEventQueue();

      expect(failures, isNotEmpty);
      expect(failures.last.error, isNotNull);
      expect(store.isInstalled('missing'), isFalse);
    });
  });

  group('FR-5.1 pause and cancel', () {
    test('cancel discards the partial download', () async {
      await store
          .partialFor('bangladesh')
          .writeAsBytes(payload.sublist(0, 5000), flush: true);

      final downloader = PackDownloader(store: store);
      addTearDown(downloader.dispose);

      await downloader.cancel('bangladesh');

      expect(store.partialFor('bangladesh').existsSync(), isFalse);
      expect(store.isInstalled('bangladesh'), isFalse);
    });

    test('pause keeps what has arrived so it can be resumed', () async {
      // Pause has to differ from cancel in exactly this way, or a user who
      // pauses on a metered connection loses everything they have paid for.
      await store
          .partialFor('bangladesh')
          .writeAsBytes(payload.sublist(0, 5000), flush: true);

      expect(store.partialBytes('bangladesh'), 5000);

      final downloader = PackDownloader(store: store);
      addTearDown(downloader.dispose);

      await downloader.start(packFor());
      await pumpEventQueue();

      expect(store.bytesFor('bangladesh'), payload.length);
    });

    test('cancelling something that is not running is harmless', () async {
      final downloader = PackDownloader(store: store);
      addTearDown(downloader.dispose);
      await expectLater(downloader.cancel('nothing'), completes);
    });
  });

  group('integrity', () {
    test('a correct checksum installs the pack', () async {
      final digest = sha256.convert(payload).toString();
      final downloader = PackDownloader(store: store);
      addTearDown(downloader.dispose);

      await downloader.start(packFor(digest: digest));
      await pumpEventQueue();

      expect(store.isInstalled('bangladesh'), isTrue);
    });

    test('a wrong checksum refuses to install and cleans up', () async {
      // A truncated pack opens as a perfectly valid archive that simply
      // returns no tiles, which looks like a blank map rather than a failed
      // download.
      final downloader = PackDownloader(store: store);
      addTearDown(downloader.dispose);

      final failures = <PackProgress>[];
      downloader.progress
          .where((p) => p.state == PackState.failed)
          .listen(failures.add);

      await downloader.start(packFor(digest: 'a' * 64));
      await pumpEventQueue();

      expect(store.isInstalled('bangladesh'), isFalse);
      expect(store.partialFor('bangladesh').existsSync(), isFalse);
      expect(failures, isNotEmpty);
      expect(failures.last.error, contains('checksum'));
    });
  });
}
