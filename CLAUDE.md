# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Keep this file current.** Whenever you change architecture, conventions, dependencies, the data schema, or the build pipeline, update the relevant section here *in the same change*. A drifted CLAUDE.md is a bug. Prefer concise, additive edits.

> **Keep `NOTICE.md` current.** Every bundled dataset and derived implementation carries an attribution obligation, and section 7 of the requirements specification flags the ODbL position as `LEGAL ACTION REQUIRED`. If you add, remove, or change a data source or a vendored algorithm, update `NOTICE.md` *in the same change*, and make sure the in-app attribution control still lists everything it must. These obligations are legally operative — a notice that no longer matches what ships is a real liability, not a docs bug.

> **Requirement IDs are the vocabulary.** The specification (`Fenrir-Requirements-Specification.pdf`) numbers everything as `FR-x.y` and `NFR-x`. Code comments, tests, and commit messages cite them. When you implement or change behaviour, cite the requirement it serves — and if you find yourself unable to name one, question whether the change belongs.

> **Always push after a change.** After completing and verifying a change, commit it and `git push` to `origin`. Do not leave finished work uncommitted or unpushed.

## Commands

```bash
flutter pub get                      # Resolve dependencies
flutter analyze                      # Static analysis (must be clean)
flutter test                         # Full suite
flutter test test/geo/               # One directory
flutter test test/geo/haversine_test.dart          # One file
flutter test --name "the antimeridian"             # One test by name substring
flutter test --plain-name "NFR-2 place resolution latency 95th percentile is under 50 ms"

flutter devices                      # List targets
flutter run -d R5CXA3S38BJ           # Run on the physical Android device
flutter build apk --debug            # Debug APK
flutter build appbundle --analyze-size   # Release bundle + size breakdown (NFR-3)
```

The `master` branch is a leftover pointing at the initial commit. Work happens on `main`.

## Architecture

An offline-first Android/iOS positioning app. The engineering problem is not
acquiring a coordinate — GNSS already works without a network — it is rendering
that coordinate as something a human understands with no server to ask.

### Layout

```
lib/src/geo/        Pure Dart. No Flutter binding, no I/O. Haversine, Plus
                    Codes, coordinate notations.
lib/src/data/       Bundled asset extraction, place database access, models.
lib/src/location/   GNSS acquisition and the state machine the UI renders.
lib/src/ui/         Theme and screens.
tools/              Build-time only. Never ships.
```

Tests mirror `lib/src/` exactly.

### Three-tier data model

Tier 1 is bundled in the binary and must never exceed 60 MB (NFR-3): the place
database plus a world basemap capped at zoom 5. Tiers 2 (regional basemaps) and
3 (OSM-derived place packs) are downloaded on demand and are **out of scope for
the current milestone**. Tier 1 exists so the app is never useless — that
cold-start usefulness is the entire product claim against competitors, all of
which ship an empty app until a region is downloaded.

### The place database

`assets/db/places.db`, 25.8 MB, 235,242 rows. One denormalised table, no lookup
tables:

```sql
CREATE TABLE place (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, admin1 TEXT, admin2 TEXT,
  country TEXT NOT NULL,                              -- ISO 3166-1 alpha-2
  lat_e5 INTEGER NOT NULL, lon_e5 INTEGER NOT NULL,   -- degrees x 1e5
  pop INTEGER, tz TEXT
);
CREATE INDEX idx_place_lat ON place(lat_e5, lon_e5);
CREATE VIRTUAL TABLE place_fts USING fts5(name, content='place', content_rowid='id');
```

Things that will bite you:

- **`admin2` is NULL in 33,521 rows.** Never assume it is present.
- **`admin1` naming is inconsistent in the source data** — Bangladesh has both
  `Chittagong` and `Khulna Division`. Never synthesize or strip a `" Division"`
  suffix; render what is stored.
- **There is no feature-class column.** The populated-place filter was applied
  at build time and cannot be re-applied at query time. `pop > 0` is the only
  lever.
- **`place_fts` is external-content with no sync triggers.** Any write to
  `place` silently desyncs the index unless the FTS table is updated in the same
  transaction. Harmless while the asset is read-only.
- **`place_fts` indexes `name` only.** Division and country names are not
  searchable, so "Chittagong" finds nothing while "Chattogram" — the city's
  actual GeoNames name — finds it. Widening this means rebuilding the database.

### SQLite is bundled, not borrowed

The app uses `sqflite_common_ffi`, whose native library `package:sqlite3` builds
from source, rather than the `sqflite` plugin and the platform's SQLite.

This is not a preference. A device run failed with **`no such module: fts5`** on
a current Samsung handset (Android 16) while all 230 tests passed, because
Android's system SQLite is whatever the vendor compiled and this one has FTS5
out. The tests passed because `sqflite_common_ffi` bundles its *own* SQLite —
**they were running against a different engine than the device.**

Bundling makes the engine identical in tests, on a phone and on a desktop, so a
capability proven once is proven everywhere. It costs about 1.5 MB per ABI
against an NFR-3 budget with more than 30 MB of headroom.

**Do not reintroduce `package:sqflite`.** Open databases through
`appDatabaseFactory` in `lib/src/data/database.dart`.

### Why place resolution is two-stage

There is no R\*Tree, and Android's system SQLite ships without the maths
functions, so `acos` is unavailable in SQL. `PlaceRepository` therefore runs an
integer bounding box that `idx_place_lat` can serve, then haversine over the
survivors in Dart.

Radii escalate 25 → 100 → 250 km. The box is a *square*, so its corners reach
further than the radius: a nearest candidate beyond the radius proves nothing
was found inside it, but does **not** prove it is the nearest overall. The
search only accepts a result within the radius it came from, and widens
otherwise. Removing that check reintroduces plausible-but-wrong answers at the
edges of sparse regions.

Two geometry cases only fail where nobody develops, and both are tested:
crossing the antimeridian needs **two** queries (`lon_e5 BETWEEN 17990000 AND
-17990000` selects nothing), and near the poles the longitude span exceeds the
globe, so the search covers every longitude.

The 250 km ceiling implements FR-3.3. A negative result is a **null return**,
not an empty match, so the type system forces callers to handle it.

### Assets must be extracted before use

SQLite cannot open a database out of `rootBundle`; it needs a real path. Both
Tier 1 payloads go through `BundledAssetStore`, which writes to a temp file,
renames it into place, and only then writes a `<name>.version` marker holding
`<version>:<byte length>`. The asset ships with `PRAGMA user_version = 0`, so
there is no stamp inside the file — the marker is the mechanism, and the length
is what catches a truncated copy. This doubles the installed footprint; NFR-3
governs download size, so the budget holds.

### Location state

`LocationState` is **sealed** (`PermissionDenied` / `ServicesDisabled` /
`Searching` / `Located`) so adding a state is a compile error everywhere one is
rendered. NFR-6 forbids unexplained blanks; letting the compiler enforce
exhaustiveness is cheaper than remembering to.

`FixQuality` is a function of the **current time**, not a property fixed when
the reading arrived — `qualityAt(now)`, never a stored field. `LocationService`
re-emits the held fix once a second for exactly this reason: without a tick,
nothing prompts the UI to recompute age, and a receiver that stops delivering
leaves a stale fix on screen looking fresh. That is the failure FR-1.2 names.

Android uses `AndroidSettings(forceLocationManager: true)` to route through the
platform LocationManager rather than the fused provider, because the fused
provider blends in Wi-Fi and cell positioning without saying so, which FR-1.1
forbids. The cost is a slower first fix. **This is not a performance bug to be
optimised away.**

## Decisions that look wrong until you know why

- **Plus Codes are implemented in-repo**, not taken from `open_location_code`,
  which pins `latlong2: ^0.9.0` and cannot resolve against the `^0.10.1` that
  `flutter_map` needs. The algorithm is graded against 747 official Google
  vectors in `test/geo/fixtures/`. It works in integers deliberately — floating
  point produces off-by-one errors in the final digit.
- **UTM/MGRS come from `geobase`**, not hand-rolled: the Krüger series behind an
  accurate transverse Mercator is easy to get subtly wrong. They are **undefined
  above 84°N and below 80°S** and `geobase` throws there, so formatting returns a
  `FormattedCoordinate` that either carries text or a reason it has none.
- **Raster MBTiles, not vector PMTiles.** No stable vector-tile plugin supports
  `flutter_map` 8.x (`vector_map_tiles` pins `^7.0.2`). MBTiles is also just
  SQLite, so the build script is pure Dart with no external toolchain.
- **Natural Earth, not OpenStreetMap, for the Tier 1 basemap.** At zoom 0–5 the
  only renderable content is coastlines, borders and lakes — exactly Natural
  Earth's scales — and being public domain it keeps the bundled tier clear of
  the ODbL share-alike question entirely.
- **Dark-only theme.** The fix-status palette is ordered by *luminance*, not
  just hue, and is tested for it. A conventional green/amber pair measures
  1.04:1 against each other — identical brightness, differing only in hue, which
  is what red-green colour blindness collapses. Colour is never the sole channel.

## Testing

Tests run against the **real shipped `places.db`**, not fixtures or mocks, via
`sqflite_common_ffi`. The specification's verified results are only meaningful
if checked against the bytes that ship. `test/data/place_repository_test.dart`
also asserts the database's identity (235,242 rows, BD 161, US 21,782) so an
asset swap fails loudly rather than silently invalidating every distance
fixture.

Pass an **absolute** path to `openDatabase` — relative paths resolve against
the package's own `.dart_tool` databases directory, not the project root. This
has bitten twice: once in a test, once in the basemap builder, where it wrote
all 1,365 tiles somewhere nobody was looking and only failed afterwards.

Because the app now bundles the same SQLite the tests use, a capability
confirmed in a test is genuinely confirmed on device. That was not true before
— see the FTS5 note above — and it is the reason the engine is bundled.
Platform behaviour that cannot be bundled (GNSS, permissions, the share sheet)
still has to be checked on hardware.

Platform statics (`geolocator`) and I/O (`rootBundle`, `path_provider`) are
injected behind interfaces so state machines are testable without a device.

NFR budgets are asserted, not assumed: place resolution measures its own p95
against the 50 ms ceiling and prints the number so it appears in CI output as
evidence.

## Conventions

- 80-column lines (`.vscode/settings.json` sets `dart.lineLength`), format on
  save.
- `flutter_lints` with no custom rules. `flutter analyze` must be clean.
- Comments explain **why**, especially where the code looks wrong — the
  non-obvious constraint, the failure being prevented, the trade being made.
  Do not narrate what the code already says.
