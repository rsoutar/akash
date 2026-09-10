# Akash — plan

**One Omarchy Quattro (Quickshell) plugin: live weather radar + Copernicus CAMS air quality on a single map, with an AQ bar readout and storm + air-quality alerts. No API keys, no accounts.**

Based on (both MIT-licensed, credited in README):

- [kuki](https://github.com/cossssmin/kuki) — CAMS air-quality/pollen/UV forecast maps
- [omarchy-weather-radar](https://github.com/eduardodallecort/omarchy-weather-radar) — RainViewer radar, offline Natural Earth basemap, storm alerts

## Design decisions

| Decision | Choice |
|---|---|
| Panel layout | **One map, layer toggles** — RainViewer radar and CAMS overlays stack on the same map; category chips: Radar / Air quality / Allergens / UV |
| Bar widget | **AQ readout + radar icon** — radar-scope icon plus a small AQ pill (chosen layer, default PM2.5) coloured by level, tooltip like "PM2.5 6.4 µg/m³ · Low"; probed hourly |
| Alerts | **Storm + air quality**, off by default, same latch semantics as the radar plugin |
| Basemap | **Offline Natural Earth** compiled to `data/basemap.bin`, drawn by the plugin (no tile server, theme-aware) |
| Helper language | **Python 3, stdlib only** (`cams.py`) — matches kuki; `python3` is guaranteed on Omarchy, no build step, the helper is I/O-bound |

## How the upstream plugins get their data (research notes)

### kūki — Copernicus CAMS via the public ECMWF WMS

- Endpoint: `https://eccharts.ecmwf.int/wms/?token=public` — no key.
- A Python helper (`cams.py`, stdlib only) does all network work:
  - `GetCapabilities` (≈600 KB namespaced XML) → parsed into `composition_*` layers (name, title, default time, time dimension, styles), classified into curated categories; cached to `~/.config/omarchy/kuki/caps.json` with a **6 h TTL**.
  - Map overlays: WMS `GetMap` tiles with a `dim_time` forecast step.
  - Region pick: Europe high-res `composition_europe_*` layers vs coarser global `composition_*`, chosen from the system timezone's coordinates (`/usr/share/zoneinfo/zone1970.tab`) against a Europe bbox — fully offline.
  - Point values (bar tooltip): WMS `GetFeatureInfo` at home lat/lon — small EPSG:3857 box (~20 km half-box), centre pixel, parse `Value: <num> <unit>` from `text/plain`.
  - Legends: `GetLegend` PNG, decoded with a hand-rolled PNG reader to a discrete hex-colour swatch strip.
- State in `~/.config/omarchy/kuki/state.json`; plugin touches nothing else.
- Basemap: CARTO tiles (needs network) — Akash deliberately does **not** copy this.

### omarchy-weather-radar — RainViewer + Open-Meteo

- Radar manifest: `https://api.rainviewer.com/public/weather-maps.json` → tile `host` + frame paths for the past 2 h (`radar.past`) + nowcast (`radar.nowcast`). Frames are XYZ tiles: `{host}{path}/{size}/{z}/{x}/{y}/{color}/{smooth}_{snow}.png`, radar useful to **z7** (~1.1 km/px). A coverage-mask tile answers "is there ground radar here". Polled every **10 min** while the panel is open; tile images cached by URL; no requests while closed.
- Forecast/alerts: `https://api.open-meteo.com/v1/forecast` with `minutely_15=precipitation,precipitation_probability`, `hourly=cape,wind_gusts_10m`. Five sample points (centre + four at 5 km) travel in **one** request. Poll every **15 min**. Intensity bands (Light 0.3 / Moderate 2.5 / Heavy 7.6 / Severe 15 mm/h) and a promotion rule: moderate+ raises one band when CAPE ≥ 2000 J/kg, or CAPE ≥ 1000 with gusts ≥ 45 km/h. Radius presets 50–200 km convert to lead time at 50 km/h; the radius draws the alert rings and sets how far ahead is inspected. Latch: one notification per event, re-notify only on escalation, re-arm below threshold.
- Geocoding: `https://geocoding-api.open-meteo.com/v1/search` — same endpoint/shape as the stock weather widget.
- Location: shared file `~/.local/state/omarchy/settings/weather.json` owned by `omarchy-weather-location`; watched, with a `reloadLocation()` call after saves because a fresh home directory defeats the inotify watch (first-run edge case, pinned by their test).
- Basemap: offline — Natural Earth 1:10m/1:50m simplified and quantised into `data/basemap.bin` (~2.6 MB) by `tools/build-basemap.py`; format documented in the generator, decoded by `lib/Basemap.js`, both pinned by tests.
- All network via `curl -fsS --max-time --max-filesize` with per-endpoint byte ceilings (manifest 64 KB, geocoding 64 KB, forecast 256 KB) — enforced during transfer, exit 63 on overrun.
- `lib/` files are `.pragma library` pure JS, tested with `node --test` after stripping QML directives; plus stream-ceiling and `Text.PlainText` source tests, and shell-run tests under Quickshell.
- Polling belongs only in `Service.qml` (mounted once per plugin), never in `BarWidget.qml` (one per monitor).

## Architecture

```
akash/
  manifest.json
  BarWidget.qml          # radar-scope icon + AQ pill (value, level colour, tooltip)
  Panel.qml              # panel state/lifecycle, IPC handler
  Service.qml            # headless singleton: radar manifest, forecast poll,
                         # AQ probe, alert latch
  cams.py                # adapted from kuki: capabilities cache, GetFeatureInfo
                         # probe, legend decode — Python 3 stdlib only
  ui/MapCanvas.qml       # shared map: basemap + radar layer + AQ overlay
  ui/RadarLayer.qml      # RainViewer XYZ tiles + coverage probe
  ui/AirLayer.qml        # CAMS GetMap overlay, opacity slider
  ui/Timeline.qml        # scrubber/play — radar past+nowcast and CAMS forecast steps
  ui/LayerPicker.qml     # category chips + per-category layer checklist
  ui/LocationPicker.qml  # shared weather.json city search
  ui/AlertControls.qml   # storm + AQ switches, radius, thresholds
  lib/TileMath.js        # Web Mercator, distance, bearing (from radar plugin)
  lib/RadarModel.js      # RainViewer endpoints, parsing (from radar plugin)
  lib/CamsModel.js       # layer registry, region pick, AQ level bands
  lib/Alerts.js          # storm bands (upstream) + AQ bands + shared latch
  lib/Settings.js        # reading/coercing widget settings
  lib/Basemap.js         # decodes data/basemap.bin (from radar plugin)
  lib/Glyphs.js          # Nerd Font glyphs
  data/basemap.bin       # committed; built by tools/build-basemap.py
  tools/build-basemap.py # from radar plugin, unchanged
  test/                  # node --test on lib/ + stream/text-format source tests
```

## Behaviour

- **One map, stacked layers.** Category chips switch overlay family; within Air quality the user ticks pollutants (PM2.5, PM10, O₃, NO₂, SO₂, CO). Allergens tab is disabled outside the CAMS Europe bbox (same timezone check as kuki). Radar and a CAMS layer can be shown together with an opacity slider.
- **Timeline** covers radar past+nowcast and CAMS forecast steps; play auto-advances paced to the network; opens on the step nearest now.
- **Bar widget**: radar-scope icon + AQ pill. AQ value from hourly `GetFeatureInfo` at the home point; colour from CAMS level bands. Tooltip: "PM2.5 6.4 µg/m³ · Low".
- **Alerts (both off by default)** share one latch/notification path (`omarchy-notification-send`):
  - *Storm*: upstream bands, 5-point sampling, CAPE promotion, radius rings.
  - *Air quality*: threshold on the tracked layer at the home point (default PM2.5 > 35 µg/m³), evaluated against the hourly CAMS forecast steps; notify once, escalate-only re-notify, re-arm when the level drops back.
- **Location** shared with the stock weather widget via `weather.json` + `omarchy-weather-location`; both directions stay in sync by file watch + reload-on-save.
- **State**: plugin-owned files only, under `~/.config/omarchy/akash/` (`state.json`, `caps.json`).
- **Requests**: `curl` with per-endpoint byte ceilings; the Python helper handles the XML and `GetFeatureInfo` paths. Polling only in `Service.qml`.

## Data & attribution

- Radar imagery: [RainViewer](https://www.rainviewer.com) — best-effort, no SLA
- Forecast + geocoding: [Open-Meteo](https://open-meteo.com)
- Air quality/pollen/UV: Copernicus CAMS via the public ECMWF WMS (`eccharts.ecmwf.int`, `token=public`)
- Basemap: Natural Earth 1:10m/1:50m (public domain), bundled as `data/basemap.bin`
- Code heritage: kūki (MIT) and omarchy-weather-radar (MIT) — credited in README

## Risks / notes

- CAMS `GetFeatureInfo` can take seconds — probe asynchronously, never block panel open.
- CAMS layer names can change — capabilities parsing must tolerate missing layers (kuki's approach).
- Radar z7 limit + Natural Earth z9 cap carried over from upstream; "no radar coverage" is stated explicitly, empty radar ≠ clear sky.
- The radar plugin notes `omarchy plugin update` does not rebuild a mounted service — docs must say `omarchy restart shell` after updates.
- QML `Text` must declare `Text.PlainText`; place names reaching notification bodies go through an inert-text helper (upstream security test keeps this honest).
