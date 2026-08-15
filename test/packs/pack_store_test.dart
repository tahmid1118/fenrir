import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fenrir/src/packs/pack_store.dart';
import 'package:fenrir/src/packs/region_pack.dart';

void main() {
  late Directory temp;
  late PackStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fenrir_pack_store');
    store = PackStore(Directory('${temp.path}/packs'));
    await store.directory.create(recursive: true);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<void> install(String id, int bytes) async {
    await store.fileFor(id).writeAsBytes(List.filled(bytes, 0), flush: true);
  }

  group('FR-5.3 storage accounting', () {
    test('reports nothing when no pack is installed', () {
      expect(store.installedIds(), isEmpty);
      expect(store.totalBytes(), 0);
    });

    test('reports per-pack and total usage', () async {
      await install('bangladesh', 5000);
      await install('sri-lanka', 3000);

      expect(store.bytesFor('bangladesh'), 5000);
      expect(store.bytesFor('sri-lanka'), 3000);
      expect(store.totalBytes(), 8000);
      expect(store.installedIds(), ['bangladesh', 'sri-lanka']);
    });

    test('counts partial downloads, which also occupy the disk', () async {
      // A storage screen that ignored them would understate usage by however
      // much the user had downloaded before pausing.
      await install('bangladesh', 5000);
      await store.partialFor('nepal').writeAsBytes(List.filled(2000, 0));

      expect(store.totalBytes(), 7000);
      expect(store.partialBytes('nepal'), 2000);
      // But a partial download is not an installed pack.
      expect(store.isInstalled('nepal'), isFalse);
      expect(store.installedIds(), ['bangladesh']);
    });

    test('lists packs from disk, not from a catalogue', () async {
      // A pack whose catalogue entry has disappeared must still be visible and
      // deletable, rather than becoming storage the user cannot reclaim.
      await install('withdrawn-region', 4000);
      expect(store.installedIds(), contains('withdrawn-region'));
      expect(store.bytesFor('withdrawn-region'), 4000);
    });
  });

  group('FR-5.3 deletion', () {
    test('removes a pack and reports it', () async {
      await install('bangladesh', 5000);
      expect(await store.remove('bangladesh'), isTrue);
      expect(store.isInstalled('bangladesh'), isFalse);
      expect(store.totalBytes(), 0);
    });

    test('removing something absent is not an error but is not a success', () async {
      expect(await store.remove('nothing'), isFalse);
    });

    test('removes the partial download too', () async {
      await store.partialFor('nepal').writeAsBytes(List.filled(2000, 0));
      expect(await store.remove('nepal'), isTrue);
      expect(store.partialFor('nepal').existsSync(), isFalse);
    });

    test('touches only the pack asked for', () async {
      // FR-5.3 requires that deleting a pack never affect anything else.
      await install('bangladesh', 5000);
      await install('sri-lanka', 3000);

      await store.remove('bangladesh');

      expect(store.isInstalled('sri-lanka'), isTrue);
      expect(store.bytesFor('sri-lanka'), 3000);
    });

    test('cannot reach outside its own directory', () async {
      // Saved waypoints and the bundled databases live elsewhere on purpose,
      // and the store has no way to address them.
      final outside = File('${temp.path}/places.db');
      await outside.writeAsString('bundled data');

      await store.remove('../places');

      expect(outside.existsSync(), isTrue);
    });
  });

  group('FR-5.2 nothing expires', () {
    test('an installed pack has no expiry to check', () async {
      await install('bangladesh', 5000);

      // A pack installed long ago is exactly as installed as one from today.
      // This is a direct response to Maps.me's regions going stale after a
      // failed refresh, and the store simply has no mechanism for it.
      final packs = store.withInstallState([
        RegionPack(
          id: 'bangladesh',
          name: 'Bangladesh',
          country: 'BD',
          downloadBytes: 5000,
          url: Uri.parse('https://example.invalid/bd.mbtiles'),
          maxZoom: 14,
        ),
      ]);

      expect(packs.single.isInstalled, isTrue);
      expect(packs.single.installedBytes, 5000);
      expect(packs.single.installedAt, isNotNull);
    });

    test('there is no limit on how many packs may be kept', () async {
      for (var i = 0; i < 25; i++) {
        await install('region-$i', 1000);
      }
      expect(store.installedIds(), hasLength(25));
      expect(store.totalBytes(), 25000);
    });
  });

  group('the catalogue', () {
    const json = '''
    {"packs": [
      {"id":"bangladesh","name":"Bangladesh","country":"BD",
       "bytes":335200000,"url":"https://example.invalid/bd.mbtiles",
       "maxZoom":14,"sha256":"abc"},
      {"id":"sri-lanka","name":"Sri Lanka","country":"LK",
       "bytes":137100000,"url":"https://example.invalid/lk.mbtiles",
       "maxZoom":14}
    ]}
    ''';

    test('parses entries', () {
      final packs = PackStore.parseCatalogue(json);
      expect(packs, hasLength(2));
      expect(packs.first.id, 'bangladesh');
      expect(packs.first.downloadBytes, 335200000);
      expect(packs.first.sha256, 'abc');
      expect(packs.last.sha256, isNull);
    });

    test('accepts a bare list as well as an object', () {
      final packs = PackStore.parseCatalogue(
        '[{"id":"x","name":"X","url":"https://example.invalid/x.mbtiles"}]',
      );
      expect(packs.single.id, 'x');
      // A missing zoom defaults to the Tier 2 target rather than to nothing.
      expect(packs.single.maxZoom, 14);
    });

    test('marks which entries are installed', () async {
      await install('bangladesh', 5000);
      final merged = store.withInstallState(PackStore.parseCatalogue(json));

      expect(merged.firstWhere((p) => p.id == 'bangladesh').isInstalled, isTrue);
      expect(merged.firstWhere((p) => p.id == 'sri-lanka').isInstalled, isFalse);
    });
  });

  group('sizes are stated before the user commits', () {
    test('are formatted for a screen where the number is the point', () {
      // FR-5.1: sizes are stated before the user commits, and "335.2 MB" is
      // actionable in a way that "335200000" is not.
      expect(RegionPack.formatBytes(512), '512 B');
      expect(RegionPack.formatBytes(2048), '2 kB');
      expect(RegionPack.formatBytes(335200000), '319.7 MB');
      expect(RegionPack.formatBytes(1620000000), '1.51 GB');
    });
  });
}
