# Akash design

How a change, feature, or fix should behave.

[README.md](README.md) is install and use. [manifest.json](manifest.json) is
the settings schema. [SKILL.md](SKILL.md) is the operating manual. Honor these;
ask before violating them.

## Picture

Weather occupies the view. Geographic detail stays quiet: a Natural Earth
1:10 m basemap drawn in the theme's line weight, sparse labels, rings for the
alert radius, a crosshair, a timeline. Chrome — the bar pill, the panel —
follows the Omarchy theme.

Radar colours come from one place: the `COLOR_SCHEMES` table in
`lib/RadarModel.js`, selected by the widget's `colorScheme` setting and applied
to every radar tile request. Air-quality colours come from the EEA band tables
— `BAND_NAMES`/`BAND_COLORS` in `lib/CamsModel.js`, `AQ_BAND_NAMES` in
`lib/Alerts.js` — which the map, the bar pill and the notification all derive
from. The bar pill does not paint with the EEA pastels, which wash out on
light themes: it signals severity with the theme's `Color.accent` and
`Color.urgent`, and its tooltip names the band exactly. A colour change to
either table is shown with a capture, not described.

Show actual frame and timeline times. The timeline stamp shows the frame's
own clock (`ui/Timeline.qml`), plus "35 min ago" when a radar frame sits
behind the newest. An empty map is ambiguous, so the plugin says which it is:
the header's "Fetching" while frames are on their way, "Radar unavailable" on
the map when fetching them failed, and "· no radar coverage" where the
coverage probe found no ground radar. A clear sky is a real radar image that
shows nothing falling; an empty map in a radar-free part of the world means
"nothing is known", not "nothing is falling".

The panel's top line (`ui/PanelHeader.qml`) carries the plugin's name and its
live state: a terminal-style blinking dot, green and reading "Live" when idle,
orange and reading "Fetching" while any request is in flight. The green and
orange are fixed literals because the theme palette exposes no such roles; the
name and label stay on the theme's foreground. This is the panel's only status
readout — the map does not repeat it. "Fetching" tracks real requests — the
service's polls, a location save, and the CAMS overlay's GetMap — not radar
tile rendering: those tiles are cached by URL and merely re-decode when a chip
returns to Radar, so counting them would blink the header on every switch.
Work that finishes inside half a second is ignored too, so a fast request does
not flash the label.

Keep attribution: data credits (RainViewer, Open-Meteo, Copernicus
CAMS/ECMWF, Natural Earth) in README's data-sources section, and code credits
(kuki, omarchy-weather-radar) in README's credits and in LICENSE.

## Location, onboarding, and map

The map centre comes from exactly one source: Omarchy's shared weather
location, `~/.local/state/omarchy/settings/weather.json`, read read-only and
watched through a `FileView` in the service. There is deliberately no parallel
store: widget settings (the shell.json entry) hold preferences and the
last-used view, and `state.json` holds CAMS session restore, and neither is a
centre. The file Omarchy's weather widget owns is the single source of truth,
so the two widgets agree by construction rather than by reconciliation.

The bar's air-quality probe falls back, when weather.json has no coordinates,
to `state.json`'s `home` — a country-level value from the timezone, better
than none — and then to no reading. A saved location name without coordinates
is its own state, "unresolved", and is reported rather than dropped: the
picker prints "· no coordinates — pick one from the list", and the alert
status says "the saved location has no coordinates".

The picker is the stock weather widget's — same geocoding, same
`omarchy-weather-location` CLI. Choosing a city there writes weather.json
through that CLI; the watch re-centres the radar live. The plugin never
writes Omarchy, Hyprland or system configuration outside its own shell.json
entry.

Refresh, and new frame lists arriving while the panel is open, never move the
viewport or reset the camera. The timeline remembers the moment the user was
looking at (`lib/Frames.js`), not the index, and re-places it as the list
moves underneath. Closing preserves the session: the panel object stays
mounted, so the chosen zoom, the last-used view and the followed time all
survive a close. Reopening then starts "about now" — centred on the location,
on the newest frame — because opening is a question about now; while open,
scrubbing and panning are never disturbed by an arriving frame list.

## Split

All network, polling, and alert state lives in `Service.qml`, mounted once per
plugin; a bar widget is instantiated per monitor and a service is not, so
two monitors never double a request. The widget and the panel bind to the
service's summary properties; they poll nothing themselves.

`lib/*.js` are pure functions over plain values, one concern each, pinned by
`node --test`. Anything that is not a pure function does not belong there.

`cams.py` is the isolated CAMS/network helper: the capabilities cache
(`caps.json`, refreshed at most every 6 hours), the WMS `GetFeatureInfo`
probe, region-from-timezone, and per-endpoint byte ceilings (1 MiB
capabilities, 4 KiB probe, 64 KiB legend) enforced mid-stream. Every process
that reads stdout back into the shell process is bounded the same way, and
`test/streams.test.js` pins each stream and its ceiling.

Deliberate preferences live in the widget's shell.json entry, managed by the
`omarchy` CLI; session restore lives in `~/.config/omarchy/akash/state.json`,
written atomically (temp file, fsync, rename) by cams.py. A setting the code
cannot act on is named rather than silently defaulted: an unrecognised band
name falls back to the default but is reported, and an alert radius outside
the presets is added to the list rather than dropped.

## Scope

Keep the feature set small. Prefer stock integrations — the shared weather
location, `omarchy-weather-location`, `omarchy-notification-send`, the
first-party bar APIs — over parallel mechanisms inside this plugin. If a
visual call is open, change the running picture and look at it.

## Future direction

A Rust engine in the omastorm style — a release binary, sha256-pinned, run as
a daemon the shell talks to — is the right path only if a raw local-decode
data source is ever added: a national high-resolution radar feed, or motion
analysis over frames. Only then does the decode cost justify a compiled
engine that decodes once and serves the shell by IPC. It is not warranted for
the current HTTP-tile sources, which the shell and cams.py already fetch
directly, and it is never to be started now.