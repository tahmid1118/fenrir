import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fenrir/src/data/models.dart';
import 'package:fenrir/src/data/waypoint_store.dart';

void main() {
  late Directory temp;
  late WaypointStore store;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fenrir_waypoint_test');
    store = await WaypointStore.open(
      path: p.join(temp.path, 'fenrir.db'),
      factory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    await store.close();
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Waypoint sample({
    String? label,
    String? note,
    String? placeName = 'Dhanmondi, Dhaka, Dhaka Division, BD',
    double accuracy = 6.0,
    DateTime? savedAt,
  }) {
    return Waypoint(
      label: label,
      note: note,
      latitude: 23.7461,
      longitude: 90.3742,
      accuracyMeters: accuracy,
      altitudeMeters: 27.4,
      placeName: placeName,
      savedAt: savedAt ?? DateTime.utc(2026, 8, 15, 3, 30),
    );
  }

  group('FR-6.1 saving a position', () {
    test('round-trips every field the requirement names', () async {
      final saved = await store.add(sample(note: 'Left the car here'));

      expect(saved.id, isNotNull);
      final loaded = await store.byId(saved.id!);

      expect(loaded, isNotNull);
      expect(loaded!.latitude, 23.7461);
      expect(loaded.longitude, 90.3742);
      expect(loaded.accuracyMeters, 6.0);
      expect(loaded.altitudeMeters, 27.4);
      expect(loaded.placeName, 'Dhanmondi, Dhaka, Dhaka Division, BD');
      expect(loaded.note, 'Left the car here');
      expect(loaded.savedAt, DateTime.utc(2026, 8, 15, 3, 30));
    });

    test('keeps full coordinate precision', () async {
      // The bundled place database quantises to about a metre so a B-tree can
      // serve proximity queries. A saved position is the user's own record and
      // there is no reason to round it.
      const lat = 23.74612345;
      const lon = 90.37421987;
      final saved = await store.add(Waypoint(
        latitude: lat,
        longitude: lon,
        accuracyMeters: 4,
        savedAt: DateTime.utc(2026, 8, 15),
      ));

      final loaded = await store.byId(saved.id!);
      expect(loaded!.latitude, lat);
      expect(loaded.longitude, lon);
    });

    test('records the accuracy the fix actually had', () async {
      // A waypoint taken with a 200 metre fix is a different thing from one
      // taken with a 4 metre fix, and FR-1.2's honesty applies afterwards too.
      final coarse = await store.add(sample(accuracy: 213.5));
      expect((await store.byId(coarse.id!))!.accuracyMeters, 213.5);
    });

    test('an optional note and label really are optional', () async {
      final saved = await store.add(sample());
      final loaded = await store.byId(saved.id!);
      expect(loaded!.label, isNull);
      expect(loaded.note, isNull);
    });

    test('blank text is stored as absent, not as an empty string', () async {
      final saved = await store.add(sample(label: '   ', note: ''));
      final loaded = await store.byId(saved.id!);
      expect(loaded!.label, isNull);
      expect(loaded.note, isNull);
    });

    test('times are kept in UTC so they survive a time zone change', () async {
      // A travelling app crosses time zones as a matter of course, and a local
      // time string would silently change meaning when it did.
      final local = DateTime.parse('2026-08-15T09:30:00+06:00');
      final saved = await store.add(sample(savedAt: local));
      final loaded = await store.byId(saved.id!);

      expect(loaded!.savedAt.isUtc, isTrue);
      expect(loaded.savedAt.isAtSameMomentAs(local), isTrue);
    });
  });

  group('listing', () {
    test('is empty to begin with', () async {
      expect(await store.all(), isEmpty);
      expect(await store.count(), 0);
    });

    test('returns newest first', () async {
      await store.add(sample(label: 'oldest', savedAt: DateTime.utc(2026, 1, 1)));
      await store.add(sample(label: 'newest', savedAt: DateTime.utc(2026, 8, 1)));
      await store.add(sample(label: 'middle', savedAt: DateTime.utc(2026, 5, 1)));

      final all = await store.all();
      expect(all.map((w) => w.label), ['newest', 'middle', 'oldest']);
      expect(await store.count(), 3);
    });

    test('breaks ties on identical timestamps deterministically', () async {
      // Two waypoints saved in the same millisecond must still have a stable
      // order, or the list reshuffles itself between rebuilds.
      final at = DateTime.utc(2026, 8, 15, 3, 30);
      await store.add(sample(label: 'first', savedAt: at));
      await store.add(sample(label: 'second', savedAt: at));

      expect((await store.all()).map((w) => w.label), ['second', 'first']);
      expect((await store.all()).map((w) => w.label), ['second', 'first']);
    });
  });

  group('editing and removing', () {
    test('a label and note can be changed', () async {
      final saved = await store.add(sample());
      await store.rename(saved.id!, label: 'Camp', note: 'By the big rock');

      final loaded = await store.byId(saved.id!);
      expect(loaded!.label, 'Camp');
      expect(loaded.note, 'By the big rock');
      // The position is not editable: a waypoint records where the user was.
      expect(loaded.latitude, 23.7461);
    });

    test('clearing a label restores the fallback name', () async {
      final saved = await store.add(sample(label: 'Camp'));
      await store.rename(saved.id!, label: '');

      final loaded = await store.byId(saved.id!);
      expect(loaded!.label, isNull);
      expect(loaded.displayLabel, 'Dhanmondi, Dhaka, Dhaka Division, BD');
    });

    test('removal reports whether anything was removed', () async {
      final saved = await store.add(sample());
      expect(await store.remove(saved.id!), isTrue);
      expect(await store.byId(saved.id!), isNull);
      expect(await store.count(), 0);

      // Removing it twice is not an error, but it is not a success either.
      expect(await store.remove(saved.id!), isFalse);
    });

    test('removing one leaves the others alone', () async {
      final a = await store.add(sample(label: 'a'));
      await store.add(sample(label: 'b'));
      await store.remove(a.id!);

      expect((await store.all()).map((w) => w.label), ['b']);
    });
  });

  group('display name', () {
    test('prefers the user label', () {
      expect(sample(label: 'Camp').displayLabel, 'Camp');
    });

    test('falls back to the place name captured at save time', () {
      // Stored rather than re-resolved: it is what the user saw when they
      // decided the spot was worth keeping, and a database rebuild must not
      // silently rename their waypoint.
      expect(
        sample().displayLabel,
        'Dhanmondi, Dhaka, Dhaka Division, BD',
      );
    });

    test('falls back to coordinates when there was no place nearby', () {
      // FR-3.3's open-water case, saved.
      expect(sample(placeName: null).displayLabel, '23.74610, 90.37420');
    });

    test('ignores a whitespace-only label', () {
      expect(sample(label: '   ').displayLabel,
          'Dhanmondi, Dhaka, Dhaka Division, BD');
    });
  });

  group('persistence', () {
    test('saved positions survive reopening the database', () async {
      final path = p.join(temp.path, 'reopen.db');
      final first = await WaypointStore.open(
        path: path,
        factory: databaseFactoryFfi,
      );
      await first.add(sample(label: 'Camp'));
      await first.close();

      final second = await WaypointStore.open(
        path: path,
        factory: databaseFactoryFfi,
      );
      addTearDown(second.close);

      final all = await second.all();
      expect(all, hasLength(1));
      expect(all.single.label, 'Camp');
    });

    test('the schema version is stamped, so migrations have a starting point',
        () async {
      final path = p.join(temp.path, 'versioned.db');
      final opened = await WaypointStore.open(
        path: path,
        factory: databaseFactoryFfi,
      );
      await opened.close();

      final raw = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      addTearDown(raw.close);

      final version = await raw.rawQuery('PRAGMA user_version');
      expect(
        version.first.values.first,
        WaypointStore.schemaVersion,
      );
    });

    test('is a separate file from the bundled databases', () async {
      // FR-5.3 requires that deleting a downloaded pack never affects saved
      // user data. Never sharing a file is the cleanest way to guarantee it.
      expect(WaypointStore.fileName, isNot('places.db'));
      expect(WaypointStore.fileName, isNot('basemap.mbtiles'));
      expect(File(p.join(temp.path, 'fenrir.db')).existsSync(), isTrue);
    });
  });
}
