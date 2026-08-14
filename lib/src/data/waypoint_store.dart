import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';
import 'models.dart';

/// Local storage for saved positions (FR-6.1).
///
/// A separate database from the bundled ones, and the only one the app writes
/// to. Keeping user data apart from shipped data matters for a reason the
/// requirements state directly: FR-5.3 says deleting a downloaded pack must not
/// affect saved user data, and the cleanest way to guarantee that is for them
/// never to share a file.
///
/// It also means the bundled databases stay strictly read-only, so a corrupt
/// write can never damage the 235,242 places the app depends on.
class WaypointStore {
  WaypointStore(this._db);

  final Database _db;

  /// Bumped when the schema changes; [_upgrade] must then handle the step.
  static const int schemaVersion = 1;

  static const String fileName = 'fenrir.db';

  /// Opens, creating and migrating as needed.
  ///
  /// [path] and [factory] are injectable so tests run against a temporary file
  /// rather than the real application directory.
  static Future<WaypointStore> open({
    String? path,
    DatabaseFactory? factory,
  }) async {
    final resolved = path ??
        p.join((await getApplicationSupportDirectory()).path, fileName);

    final db = await (factory ?? appDatabaseFactory).openDatabase(
      resolved,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: _create,
        onUpgrade: _upgrade,
        singleInstance: false,
      ),
    );
    return WaypointStore(db);
  }

  static Future<void> _create(Database db, int version) async {
    // Coordinates are REAL here, unlike the integer form the bundled place
    // database uses. That form exists so a B-tree can serve proximity queries
    // over 235,242 rows; it also quantises to about a metre. A saved position
    // is the user's own record of where they stood, and there is no reason to
    // round it.
    await db.execute('''
      CREATE TABLE waypoint (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        label         TEXT,
        note          TEXT,
        latitude      REAL    NOT NULL,
        longitude     REAL    NOT NULL,
        accuracy_m    REAL    NOT NULL,
        altitude_m    REAL,
        place_name    TEXT,
        saved_at      INTEGER NOT NULL
      )
    ''');
    // Newest first is the only ordering the list uses.
    await db.execute('CREATE INDEX idx_waypoint_saved ON waypoint(saved_at)');
  }

  static Future<void> _upgrade(Database db, int from, int to) async {
    // Nothing to do yet. When it is needed, migrate step by step rather than
    // jumping: a user may skip several app versions, and dropping the table
    // would discard the one thing in this database that cannot be regenerated.
  }

  /// Saves a position and returns it with its assigned id.
  Future<Waypoint> add(Waypoint waypoint) async {
    final id = await _db.insert('waypoint', _toRow(waypoint));
    return waypoint.copyWith(id: id);
  }

  /// All saved positions, newest first.
  Future<List<Waypoint>> all() async {
    final rows = await _db.query('waypoint', orderBy: 'saved_at DESC, id DESC');
    return rows.map(_fromRow).toList();
  }

  Future<Waypoint?> byId(int id) async {
    final rows = await _db.query(
      'waypoint',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT count(*) AS n FROM waypoint');
    return rows.first['n']! as int;
  }

  /// Updates the label and note. The position itself is never editable —
  /// a waypoint is a record of where the user was, not a note that happens to
  /// have coordinates.
  Future<void> rename(int id, {String? label, String? note}) async {
    await _db.update(
      'waypoint',
      {'label': _blankToNull(label), 'note': _blankToNull(note)},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Returns whether a row was actually removed.
  Future<bool> remove(int id) async {
    final removed = await _db.delete(
      'waypoint',
      where: 'id = ?',
      whereArgs: [id],
    );
    return removed > 0;
  }

  Future<void> close() => _db.close();

  static Map<String, Object?> _toRow(Waypoint w) => {
        'label': _blankToNull(w.label),
        'note': _blankToNull(w.note),
        'latitude': w.latitude,
        'longitude': w.longitude,
        'accuracy_m': w.accuracyMeters,
        'altitude_m': w.altitudeMeters,
        'place_name': _blankToNull(w.placeName),
        // Stored as epoch milliseconds in UTC. A local-time string would shift
        // meaning the moment the user crosses a time zone, which for a
        // travelling app is a matter of course rather than an edge case.
        'saved_at': w.savedAt.toUtc().millisecondsSinceEpoch,
      };

  static Waypoint _fromRow(Map<String, Object?> row) => Waypoint(
        id: row['id'] as int?,
        label: row['label'] as String?,
        note: row['note'] as String?,
        latitude: (row['latitude']! as num).toDouble(),
        longitude: (row['longitude']! as num).toDouble(),
        accuracyMeters: (row['accuracy_m']! as num).toDouble(),
        altitudeMeters: (row['altitude_m'] as num?)?.toDouble(),
        placeName: row['place_name'] as String?,
        savedAt: DateTime.fromMillisecondsSinceEpoch(
          row['saved_at']! as int,
          isUtc: true,
        ),
      );

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
