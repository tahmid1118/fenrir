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
| FR-1.1 | GPS fix without network, no silent fallback | Built, device-unverified | `AndroidSettings(forceLocationManager: true)` routes through the platform LocationManager rather than the fused provider. Cannot be proven without a device. |
| FR-1.2 | Fix quality and accuracy radius | ✅ | `position_fix_test`: every quality boundary; radius always rendered; `home_screen_test` covers acquired / approximate / stale on screen. |
| FR-2.1 | DD, DMS, UTM, MGRS, one-tap switching | ✅ | `coordinate_formats_test` (19); UTM/MGRS pinned to geobase's published Eiffel Tower values; switching exercised in `home_screen_test`. |
| FR-2.2 | Plus Code generation | ✅ | **747/747** official Google vectors — 302 encoding, 420 decoding, 25 validity. |
| FR-2.3 | Copy and share | ✅ | Payload asserted to carry place name, bare decimal degrees, Plus Code and accuracy, with no app-specific scheme. |
| FR-3.1 | Resolve to a place name offline | ✅ | `23.7461, 90.3742` → **Dhanmondi, Dhaka, Dhaka Division, BD at 1.2917 km**, against the shipped database. |
| FR-3.2 | Report distance honestly | ✅ | *near* vs *in* asserted, including a Sundarbans position in the real coverage gap. |
| FR-3.3 | Nothing over open water | ✅ | `30.0, -40.0` → null, plus four more ocean probes. |
| FR-4.1 | Map with position, offline, first launch | Built, device-unverified | 1,365 tiles render and read back correctly; the assembled screen is verified by widget test, but not yet by eye on a phone. |
| FR-9.1 | Zero-configuration first run | ✅ | One screen, no route stack, no wizard, no account. Asserted in `home_screen_test`. |
| FR-9.2 | No accounts, tracking or advertising | ✅ | See the dependency audit below. |

## Non-functional requirements

### NFR-1 — total network independence · partially verified

Static evidence is complete:

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

**Outstanding:** the acceptance test the requirement actually names — the full
regression walkthrough on a device in airplane mode with zero outbound requests
observed. Needs hardware.

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

### NFR-4 — 60 fps, cold start under 2 s · not verified

Requires profile-mode runs on hardware. Nothing here substitutes for it.

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
| **Device pass in airplane mode** | The acceptance test NFR-1 names. Also the only way to verify FR-1.1's GNSS-only behaviour, FR-4.1 by eye, and NFR-4. |
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
