import 'package:sqflite_common_ffi/sqflite_ffi.dart';

export 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;

/// The SQLite engine the whole app uses.
///
/// Deliberately the bundled one rather than the platform's. Android's system
/// SQLite is whatever the vendor compiled: a device run failed with
/// `no such module: fts5` on a current Samsung handset while every test passed,
/// because the tests were running against a different SQLite entirely.
///
/// Bundling it means the engine is the same in tests, on a phone and on a
/// desktop, and that a capability proven once is proven everywhere. For an app
/// whose whole value is behaving predictably with no network to fall back on,
/// that determinism is worth the roughly 1.5 MB per ABI it costs — against an
/// NFR-3 budget with more than 30 MB of headroom.
bool _initialised = false;

/// Prepares the engine. Safe to call more than once.
void initialiseDatabases() {
  if (_initialised) return;
  sqfliteFfiInit();
  _initialised = true;
}

/// The factory every database in the app is opened with.
DatabaseFactory get appDatabaseFactory {
  initialiseDatabases();
  return databaseFactoryFfi;
}
