# Milestone 1 verification

Evidence for the cold-start vertical slice. Measured figures, not estimates;
where something is unverified it says so rather than being left to look
finished.

Last run: 2026-08-15.
Suite: **347 tests passing**, `flutter analyze` clean, plus one on-device
integration test (`integration_test/perf_test.dart`) that does not run under
`flutter test`.

---

## Functional requirements

| Req | What it asks | Status | Evidence |
|---|---|---|---|
| FR-1.1 | GPS fix without network, no silent fallback | ✅ | `AndroidSettings(forceLocationManager: true)` routes through the platform LocationManager, not the fused provider. Confirmed on device in airplane mode: the app acquired and held a fix with every radio off, and the UI states plainly that it uses the receiver directly rather than nearby networks. |
| FR-1.2 | Fix quality and accuracy radius | ✅ | `position_fix_test`: every quality boundary; radius always rendered; `home_screen_test` covers acquired / approximate / stale on screen. |
| FR-2.1 | DD, DMS, UTM, MGRS, one-tap switching | ✅ | `coordinate_formats_test` (19); UTM/MGRS pinned to geobase's published Eiffel Tower values; switching exercised in `home_screen_test`. |
| FR-2.2 | Plus Code generation | ✅ | **747/747** official Google vectors — 302 encoding, 420 decoding, 25 validity. |
| FR-2.3 | Copy and share | ✅ | Payload asserted to carry place name, bare decimal degrees, Plus Code and accuracy, with no app-specific scheme. |
| FR-3.1 | Resolve to a place name offline | ✅ | `23.7461, 90.3742` → **Dhanmondi, Dhaka, Dhaka Division, BD at 1.2917 km**, against the shipped database. |
| FR-3.2 | Report distance honestly | ✅ | *near* vs *in* asserted, including a Sundarbans position in the real coverage gap. |
| FR-3.3 | Nothing over open water | ✅ | `30.0, -40.0` → null, plus four more ocean probes. |
| FR-4.1 | Map with position, offline, first launch | ✅ | Confirmed by eye on a phone in airplane mode, on a first run with nothing cached: the bundled basemap rendered with the position marker on it. This is the product's differentiating claim and it now has a screenshot behind it. |
| FR-4.2 | Seamless detail upgrade when a pack is installed | ✅ built, ⚠ no packs exist | `LayeredTileProvider` draws the most detailed archive available per tile and falls through to the basemap. Verified with synthetic archives (holes, precedence, zoom/bounds rejection). **No regional pack has actually been produced** — that needs an OSM processing pipeline and hosting, and §7's ODbL question is unresolved. Untestable end-to-end until one exists. |
| FR-4.3 | Follow-me, heading-up, compass rose | ✅ | Confirmed on device: the map rotates and the needle tracks screen north, labelled **`TRUE`** — the World Magnetic Model correction confirmed live on hardware. See below. |
| FR-5.1 | Browse and download packs, pause/resume/cancel, sizes stated up front | ✅ built, ⚠ empty catalogue | Resume verified against a **real local HTTP server** issuing actual range requests, including the case where the server ignores the range and answers 200. `RegionPack.formatBytes` states size before commit. The catalogue itself has zero entries — same blocker as FR-4.2. |
| FR-5.2 | Downloaded data never expires or is capped | ✅ | Enforced by absence: nothing in `RegionPack` or `PackStore` can express an expiry, a lease, or a cap. |
| FR-5.3 | Storage accounting and deletion | ✅ | Lists installed packs from disk rather than a catalogue, so a withdrawn entry stays deletable. Deletion cannot address anything outside its own directory, which is how it can never touch Tier 1 or saved waypoints. |
| FR-6.1 | Save the current position as a waypoint | ✅ | Local SQLite, separate from the bundled databases. Confirmed on device: saved, listed, undoable, and the stored accuracy (±17 m) correctly stayed put while the live fix later improved to ±8.5 m. |
| FR-7.1 | Share position over SMS | ✅ | Composer opens prefilled, recipient chosen by the user. Needed a `<queries>` declaration or Android 11+ cannot see the SMS app at all. Verified on device. |
| FR-8.1 | Offline place search | ✅ | 235,242 names via FTS5, with distance and bearing. On device: *Chattogram → 214 km SE*. |
| FR-8.2 | Coordinate and Plus Code entry | ✅ | Five notations parsed; round-trip property asserts anything rendered can be pasted back. |
| FR-9.1 | Zero-configuration first run | ✅ | One screen, no route stack, no wizard, no account. Asserted in `home_screen_test`. |
| FR-9.2 | No accounts, tracking or advertising | ✅ | See the dependency audit below. |

## Device run history

Four sessions on the same handset (Samsung SM-S721B, Android 16), each adding
capability and each verified before moving on. This first one is kept in full
because the defect it found reshaped how every later session was tested.

### Session 1 — first device run, 2026-08-15

The app was installed, granted location, and driven on real hardware in Dhaka.

**Confirmed working:**

- The bundled Natural Earth basemap renders, correctly oriented, with the
  position marker on it (FR-4.1).
- Offline place resolution: *Paltan, Dhaka, Dhaka Division, BD · 3.5 km*
  (FR-3.1, FR-3.2).
- Fix quality tracked a real receiver honestly (FR-1.2). It opened at
  **"Approximate · ±29 m, low precision"** in amber, then moved to **"GPS fix ·
  ±6.5 m"** in mint as the fix improved — naming *which* problem it had, not
  just that it had one.
- Altitude with its own accuracy: *27 m ±5 m* (FR-2.4).
- Offline search with distance and bearing: *Chattogram → 214 km SE* (FR-8.1).
- Panning dropped follow-mode and revealed the recentre control.

**One defect found that 230 passing tests had missed:**

Search failed on device with `no such module: fts5`. Android's system SQLite is
whatever the vendor compiled, and this handset has FTS5 out. The tests passed
because `sqflite_common_ffi` bundles its own SQLite — they were running against
a different engine than the device. The app now bundles SQLite too, so the two
are the same. Fixed and re-verified on the same handset.

A second, smaller defect surfaced with it: the failing search left a progress
bar spinning forever with no explanation, which is exactly the unexplained
state NFR-6 rules out. Failures now say so.

**Known limitation, not a defect:** `place_fts` indexes place names only, so
"Chittagong" finds nothing while "Chattogram" — the city's actual GeoNames name
— finds it. Widening it means rebuilding the database.

### Session 2 — NFR-1 airplane-mode acceptance test

Covered in full in its own section below — the device was made genuinely
offline, a fresh install measured from a zero-byte network baseline, and the
zero-requests claim confirmed against `dumpsys netstats` rather than asserted.

### Session 3 — declination, region packs, waypoints, SMS, compass

Confirmed on this run: waypoint save/list/undo with the original accuracy
preserved (±17 m) even as the live fix later improved (±8.5 m); the SMS
composer opening prefilled with no message auto-sent; the compass rose
rotating the map live and tracking screen north.

### Session 4 — 60 fps profile run and TalkBack pass

Covered in full in the NFR-4 and NFR-7 sections below. This session also
confirmed, as a side effect of relaunching for the TalkBack pass, that the
compass rose now reads **`TRUE`** rather than `MAG` — the World Magnetic
Model correction from session 3, live on hardware.

---

### NFR-1 — total network independence · ✅ verified on hardware

The acceptance test the requirement names has now been run. Samsung SM-S721B,
Android 16, 2026-08-15.

**The device was made genuinely offline**, not merely told to be:

```
airplane_mode_on = 1        wifi_on = 0
ping 8.8.8.8  ->  connect: Network is unreachable
ping pub.dev  ->  ping: unknown host pub.dev
```

**The app was installed fresh in that state** — no extracted assets, no cache,
a new UID (10569) so its network accounting started from zero.

**Cold start: 1,453 ms**, measured by `am start -W`, `LaunchState: COLD`. That
run also extracted 28.5 MB of bundled assets, and still came in under the
2-second cold-start figure in NFR-4.

**What worked with the radios off:**

| | |
|---|---|
| Bundled world basemap rendered, correctly oriented | FR-4.1 |
| "Searching / No fix yet", with an explanation of why the first fix is slow | NFR-6, FR-1.1 |
| Offline search returned *Dhanmondi, Dhaka, Dhaka Division, BD* | FR-8.1 |
| Distance omitted, because there was genuinely no fix to measure from | FR-8.1 |
| No Flutter errors in logcat throughout | |

**Zero outbound requests, measured.** After the session, `dumpsys netstats
detail` was searched for the app's UID:

```
UID stats      section:  0 entries for uid=10569
UID tag stats  section:  0 entries for uid=10569
BPF map content:         1 entry  (kernel tracking table; carries no bytes)
```

Other applications appear throughout both byte-accounting sections. Fenrir
appears in neither. It did not merely fail to reach the network — it never
asked.

Static evidence, unchanged and still complete:

- No analytics, advertising, crash-reporting or telemetry package anywhere in
  the dependency graph. Searched for firebase, crashlytics, sentry, amplitude,
  mixpanel, segment, appsflyer, adjust, facebook, admob, datadog, posthog,
  bugsnag — **none present**.
- `lib/` contains **no** `package:http` import, no `HttpClient`, no socket, no
  `NetworkTileProvider`, and no URL construction.
- `http` appears transitively only via `flutter_map` (its default network tile
  provider, which this app does not use) and `package_info_plus`.
- The map is given `MbTilesTileProvider` explicitly; the network provider is
  never constructed.

### Magnetic declination · ✅ verified against NOAA

A compass measures magnetic north; the map is drawn to true north. The angle
between them is under a degree in Dhaka and London and exceeds twenty degrees
across parts of North America, so heading-up rotated by a raw magnetic reading
is visibly wrong over much of the world.

The correction is computed, not looked up: a degree-and-order-twelve spherical
harmonic expansion of the World Magnetic Model — ninety coefficients and some
arithmetic, no network, valid everywhere on Earth. That is the same reasoning
the specification applies to Plus Codes in section 2.4.

Graded against **all 100 of NOAA's published test values**, which cover several
epochs and altitudes rather than only sea level in 2025:

```
declination        every value within 0.01°   (the fixture's own precision)
inclination        every value within 0.01°
X, Y, Z, H, F      every value within 0.5 nT
evaluation cost    4.3 us
```

Checking the vector components as well as the angles matters: two components
wrong by the same factor still divide to a plausible-looking declination.

The model expires in 2029, and `isExpiredAt` knows it. Past that date, and
before the first fix arrives, headings fall back to magnetic and are labelled
`MAG` rather than corrected by a guess.

### NFR-2 — place resolution under 50 ms at p95 · ✅ verified

Measured over 300 randomised lookups against the shipped 25.8 MB database,
biased toward inhabited latitudes:

```
median 1.47 ms   p95 5.29 ms   worst 17.97 ms
```

Roughly **9× inside budget** at p95. Measured on desktop; a mid-range phone is
slower, but the margin is large and the query plan (`SEARCH place USING INDEX
idx_place_lat`) is the same.

### NFR-3 — size budget · ✅ verified

```
places.db          25.79 MB
basemap.mbtiles     2.69 MB
Tier 1 total       28.47 MB  of 60 MB      (47%)

release AAB        29.73 MB  of 200 MB     (15%)   arm64, per-device download
```

The basemap came in at a fifth of the 14.3 MB the specification estimated for a
vector tier at the same zoom range.

### NFR-4 — 60 fps, cold start under 2 s · ✅ verified on hardware

**Cold start: 1,453 ms** on the reference handset (`am start -W`,
`LaunchState: COLD`), on a first run that also extracted 28.5 MB of assets.
Inside the 2-second figure.

**Sustained 60 fps** is measured by `integration_test/perf_test.dart`, driven
via `flutter drive --profile --no-dds` on the physical handset — a **profile**
build, release-optimised code, not a debug build whose frame times prove
nothing. It performs real pan and double-tap-zoom gestures against the actual
map and reads the engine's own `FrameTiming` through
`IntegrationTestWidgetsFlutterBinding.watchPerformance`, the same instrument
`flutter_driver`'s classic timeline summary was built to replace.

```
build     avg 4.66 ms   worst 11.71 ms   p90 8.98 ms
raster    avg 3.09 ms   worst 10.56 ms   p90 5.29 ms
frames    24 recorded, 0 missed build budget, 0 missed raster budget
```

Both p90 figures sit comfortably under the 16.6 ms a 60 Hz display allows —
worst-case build time alone (11.71 ms) is still inside budget. The test
asserts this itself (`expect(p90BuildMs, lessThan(16.6))` and the same for
raster), so a future regression fails the run rather than needing a person to
notice a stutter.

Reproduce:

```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/perf_test.dart \
  --profile --no-dds -d <device>
```

### NFR-5 — battery behaviour · out of scope

Power-saving mode is FR-1.3, deferred with the rest of the SHOULD tier.

### NFR-6 — never a blank screen · ✅ verified

`LocationState` is sealed, so a missing state is a compile error rather than a
blank. All seven defined states are asserted in `home_screen_test`:

services disabled · permission denied (soft) · permission denied (permanent) ·
searching · asset extraction failed · located · no place nearby

A missing map tile resolves to a transparent image rather than throwing, and
`maxNativeZoom: 5` upscales past the bundled detail rather than going empty.

### NFR-7 — accessibility · ✅ verified with TalkBack running

- **Contrast** — asserted, not eyeballed. Every fix-status colour clears 4.5:1
  against the surface (4.94, 6.96, 11.49, 16.51), as do body, variant and
  primary text.
- **Not colour alone** — the palette is ordered by luminance and every state
  carries an icon and a word. An earlier green/amber pair measured 1.04:1
  against each other; that is the pair red-green colour blindness collapses.
- **Text scaling** — 200% asserted with no overflow. This caught two real
  defects: the sheet overflowed by 142 px and the action buttons by 17 px.
- **Readable as text** — coordinates render in `SelectableText`.

**TalkBack pass, 2026-08-15, same handset.** Enabled via
`settings put secure enabled_accessibility_services
com.samsung.android.accessibility.talkback/…TalkBackService`, then the
*actual* Android accessibility tree TalkBack consumes was captured with
`uiautomator dump` — not our own widget-level `Semantics` tree in isolation,
the platform-side tree after Flutter's merging has already run.

That surfaced two real defects no widget test had caught:

1. **The position marker's label merged with the map attribution text.**
   `Semantics(label: 'Your position', …)` had no `container: true`, so on
   device it was announced as *"Your position, copyright Natural Earth,
   copyright GeoNames…"* — one announcement, even though "Attributions" also
   exists as its own separate button. Fixed by giving the marker (and the
   searched-place marker) an explicit semantics boundary.
2. **Icon buttons were announced twice**, and inconsistently. `IconButton`'s
   own `tooltip` parameter contributes a *second*, independent semantics node
   on Android. The search button was the worst case — one node said "Search
   places offline", a second said "Search places" — two differently-worded
   stops for one control. Fixed with `excludeSemantics: true` on the outer
   `Semantics`, the pattern the compass rose already used correctly.

Both are now asserted as widget tests (`home_screen_test.dart`) — Flutter's
semantics merging runs entirely in the framework, so the same merge is
reproducible without a device — and reverified against the real tree after
the fix:

```
before   "Your position\n© Natural Earth\n© GeoNames (CC BY 4.0)\n© Plus Codes (Apache 2.0)"
after    "Your position"                                              (own node)
         "© Natural Earth\n© GeoNames (CC BY 4.0)\n© Plus Codes (Apache 2.0)"   (own node)

before   "Saved places" x2, "Search places offline" + "Search places"
after    "Saved places" x1, "Search places offline" x1
```

TalkBack was switched off and normal touch behaviour on the device confirmed
restored afterward.

---

## Outstanding before release

| Item | Why it matters |
|---|---|
| **Release signing** | `signingConfig = signingConfigs.getByName("debug")` is still the stock TODO in `android/app/build.gradle.kts`. **Not shippable as-is.** |
| **No regional packs exist** | FR-4.2 and FR-5.1–5.3 are built and tested against synthetic archives, but the catalogue is empty. Producing one needs an OSM processing pipeline and hosting for several-hundred-MB files per country — infrastructure work, not app code. |
| **ODbL position** | Blocks the item above. §7 of the specification requires a legal opinion on ODbL share-alike before any OSM-derived pack ships. Tier 1 avoids the question entirely by using public-domain Natural Earth. |
| **`place_fts` indexes names only** | "Chittagong" (the division) finds nothing; "Chattogram" (the city's actual GeoNames name) finds it. Widening this means rebuilding the place database. |

Every other item previously listed here — sustained 60 fps, the true-north
label on device, and the TalkBack pass — has since been verified on hardware
and is recorded above.

## Reproducing these figures

```bash
flutter analyze
flutter test                                   # prints the NFR-2 and NFR-3 lines
flutter build appbundle --release --target-platform android-arm64 --analyze-size
flutter pub deps --style=compact --no-dev      # dependency audit
dart run tools/build_basemap.dart              # re-checks the Tier 1 budget
dart run tools/build_places_db.dart --out /tmp/check.db
```
