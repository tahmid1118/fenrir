# Third-party data and code notices

Fenrir bundles third-party data and derives code from third-party sources.
Each carries an attribution obligation, listed here and surfaced in the app
itself through the map attribution control.

Requirement FR-9.2 means none of this involves a network call: everything below
ships with the binary, so these notices are the only place the obligation can be
discharged besides the in-app control.

---

## GeoNames — place database

- **Used for:** `assets/db/places.db`, the 235,242-place database behind offline
  place-name resolution (FR-3.1).
- **Source:** https://www.geonames.org/ (`cities500` export)
- **Licence:** Creative Commons Attribution 4.0 International (CC BY 4.0)
- **Obligation:** attribution required; commercial use permitted.

> This product includes data created by GeoNames (https://www.geonames.org/),
> licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/).

## Natural Earth — world basemap

- **Used for:** `assets/map/basemap.mbtiles`, the bundled zoom 0–5 world
  basemap (FR-4.1).
- **Source:** https://www.naturalearthdata.com/ via
  https://github.com/nvkelso/natural-earth-vector
- **Licence:** public domain.
- **Obligation:** none legally required. Natural Earth asks that users credit
  the project where practical, and doing so costs nothing.

> Map data from Natural Earth (https://www.naturalearthdata.com/), public
> domain.

Natural Earth was chosen over an OpenStreetMap-derived basemap deliberately.
At zoom 0–5 the only renderable content is coastlines, borders and lakes —
exactly Natural Earth's 1:110m and 1:50m scales — and being public domain it
keeps the bundled tier entirely clear of the ODbL share-alike question raised
in section 7 of the requirements specification.

## Open Location Code (Plus Codes) — coordinate encoding

- **Used for:** `lib/src/geo/plus_code.dart`, a Dart implementation of the
  reference algorithm (FR-2.2).
- **Source:** https://github.com/google/open-location-code
- **Copyright:** Copyright 2014 Google Inc.
- **Licence:** Apache License, Version 2.0
  (http://www.apache.org/licenses/LICENSE-2.0)
- **Obligation:** attribution in notices; the licence text must accompany
  distribution.

The implementation follows the published reference algorithm closely, including
its integer arithmetic, because floating-point evaluation produces off-by-one
errors in the final digit. Correctness is verified against the project's own
test vectors, committed at `test/geo/fixtures/`, which are covered by the same
licence.

---

## Not used

**what3words** was evaluated and rejected. It is proprietary and requires a
commercial licence and API agreement. Plus Codes provide the same offline,
algorithmic, worldwide behaviour with no licence fee.

## Outstanding

Tier 2 regional basemap packs are intended to be derived from OpenStreetMap,
which is licensed under ODbL 1.0 and carries a share-alike obligation on
derived databases. That question is not settled and does not affect anything
bundled today. It must be resolved before any regional pack ships.
