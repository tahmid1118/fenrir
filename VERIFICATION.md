# Milestone 1 verification

Evidence for the cold-start vertical slice. Measured figures, not estimates;
where something is unverified it says so rather than being left to look
finished.

Last run: 2026-08-15, against commit `203ddd8`.
Suite: **175 tests passing**, `flutter analyze` clean.

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
| FR-6.1 | Save the current position as a waypoint | ✅ | Local SQLite, separate from the bundled databases. Confirmed on device: saved, listed, undoable. |
| FR-8.1 | Offline place search | ✅ | 235,242 names via FTS5, with distance and bearing. On device: *Chattogram → 214 km SE*. |
| FR-8.2 | Coordinate and Plus Code entry | ✅ | Five notations parsed; round-trip property asserts anything rendered can be pasted back. |
| FR-9.1 | Zero-configuration first run | ✅ | One screen, no route stack, no wizard, no account. Asserted in `home_screen_test`. |
| FR-9.2 | No accounts, tracking or advertising | ✅ | See the dependency audit below. |

## Non-functional requirements

## Device run — 2026-08-15, Samsung SM-S721B, Android 16

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

### NFR-4 — 60 fps, cold start under 2 s · partially verified

**Cold start: 1,453 ms** on the reference handset (`am start -W`,
`LaunchState: COLD`), on a first run that also extracted 28.5 MB of assets.
Inside the 2-second figure.

**Outstanding:** sustained 60 fps during pan and zoom. Needs a profile-mode run
with the performance overlay; a debug build's frame times prove nothing.

### NFR-5 — battery behaviour · out of scope

Power-saving mode is FR-1.3, deferred with the rest of the SHOULD tier.

### NFR-6 — never a blank screen · ✅ verified

`LocationState` is sealed, so a missing state is a compile error rather than a
blank. All seven defined states are asserted in `home_screen_test`:

services disabled · permission denied (soft) · permission denied (permanent) ·
searching · asset extraction failed · located · no place nearby

A missing map tile resolves to a transparent image rather than throwing, and
`maxNativeZoom: 5` upscales past the bundled detail rather than going empty.

### NFR-7 — accessibility · partially verified

- **Contrast** — asserted, not eyeballed. Every fix-status colour clears 4.5:1
  against the surface (4.94, 6.96, 11.49, 16.51), as do body, variant and
  primary text.
- **Not colour alone** — the palette is ordered by luminance and every state
  carries an icon and a word. An earlier green/amber pair measured 1.04:1
  against each other; that is the pair red-green colour blindness collapses.
- **Text scaling** — 200% asserted with no overflow. This caught two real
  defects: the sheet overflowed by 142 px and the action buttons by 17 px.
- **Readable as text** — coordinates render in `SelectableText`.
- **Screen-reader labels** — `Semantics` on the marker, the recentre control,
  the readout, the fix indicator and the place banner, with `liveRegion` on the
  two that update.

**Outstanding:** a real TalkBack pass. Semantics nodes existing is not the same
as the screen being usable with the screen reader on.

---

## Outstanding before release

| Item | Why it matters |
|---|---|
| **Sustained 60 fps** | NFR-4's other half. Needs a profile-mode run with the performance overlay. |
| **TalkBack pass** | NFR-7. |
| **Release signing** | `signingConfig = signingConfigs.getByName("debug")` is still the stock TODO in `android/app/build.gradle.kts`. **Not shippable as-is.** |
| **ODbL position** | Only affects Tier 2 regional packs, which are out of this milestone. Tier 1 avoids it entirely by using public-domain Natural Earth. |

## Reproducing these figures

```bash
flutter analyze
flutter test                                   # prints the NFR-2 and NFR-3 lines
flutter build appbundle --release --target-platform android-arm64 --analyze-size
flutter pub deps --style=compact --no-dev      # dependency audit
dart run tools/build_basemap.dart              # re-checks the Tier 1 budget
dart run tools/build_places_db.dart --out /tmp/check.db
```
