# tools/

Build-time only. Nothing here ships in the app.

## `build_basemap.dart`

Renders the Tier 1 world basemap from Natural Earth vector data into an MBTiles
archive.

```bash
dart run tools/build_basemap.dart                     # zoom 0-5 -> assets/map/basemap.mbtiles
dart run tools/build_basemap.dart --max-zoom 4        # smaller, for a quick check
dart run tools/build_basemap.dart --out /tmp/x.mbtiles
```

Current output: **1,365 tiles, 2.69 MB, about 15 seconds.** Combined with
`places.db` that is 28.5 MB against the 60 MB Tier 1 ceiling in NFR-3, which the
script checks and fails on.

### Source data

Not committed — `tools/data/` is gitignored. Re-fetch from
`https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/`:

```
ne_110m_land.geojson
ne_110m_lakes.geojson
ne_110m_admin_0_boundary_lines_land.geojson
ne_50m_land.geojson
ne_50m_lakes.geojson
ne_50m_admin_0_boundary_lines_land.geojson
```

1:110m serves zoom 0–2 and 1:50m serves zoom 3–5. Finer data at low zoom would
cost parsing time to draw detail smaller than a pixel.

Natural Earth is **public domain**, which is why it is used here instead of an
OpenStreetMap extract. At zoom 0–5 the only renderable content is coastlines,
borders and lakes — exactly what Natural Earth provides — and it keeps the
bundled tier clear of the ODbL share-alike question that section 7 of the
requirements specification leaves unresolved. See `NOTICE.md`.

### Why the rendering is hand-written

`src/tile_canvas.dart` implements its own scanline rasteriser rather than using
`package:image`'s `fillPolygon`, which ray-casts once per pixel per vertex.
Filling a coastline of a few thousand vertices into a supersampled tile costs on
the order of a billion operations there; across 1,365 tiles that is hours. The
scanline version is O(scanlines × edges) and fills several rings in one pass
under the even-odd rule, so polygon holes come out right without a second pass.

Tiles are rendered at 2× and averaged down. The rasteriser writes hard-edged
pixels, and coastlines drawn straight to 256 px look visibly jagged on a phone.

### Two traps

- **MBTiles rows are TMS**, numbered from the south; slippy-map XYZ numbers from
  the north. Reversing it renders the world upside down and looks plausible in a
  single tile. `tmsRow` is tested for this.
- **`sqflite_common_ffi` resolves relative paths** against its own
  `.dart_tool` databases directory, not the working directory. The writer forces
  the path absolute; without that the archive lands somewhere nobody looks and
  the build appears to succeed.

## `build_places_db.dart`

Rebuilds the Tier 1 place database from the GeoNames export.

```bash
dart run tools/build_places_db.dart                       # -> assets/db/places.db
dart run tools/build_places_db.dart --out /tmp/check.db   # compare without overwriting
dart run tools/build_places_db.dart --min-population 500
```

Takes about 5 seconds and produces roughly 25.9 MB. On completion it prints the
figures the requirements specification records, so a rebuild can be checked
against the database that was measured.

### Source data

Also gitignored. From `https://download.geonames.org/export/dump/`:

```
cities500.zip           # extract cities500.txt, ~39 MB
admin1CodesASCII.txt    # first-level division names
admin2Codes.txt         # second-level division names
```

The two code files are optional — without them places still resolve, they just
carry blank division names — so a missing lookup table warns rather than stops
the build.

GeoNames is **CC BY 4.0**: attribution is required. See `NOTICE.md`.

### Why the shipped database is not simply regenerated

A rebuild on 2026-08-15 produced **235,311** places against the **235,242** the
specification measured on 2026-08-12. Country counts and the FR-3.1 fixture
match exactly (BD 161, US 21,782, Dhanmondi at 1.29 km); the 69 extra rows are
three days of upstream GeoNames edits, not a defect in this script.

`assets/db/places.db` is therefore left as-is. Every distance fixture in the
test suite rests on that exact dataset, and `place_repository_test` asserts the
row count so a swap fails loudly. If you do regenerate it, expect to update
those constants and re-verify the fixtures — and bump
`BundledAssetStore.places.version`, or devices that already extracted the old
copy will keep using it.

### One trap

`batch.commit()` already runs inside its own transaction. Wrapping it in a
manual `BEGIN`/`COMMIT` fails with *cannot start a transaction within a
transaction*.

## Verifying output by eye

The tests cover the geometry, but the fastest way to confirm a rendering change
is to look at a tile. `sqlite3` ships with the Android platform-tools:

```bash
# zoom 0, the whole world
sqlite3 assets/map/basemap.mbtiles \
  "SELECT writefile('/tmp/z0.png', tile_data) FROM tiles WHERE zoom_level=0;"

# a recognisable tile: western Europe at zoom 4
sqlite3 assets/map/basemap.mbtiles \
  "SELECT writefile('/tmp/med.png', tile_data) FROM tiles
   WHERE zoom_level=4 AND tile_column=8 AND tile_row=10;"
```

That second tile should show Britain, the Alps and the boot of Italy. If it is
upside down or empty, the TMS flip or the projection has regressed.
