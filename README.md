# Akash (อากาศ) for Omarchy

**Akash** (อากาศ) is Thai for "sky", from the Sanskrit *ākāśa* — sky, space, or
ether.

Live weather radar and air quality on one map, in the [Omarchy](https://omarchy.org)
bar. Click the bar icon for a map centred on your location — scrub through the
last two hours of precipitation, overlay the Copernicus CAMS forecast for
PM2.5, pollen or UV on the same ground, and optionally be told when a storm or
a pollution episode is on its way.

No account, no API key.

> **Not a life-safety tool.** This plugin is informational. It shows
> best-effort third-party data with no availability guarantee, and it can be
> late, wrong, or silent. For decisions that matter, use your national weather
> service, your air-quality agency, and civil defence warnings.

## Install

```bash
omarchy plugin add https://github.com/rsoutar/akash.git --enable
```

The widget lands on the right of the bar: a radar scope with an air-quality
pill beside it. Consider moving it next to the stock weather widget, which
sits in the centre by default:

```bash
omarchy plugin enable akash --section center --after omarchy.weather
```

`--section` takes `left`, `center` or `right`, and `--before` works like
`--after`. Re-running `enable` rewrites the widget's entry, so move it before
tuning the settings rather than after.

### Updating

```bash
omarchy plugin update akash
omarchy restart shell
```

The restart is not optional. `omarchy plugin update` fetches the new code and
asks the shell to rescan, but an already-mounted service is not rebuilt from
it. Until the shell restarts, an update has changed the files on disk and
nothing else.

### Removing it

```bash
omarchy plugin remove akash
rm -rf ~/.config/omarchy/akash
```

The first command deletes the plugin and its entry in the bar. The second
deletes the CAMS caches the plugin owns — see
[What it writes](#what-it-writes). The stock weather widget's own state is
left alone.

### Requirements

- Omarchy Quattro (Quickshell shell)
- `python3` — standard library only, no packages to install
- `curl` — Omarchy already installs it

The base map needs nothing at all: it ships with the plugin as
`data/basemap.bin` and works with no network. The plugin also calls
`omarchy-weather-location` to store a chosen city and
`omarchy-notification-send` to raise an alert — both ship with Omarchy.

## The map

| | |
| --- | --- |
| Drag | pan |
| Wheel, `+` / `-` | zoom towards the pointer |
| Play button, `Enter` | play the timeline |
| `←` / `→` | step one frame |
| Crosshair button, `Home` | recentre on your location |
| `Tab` | move to the neighbouring bar panel |
| `Esc` | close |

The panel opens on your location and on the newest moment, every time —
radar on top of the air-quality layers you have enabled, one scrubber under
the map for both. Which view it opens on is a setting: **Open panel on** in
the widget's settings, Radar by default, or your last-used chip. While the
panel is open a new frame list arriving every ten minutes does not move you;
once you close it, the map asks for nothing.

An empty radar reads as "it is not raining", so the map says which of the two
it is: `Loading radar…` while frames are on their way, `Radar unavailable`
when fetching them failed, and "no radar coverage" where RainViewer has none.
Large parts of the world have no ground radar at all, and there an empty map
means "nothing is known" rather than "nothing is falling".

Radar tiles stop at zoom level 7, about 1.1 km per pixel; the map goes to 9
anyway, so past 7 the ground keeps sharpening while the radar is scaled up
over it — which shows plainly where the radar's data ran out. The ground
itself is Natural Earth at 1:10 million, drawn from data in the repository,
so the map follows your Omarchy theme and works offline.

## Air quality

The second half of the map is the Copernicus Atmosphere Monitoring Service
(CAMS) forecast, served as overlay tiles through the plugin's Python helper.
The chips at the top of the panel switch between:

- **Air quality** — PM2.5, PM10, O₃, NO₂, SO₂, CO
- **Allergens** — birch, grass, ragweed, olive, alder, mugwort (Europe only;
  the chip is disabled elsewhere)
- **Aerosols** — total AOD, dust, wildfire smoke, sea salt, sulphate
- **UV** — the UV index
- **Other** — a search over the ~95 public CAMS layers, including the
  technical ones

Inside Europe the map uses CAMS's high-resolution regional forecast;
everywhere else it falls back to the coarser global model, picked from your
system timezone — no location picker involved. Layer selections per category
survive across panel opens for the session, and the last-used chip is
persisted in the widget's settings (the **Open panel on** setting reads it as
"Last used").

### The bar pill

Next to the radar scope, the bar shows the current value of your tracked
layer — PM2.5 by default — at your home point, coloured by its EEA air-quality
band. Hover for the full reading: "PM2.5 6.4 µg/m³ · Good". The probe runs
hourly while the widget lives, and immediately on opening the panel when the
reading has gone stale.

The bands are the standard EEA index cut-offs per species, so "Poor" means
the right concentration whatever the layer: PM2.5 reaches Poor at 25 µg/m³,
NO₂ at 90, O₃ at 120. The thresholds travel with the species, not the number.

## Location

Click the city name at the bottom of the panel and type to search.

The picker is the stock weather widget's — same geocoding, same suggestions —
and it writes to the same file, so a city chosen here moves the stock weather
widget too, and one chosen there moves the radar. Both watch the file, so
neither needs a restart. The location lives in
`~/.local/state/omarchy/settings/weather.json`, owned by
`omarchy-weather-location`; clearing it returns the weather widget to IP
auto-detection.

In a large city, name your neighbourhood rather than the city — the picker
resolves Tatuapé, Vila Mariana and the rest, and separates them from their
namesakes elsewhere.

## Alerts

Alerts are **off by default**, both of them. Turn them on from the switches
in the panel, or in the widget's settings.

**Storm alerts** watch the Open-Meteo forecast every ten minutes out to a
radius of your choosing — 100 km by default, roughly two hours of warning at
the speed storms travel — and notify when rain of at least your threshold is
forecast to reach you. Heavy (7.6 mm/h) is the default threshold, and rain
arriving into an unstable airmass counts one band up, so a storm crosses it
sooner than steady rain of the same rate. The radius draws its rings on the
map.

**Air-quality alerts** watch the tracked layer's hourly CAMS forecast at your
home point and notify when it reaches your chosen band — Poor by default —
now or in the next few forecast hours.

Both share the same discipline: you are not told twice about the same thing.
An alert speaks again only if conditions get *worse*, and re-arms when the
outlook drops back under your threshold. A storm parked overhead for three
hours is one notification, not eighteen. Severe, Heavy and air-quality breach
notifications stay on screen until dismissed; lighter ones time out.

## What it writes

The plugin writes only two places:

- `~/.config/omarchy/akash/` — `caps.json`, a cache of the CAMS layer
  list refreshed at most every 6 hours, and `state.json`, your chosen layers
  and view.
- Its entry in `~/.config/omarchy/shell.json` — bar placement and widget
  settings, managed by the `omarchy` CLI.

It reads `~/.local/state/omarchy/settings/weather.json` for your location but
never writes it; that file belongs to the stock weather widget. Nothing else
is written anywhere.

## Data sources

- Radar imagery: [RainViewer](https://www.rainviewer.com) — best-effort, no SLA
- Forecast and geocoding: [Open-Meteo](https://open-meteo.com)
- Air quality, pollen, aerosols and UV: Copernicus
  [CAMS](https://atmosphere.copernicus.eu/) via the public ECMWF WMS
- Base map: [Natural Earth](https://www.naturalearthdata.com/) 1:10m, public
  domain, shipped with the plugin as `data/basemap.bin`

## Development

Symlink a checkout into the plugin directory and the shell picks it up, so
the source can live wherever you keep your projects:

```bash
ln -s ~/Projects/akash ~/.config/omarchy/plugins/akash
omarchy-shell shell rescanPlugins
omarchy plugin enable akash
omarchy plugin validate .
```

**After editing any QML, restart the shell:**

```bash
omarchy restart shell
```

Quickshell's hot reload is deliberately off in Omarchy, and an edit that
appears to do nothing is usually an edit that was never loaded.

### Tests

Everything that is a plain function lives in `lib/` and is tested with Node's
own runner; `cams.py` is tested with the standard library's `unittest`:

```bash
node --test
python3 test/cams.test.py
```

`test/streams.test.js` holds the QML sources to a written-down inventory of
everything that reaches the shell process, and to a ceiling on each — a
plugin runs inside the process that owns the bar, the panels and the lock
screen, so a stream added later without a limit fails the suite rather than
turning up in a review. `test/qml-source.test.js` is the same kind of check
aimed at the QML: every `Text` declares `Text.PlainText`, and notification
bodies are made inert first. `test/cams.test.py` pins the Python helper's
byte ceilings and its tolerance of renamed CAMS layers.

The rest run the QML itself, under Quickshell rather than in Node. They skip
where there is no `qs`, and `AKASH_REQUIRE_QS=1` turns that skip into a
failure:

```bash
./test/first-run.sh       # a machine that has never set a weather location
./test/basemap-steps.sh   # decoding the ground never stalls the shell
./test/legend.qml-test.sh # the map legend compiles and renders its two ramps
```

QML is also checked statically, which needs the shell's modules on the import
path:

```bash
qmllint -I /usr/share/omarchy/shell -I . *.qml ui/*.qml
```

## Credits

Akash is two plugins folded into one, and would not exist without either:

- [kūki](https://github.com/cossssmin/kuki) by cossssmin — the air-quality
  half: the CAMS integration, the categories, the region logic and the
  Python helper are all built on its approach. MIT.
- [omarchy-weather-radar](https://github.com/eduardodallecort/omarchy-weather-radar)
  by eduardodallecort — the radar half: the map, the basemap, the alert
  system and the testing discipline are carried over from it. MIT.

Both served as direct inspiration, and large parts of this plugin are their
code, adapted to share one map.

## Licence

MIT. See [LICENSE](LICENSE).
