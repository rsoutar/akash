# Akash — tasks

Order matters: steps 1–2 give a working radar plugin (everything from omarchy-weather-radar), steps 3–6 add the air-quality half (kuki's side), steps 7–9 make it one coherent plugin. Each task ends in a verifiable state.

## 0. Scaffold

- [x] **0.1** Create `manifest.json` (plugin id `akash`, name, description, MIT licence) following the two upstream manifests.
- [x] **0.2** Vendor from omarchy-weather-radar: `lib/TileMath.js`, `lib/Basemap.js`, `lib/Glyphs.js`, `lib/Frames.js`, `data/basemap.bin`, `tools/build-basemap.py`, and the `test/` harness (`load.js` + stream-ceiling + text-format tests).
- [x] **0.3** Vendor `lib/RadarModel.js`, `lib/Alerts.js` (storm half), `lib/Settings.js` unchanged — they are pure functions and their tests come with them.
- [x] **0.4** Set up symlink development flow: `ln -s ~/Projects/akash ~/.config/omarchy/plugins/akash`, `rescanPlugins`, `omarchy plugin validate .`.
- ✅ Verify: `node --test` passes on vendored libs untouched.

## 1. Radar-only plugin (vertical slice)

- [x] **1.1** `ui/MapCanvas.qml`: basemap rendering, pan/zoom, themed colours (port from radar plugin's `RadarMap.qml`/`BasemapLayer.qml`/`TileLayer.qml`).
- [x] **1.2** `ui/RadarLayer.qml`: RainViewer XYZ tiles + coverage probe, z3–z9 with radar capped at z7.
- [x] **1.3** `Service.qml`: headless singleton — manifest fetch every 10 min while panel open, nothing when closed; tile cache by URL.
- [x] **1.4** `BarWidget.qml`: radar-scope icon only (AQ pill added in task 5).
- [x] **1.5** Minimal `Panel.qml`: open/close, timeline + play, "Radar unavailable" / "no radar coverage" states, Esc/keyboard bindings.
- ✅ Verify: panel shows a live two-hour radar loop on the offline basemap; `omarchy restart shell` after QML edits.

## 2. Location sharing

- [x] **2.1** `ui/LocationPicker.qml`: Open-Meteo geocoding search, commits via `omarchy-weather-location`, handles the name-without-coordinates state.
- [x] **2.2** Watch `~/.local/state/omarchy/settings/weather.json`; port the first-run `reloadLocation()` after-save fix and its test (`test/first-run.sh`).
- ✅ Verify: city set here moves the stock weather widget and vice versa; fresh-machine first run works.

## 3. CAMS helper (port cams.py)

- [x] **3.1** Adapt `cams.py` → akash paths (`~/.config/omarchy/akash/caps.json`, `state.json`, `AKASH_CONFIG_DIR` override); keep stdlib-only.
- [x] **3.2** Keep: `init`/`capabilities` (6 h TTL cache), `probe` (GetFeatureInfo), `legend` (PNG decode), timezone-based region pick with the Europe bbox.
- [x] **3.3** Harden: tolerate missing/renamed CAMS layers; capabilities parse never crashes the panel.
- ✅ Verify: `python3 cams.py init` populates a cache; `probe --layer composition_europe_pm2p5_forecast_surface --lat .. --lon ..` returns a value+unit; legend decode returns hex colours.

## 4. Air-quality overlay on the map

- [x] **4.1** `lib/CamsModel.js`: layer registry from `caps.json` (curated categories: air-quality, allergens, aerosols, UV; advanced tail for search), region-aware layer lists, AQ level bands.
- [x] **4.2** `ui/AirLayer.qml`: CAMS `GetMap` overlay tiles with `dim_time`, opacity slider, drawn over the shared map.
- [x] **4.3** `ui/Timeline.qml`: unified scrubber — radar past+nowcast frames and CAMS forecast steps in one model; opens nearest now; play paced to the network.
- [x] **4.4** `ui/LayerPicker.qml`: category chips (Radar / Air quality / Allergens / UV / Other search); Allergens disabled outside Europe; per-category layer checklist persisted.
- ✅ Verify: PM2.5 overlay renders on the map alongside radar; chips switch overlays; state survives restart.

## 5. Bar AQ readout

- [x] **5.1** Hourly `GetFeatureInfo` probe in `Service.qml` for the tracked layer at the home point (async, non-blocking).
- [x] **5.2** `BarWidget.qml`: AQ pill next to the radar icon — value + level colour, tooltip "PM2.5 6.4 µg/m³ · Low"; graceful "…" / error states.
- ✅ Verify: pill updates within an hour of enabling, or immediately on panel open when stale.

## 6. Alerts

- [x] **6.1** Port the storm-alert system into `Service.qml` + `lib/Alerts.js`: 10-min Open-Meteo poll, 5-point sampling, intensity bands, CAPE promotion, radius rings on the map, latch semantics.
- [x] **6.2** Add AQ alerts through the same latch: threshold on tracked layer (default PM2.5 > 35 µg/m³), evaluated against hourly CAMS forecast steps, escalate-only re-notify, re-arm below threshold.
- [x] **6.3** `ui/AlertControls.qml`: both switches, radius presets, thresholds; status line per upstream's "what the switch says" states; CLI-style notifications via `omarchy-notification-send` (Severe/Heavy/AQ breach stay on screen).
- ✅ Verify: alert fires once per event, escalates on worsening, re-arms after drop; all latch edge cases from upstream tests pass.

## 7. Tests

- [x] **7.1** `node --test` for all `lib/` files, including new `CamsModel.js` coverage (registry classification, region pick, AQ bands, forecast-step selection).
- [x] **7.2** Keep the stream-ceiling test green: add byte ceilings for any new endpoint (CAMS tiles/legends go through `cams.py`; document its limits).
- [x] **7.3** Keep text-format tests green: every `Text` declares `Text.PlainText`; notification bodies pass through inert-text.
- [x] **7.4** Shell-run tests under Quickshell where feasible (`first-run.sh` port; skip gracefully without `qs`).
- [x] **7.5** `qmllint -I /usr/share/omarchy/shell -I . *.qml ui/*.qml` clean (document known Panel.qml IpcHandler exception if it applies).
- ✅ Verify: full suite passes locally.

## 8. Docs & packaging

- [x] **8.1** README: install (`omarchy plugin add … --enable`), bar placement, usage, keyboard bindings, requirements (Omarchy Quattro, `python3`, `curl`), update note (`omarchy restart shell`), the "not a life-safety tool" disclaimer.
- [x] **8.2** Attribution section: RainViewer, Open-Meteo, Copernicus CAMS/ECMWF, Natural Earth, plus code credit to kūki and omarchy-weather-radar (both MIT).
- [x] **8.3** State contract: plugin writes only `~/.config/omarchy/akash/` and its shell.json entry; document removal steps.
- ✅ Verify: clean install on a scratch `$HOME` follows the README end to end.

## 9. Polish

- [ ] **9.1** Preview image for the plugin listing.
- [x] **9.2** Performance pass: tile decode stepped off the UI thread (port `basemap-steps.sh`), no stalls on panel open.
- [ ] **9.3** Publish repo; optional submission to omarchyplugins.com.
