import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fenrir/src/data/bundled_asset.dart';

void main() {
  late Directory temp;
  var loadCount = 0;

  /// Stands in for the real 25.8 MB database.
  Uint8List payload = Uint8List.fromList(List.generate(2048, (i) => i % 256));

  const asset = BundledAsset(
    assetPath: 'assets/db/places.db',
    fileName: 'places.db',
    version: 1,
  );

  BundledAssetStore store() => BundledAssetStore(
        loadAsset: (_) async {
          loadCount++;
          return ByteData.view(payload.buffer);
        },
        resolveDirectory: () async => temp,
      );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fenrir_asset_test');
    loadCount = 0;
    payload = Uint8List.fromList(List.generate(2048, (i) => i % 256));
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  File markerFor(BundledAsset a) =>
      File(p.join(temp.path, '${a.fileName}.version'));

  test('first run extracts the asset and records a marker', () async {
    final file = await store().ensure(asset);

    expect(file.existsSync(), isTrue);
    expect(await file.readAsBytes(), payload);
    expect(loadCount, 1);
    expect(markerFor(asset).readAsStringSync(), '1:2048');
  });

  test('a second run reuses the extracted copy without reloading', () async {
    await store().ensure(asset);
    expect(loadCount, 1);

    // This is the path taken on every launch after the first. Re-extracting
    // 25.8 MB each time would blow the 2 second cold start NFR-4 allows.
    final again = await store().ensure(asset);
    expect(loadCount, 1);
    expect(again.existsSync(), isTrue);
  });

  test('a version bump forces re-extraction', () async {
    await store().ensure(asset);
    expect(loadCount, 1);

    payload = Uint8List.fromList(List.filled(4096, 7));
    const bumped = BundledAsset(
      assetPath: 'assets/db/places.db',
      fileName: 'places.db',
      version: 2,
    );

    final file = await store().ensure(bumped);
    expect(loadCount, 2);
    expect(await file.length(), 4096);
    expect(markerFor(bumped).readAsStringSync(), '2:4096');
  });

  test('a truncated copy is detected and re-extracted', () async {
    final file = await store().ensure(asset);
    expect(loadCount, 1);

    // Simulate an extraction interrupted by the process dying or the device
    // filling up: the file exists, and the marker says it is current, but the
    // bytes are incomplete. Trusting the marker alone would hand SQLite a
    // corrupt database.
    await file.writeAsBytes(payload.sublist(0, 100), flush: true);

    final repaired = await store().ensure(asset);
    expect(loadCount, 2);
    expect(await repaired.length(), 2048);
  });

  test('a missing marker forces re-extraction even if the file is intact',
      () async {
    await store().ensure(asset);
    await markerFor(asset).delete();

    await store().ensure(asset);
    expect(loadCount, 2);
  });

  test('a corrupt marker is treated as absent', () async {
    await store().ensure(asset);

    for (final garbage in ['', 'nonsense', '1', '1:', ':2048', 'x:y']) {
      await markerFor(asset).writeAsString(garbage, flush: true);
      final before = loadCount;
      await store().ensure(asset);
      expect(loadCount, before + 1, reason: 'marker "$garbage"');
    }
  });

  test('no temporary file survives a successful extraction', () async {
    await store().ensure(asset);
    final leftovers = temp
        .listSync()
        .map((e) => p.basename(e.path))
        .where((n) => n.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('a stale temporary file from a failed run does not block extraction',
      () async {
    await File(p.join(temp.path, 'places.db.tmp'))
        .writeAsString('interrupted', flush: true);

    final file = await store().ensure(asset);
    expect(await file.readAsBytes(), payload);
  });

  test('a failure to read the asset surfaces as a typed exception', () async {
    final broken = BundledAssetStore(
      loadAsset: (_) async => throw StateError('asset missing'),
      resolveDirectory: () async => temp,
    );

    // NFR-6 requires a defined state rather than an unexplained blank, and the
    // UI cannot render one from an arbitrary error type.
    await expectLater(
      broken.ensure(asset),
      throwsA(isA<BundledAssetException>()),
    );
  });

  test('a failure to resolve the directory surfaces as a typed exception',
      () async {
    final broken = BundledAssetStore(
      loadAsset: (_) async => ByteData.view(payload.buffer),
      resolveDirectory: () async => throw StateError('no such directory'),
    );

    await expectLater(
      broken.ensure(asset),
      throwsA(isA<BundledAssetException>()),
    );
  });

  test('the declared places asset matches the pubspec entry', () {
    // Guards against the asset path drifting out of sync with pubspec.yaml,
    // which would only show up as a crash on a real device.
    expect(BundledAssetStore.places.assetPath, 'assets/db/places.db');
    expect(File('assets/db/places.db').existsSync(), isTrue);

    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('assets/db/places.db'));
  });
}
