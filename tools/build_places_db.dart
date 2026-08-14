import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'src/geonames.dart';

/// Rebuilds the Tier 1 place database from GeoNames.
///
///     dart run tools/build_places_db.dart [--out path] [--min-population 0]
///
/// The shipped `assets/db/places.db` was produced outside this repository and
/// arrived as an opaque binary. This script exists so it can be reproduced,
/// audited and — for FR-3.4 later — extended with OpenStreetMap-derived places
/// for countries GeoNames covers badly.
///
/// Source data is expected at `tools/data/cities500.txt`, the extracted
/// GeoNames export. See tools/README.md.
///
/// GeoNames is CC BY 4.0: attribution is required and recorded in NOTICE.md.

const String _dataDir = 'tools/data';
const String _defaultSource = '$_dataDir/cities500.txt';
const String _defaultOut = 'assets/db/places.db';

Future<void> main(List<String> args) async {
  final sourcePath = _stringArg(args, '--source') ?? _defaultSource;
  final outPath = _stringArg(args, '--out') ?? _defaultOut;
  final minPopulation = _intArg(args, '--min-population') ?? 0;

  final source = File(sourcePath);
  if (!source.existsSync()) {
    stderr
      ..writeln('Missing $sourcePath')
      ..writeln('Download https://download.geonames.org/export/dump/'
          'cities500.zip and extract cities500.txt into $_dataDir/.')
      ..writeln('See tools/README.md.');
    exitCode = 1;
    return;
  }

  stdout.writeln('Reading $sourcePath');
  final admin1 = await AdminNames.readAdmin1('$_dataDir/admin1CodesASCII.txt');
  final admin2 = await AdminNames.readAdmin2('$_dataDir/admin2Codes.txt');
  stdout.writeln('  ${admin1.length} first-level and ${admin2.length} '
      'second-level division names');

  final stopwatch = Stopwatch()..start();

  final out = File(outPath);
  await out.parent.create(recursive: true);
  if (out.existsSync()) await out.delete();

  sqfliteFfiInit();
  // Absolute: a relative path resolves against the package's own .dart_tool
  // databases directory rather than the working directory.
  final db = await databaseFactoryFfi.openDatabase(
    out.absolute.path,
    options: OpenDatabaseOptions(singleInstance: false),
  );

  // Schema is fixed by what the app queries. lat_e5/lon_e5 hold degrees times
  // 1e5 as integers so that proximity can be served by a plain B-tree: the
  // bundled SQLite has no R*Tree, and Android's build has no maths functions,
  // so the distance itself is computed in Dart.
  await db.execute('''
    CREATE TABLE place (
      id        INTEGER PRIMARY KEY,
      name      TEXT NOT NULL,
      admin1    TEXT,
      admin2    TEXT,
      country   TEXT NOT NULL,
      lat_e5    INTEGER NOT NULL,
      lon_e5    INTEGER NOT NULL,
      pop       INTEGER,
      tz        TEXT
    )
  ''');

  var inserted = 0;
  var skipped = 0;
  var batch = db.batch();
  var pending = 0;

  // No explicit BEGIN: sqflite's batch runs inside its own transaction, and
  // opening one by hand around it fails with "cannot start a transaction
  // within a transaction".
  await for (final row in readGeoNames(source)) {
    if (row.population < minPopulation) {
      skipped++;
      continue;
    }
    batch.insert('place', {
      'id': row.id,
      'name': row.name,
      'admin1': admin1['${row.country}.${row.admin1Code}'],
      'admin2':
          admin2['${row.country}.${row.admin1Code}.${row.admin2Code}'],
      'country': row.country,
      'lat_e5': (row.latitude * 100000).round(),
      'lon_e5': (row.longitude * 100000).round(),
      'pop': row.population,
      'tz': row.timeZone,
    });
    inserted++;
    if (++pending >= 5000) {
      await batch.commit(noResult: true);
      batch = db.batch();
      pending = 0;
    }
  }
  if (pending > 0) await batch.commit(noResult: true);

  stdout.writeln('  $inserted places inserted, $skipped below the population '
      'floor');

  // Indexes after the load: building them alongside the insert is markedly
  // slower and produces a more fragmented result.
  stdout.writeln('Indexing');
  await db.execute('CREATE INDEX idx_place_lat ON place(lat_e5, lon_e5)');

  // External-content FTS5: the index stores no copy of the text, and matching
  // rows are fetched back from `place` by rowid. It has no synchronisation
  // triggers, which is safe only because the shipped database is read-only.
  // Any future write to `place` must update this in the same transaction or
  // the index silently desyncs.
  await db.execute(
    "CREATE VIRTUAL TABLE place_fts USING fts5("
    "name, content='place', content_rowid='id', tokenize='unicode61')",
  );
  await db.execute(
    "INSERT INTO place_fts(place_fts) VALUES('rebuild')",
  );

  // ANALYZE so the query planner reaches for idx_place_lat rather than
  // scanning; without it the first lookups on a device can be far slower.
  await db.execute('ANALYZE');
  await db.execute('VACUUM');
  await db.close();

  stopwatch.stop();
  final bytes = out.lengthSync();
  stdout
    ..writeln('')
    ..writeln('Wrote $outPath in '
        '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s')
    ..writeln('Size: ${(bytes / 1024 / 1024).toStringAsFixed(2)} MB');

  await _report(out.absolute.path);
}

/// Prints the figures the specification records, so a rebuild can be compared
/// against the database that was measured.
Future<void> _report(String path) async {
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
  );

  Future<int> count(String where) async {
    final rows = await db.rawQuery('SELECT count(*) AS n FROM place $where');
    return rows.first['n']! as int;
  }

  final total = await count('');
  final bd = await count("WHERE country='BD'");
  final us = await count("WHERE country='US'");

  stdout
    ..writeln('')
    ..writeln('Against the figures in the requirements specification:')
    ..writeln('  places   $total   (specification: 235242)')
    ..writeln('  BD       $bd      (specification: 161)')
    ..writeln('  US       $us      (specification: 21782)');

  // The FR-3.1 fixture, checked end to end.
  final rows = await db.rawQuery(
    'SELECT name, admin1, admin2, country FROM place '
    'WHERE lat_e5 BETWEEN 2369610 AND 2379610 '
    'AND lon_e5 BETWEEN 9032961 AND 9042879 '
    'ORDER BY (lat_e5 - 2374610) * (lat_e5 - 2374610) '
    '+ (lon_e5 - 9037420) * (lon_e5 - 9037420) LIMIT 1',
  );
  if (rows.isNotEmpty) {
    final r = rows.first;
    stdout.writeln('  nearest to 23.7461, 90.3742: '
        '${r['name']}, ${r['admin2']}, ${r['admin1']}, ${r['country']} '
        '(specification: Dhanmondi, Dhaka, Dhaka Division, BD)');
  }

  await db.close();
}

int? _intArg(List<String> args, String name) {
  final value = _stringArg(args, name);
  return value == null ? null : int.tryParse(value);
}

String? _stringArg(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i == -1 || i + 1 >= args.length) return null;
  return args[i + 1];
}
