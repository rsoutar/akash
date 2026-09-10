// CAMS data model: layer registry, forecast time steps, GetMap URLs and the
// air-quality level bands.
//
// Everything here is a pure function over plain values, so the QML layers stay
// thin and the parts that are easy to get subtly wrong — a time dimension that
// expands forever, a bbox that straddles the antimeridian, a species band
// table — are pinned by test/cams-model.test.js.
//
// The registry is written by cams.py (see that file for the cache layout);
// this library only reads it.
//
// API reference: https://eccharts.ecmwf.int (public WMS, token=public)

.pragma library

.import "TileMath.js" as TileMath

// ---------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------

var WMS_BASE = "https://eccharts.ecmwf.int/wms/?token=public"

// ---------------------------------------------------------------------------
// Layer registry
// ---------------------------------------------------------------------------

// Chip order. "advanced" is the long tail reachable through the search —
// everything CAMS publishes that the curation tables do not name. It is
// deliberately last, and never a default.
var CATEGORY_ORDER = ["air-quality", "allergens", "aerosols", "uv", "advanced"]

var CATEGORY_LABELS = {
  "air-quality": "Air quality",
  "allergens": "Allergens",
  "aerosols": "Aerosols",
  "uv": "UV",
  "advanced": "Other"
}

// Legend end labels per category. All these layers measure a concentration or
// index where higher = more of the thing, but a bare "Low/High" is ambiguous
// (low air *quality* reads as bad, low *pollen* reads as good), so name what
// the ends actually mean. Higher is consistently the worse/heavier end.
var LEGEND_END_LABELS = {
  "air-quality": { low: "Cleaner", high: "More polluted" },
  "allergens": { low: "Less pollen", high: "More pollen" },
  "aerosols": { low: "Clearer", high: "Hazier" },
  "uv": { low: "Low UV", high: "Extreme UV" }
}

// Display order within a category, keyed by the `species` tag cams.py writes.
// Layers a sort key does not name keep registry order, after the sorted ones.
var SPECIES_ORDER = {
  "air-quality": ["pm2p5", "pm10", "o3", "no2", "so2", "co"],
  "allergens": ["birch", "grass", "ragw", "alder", "olive", "mugwort"],
  "aerosols": ["aod550", "duaod550", "bbaod550", "ssaod550", "suaod550"],
  "uv": ["uvindex", "uvindex_daily_max", "uvindex_clearsky", "uvindex_clearsky_daily_max"]
}

function findLayer(caps, name) {
  var layers = caps && caps.layers ? caps.layers : []
  for (var i = 0; i < layers.length; i++) {
    if (layers[i].name === name) return layers[i]
  }
  return null
}

// Whether a layer belongs in this region's picker. "europe" layers are
// regional high-res and exist only there; "global" layers are the coarse
// fallback and exist only outside Europe; "any" layers are worldwide. cams.py
// tags each layer; the region word comes from the state file.
function layerAppliesToRegion(layer, region) {
  if (!layer) return false
  if (layer.region === "any") return true
  return layer.region === region
}

function layersForCategory(caps, category, region) {
  var layers = caps && caps.layers ? caps.layers : []
  var order = SPECIES_ORDER[category] || []
  var matched = []
  for (var i = 0; i < layers.length; i++) {
    var layer = layers[i]
    if (layer.category !== category) continue
    if (!layerAppliesToRegion(layer, region)) continue
    var rank = order.indexOf(layer.species)
    matched.push({ rank: rank === -1 ? order.length : rank, index: matched.length, layer: layer })
  }
  matched.sort(function(a, b) {
    if (a.rank !== b.rank) return a.rank - b.rank
    return a.index - b.index
  })
  return matched.map(function(entry) { return entry.layer })
}

// The categories a region's chips offer, in display order. Allergens is
// Europe-only pollen — a global user would otherwise get a tab whose layers
// are all filtered away. A category (including the advanced tail) with no
// layers at all is not offered: an empty tab is not an interface.
function categoriesFor(caps, region) {
  var out = []
  for (var i = 0; i < CATEGORY_ORDER.length; i++) {
    var id = CATEGORY_ORDER[i]
    if (id === "allergens" && region !== "europe") continue
    if (layersForCategory(caps, id, region).length === 0) continue
    out.push(id)
  }
  return out
}

// Drop the "(provided by CAMS, …)" attribution the WMS appends to every title.
function cleanTitle(title) {
  return String(title || "").replace(/\s*\(provided by[^)]*\)\s*$/i, "").trim()
}

function layerLabel(layer) {
  return cleanTitle(layer ? layer.title : "") || (layer ? layer.short : "") || ""
}

// ---------------------------------------------------------------------------
// Forecast time steps
// ---------------------------------------------------------------------------

// Parse an ISO8601 duration like "PT3H", "PT1H", "P1D" into milliseconds.
// CAMS only uses hour/day periods, so a small subset is enough.
function durationMs(period) {
  var match = /^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?$/.exec(String(period || ""))
  if (!match) return 0
  var days = Number(match[1] || 0)
  var hours = Number(match[2] || 0)
  var minutes = Number(match[3] || 0)
  return ((days * 24 + hours) * 60 + minutes) * 60 * 1000
}

// A pathological dimension — a fine period over a long window — would expand
// into more steps than any timeline can use and freeze the shell building the
// list. Measured: the real Europe layers expand to a few hundred steps at
// most, so this ceiling is far above what CAMS actually publishes.
var MAX_STEPS = 4000

// Expand a WMS time Dimension string into an array of ISO timestamps.
// The string is comma-separated tokens; each token is either a single instant
// or a "start/end/period" interval, e.g.
//   "2026-08-12T03:00:00Z,2026-08-12T06:00:00Z/2026-08-21T00:00:00Z/PT3H"
function expandTimes(dimension) {
  var out = []
  var tokens = String(dimension || "").split(",")
  for (var t = 0; t < tokens.length; t++) {
    var token = tokens[t].trim()
    if (!token) continue
    if (token.indexOf("/") === -1) {
      out.push(token)
      continue
    }
    var parts = token.split("/")
    if (parts.length < 3) { out.push(parts[0]); continue }
    var start = Date.parse(parts[0])
    var end = Date.parse(parts[1])
    var step = durationMs(parts[2])
    if (!isFinite(start) || !isFinite(end) || step <= 0) { out.push(parts[0]); continue }
    for (var ms = start; ms <= end && out.length < MAX_STEPS; ms += step) {
      out.push(new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z"))
    }
  }
  return out
}

// The step list for a layer, empty when the cache has no dimension for it —
// which is a tolerable state the UI shows as a single "now" step, not an error.
function layerSteps(layer) {
  if (!layer) return []
  return expandTimes(layer.time)
}

// Index of the step closest to `nowMs` (defaults to the current time), so
// opening a layer lands on ~now rather than on the analysis time.
function nearestTimeIndex(times, nowMs) {
  if (!times || times.length === 0) return 0
  var now = isFinite(nowMs) ? nowMs : Date.now()
  var best = 0, bestDiff = Infinity
  for (var i = 0; i < times.length; i++) {
    var diff = Math.abs(Date.parse(times[i]) - now)
    if (diff < bestDiff) { bestDiff = diff; best = i }
  }
  return best
}

// Short human label for a forecast valid time, in the local timezone. Day is
// named because a forecast spans midnight, and "--" alone on a forecast does
// not say which day it means.
function formatStepTime(iso) {
  var ms = Date.parse(iso)
  if (!isFinite(ms)) return String(iso || "")
  var d = new Date(ms)
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  var hh = ("0" + d.getHours()).slice(-2)
  var mm = ("0" + d.getMinutes()).slice(-2)
  return days[d.getDay()] + " " + d.getDate() + " · " + hh + ":" + mm
}

// ---------------------------------------------------------------------------
// WMS URLs
// ---------------------------------------------------------------------------

// EPSG:3857 metres. The WMS asks for a bbox in map metres, not degrees, and
// for EPSG:3857 the axis order is easting,northing. Northing is positive
// north — this is not tile space, where y grows south.
var MERCATOR_SPAN = 2 * Math.PI * 6378137.0

function lonToMercX(lon) {
  var l = ((lon + 180) % 360 + 360) % 360 - 180
  return l / 180 * (MERCATOR_SPAN / 2)
}

function latToMercY(lat) {
  var clamped = Math.max(-85.05112878, Math.min(85.05112878, lat))
  var s = Math.sin(TileMath.toRadians(clamped))
  // atanh(sin φ) = ln(tan(π/4 + φ/2)) — the standard Web Mercator northing.
  return (MERCATOR_SPAN / (2 * Math.PI)) * 0.5 * Math.log((1 + s) / (1 - s))
}

// The exact viewport rectangle to request as a single GetMap overlay.
//
// A view straddling the antimeridian unprojects to a west corner east of its
// east corner; WMS bboxes are min-first, so the east edge is shifted a world
// east — the linear projection makes that the same strip of map — rather than
// letting the request come back empty.
function viewportBbox(centerLat, centerLon, zoom, width, height) {
  var west = TileMath.unprojectFromViewport(0, 0, centerLat, centerLon, zoom, width, height)
  var east = TileMath.unprojectFromViewport(width, height, centerLat, centerLon, zoom, width, height)

  var minx = lonToMercX(west.longitude)
  var maxx = lonToMercX(east.longitude)
  if (maxx < minx) maxx += MERCATOR_SPAN

  return {
    minx: minx,
    miny: latToMercY(east.latitude),
    maxx: maxx,
    maxy: latToMercY(west.latitude)
  }
}

// Build a WMS 1.3.0 GetMap URL for the overlay. For EPSG:3857 the axis order
// is easting,northing, so bbox = minx,miny,maxx,maxy.
function mapUrl(layer, style, bbox, width, height, dimTime) {
  var params = [
    "service=WMS", "version=1.3.0", "request=GetMap",
    "layers=" + encodeURIComponent(layer),
    "styles=" + encodeURIComponent(style || ""),
    "crs=EPSG:3857",
    "bbox=" + [bbox.minx, bbox.miny, bbox.maxx, bbox.maxy].join(","),
    "width=" + Math.round(width), "height=" + Math.round(height),
    "format=image/png", "transparent=true"
  ]
  if (dimTime) params.push("dim_time=" + encodeURIComponent(dimTime))
  return WMS_BASE + "&" + params.join("&")
}

function legendUrl(layer, style) {
  return WMS_BASE + "&" + [
    "request=GetLegend",
    "layers=" + encodeURIComponent(layer),
    "styles=" + encodeURIComponent(style || ""),
    "width=350", "height=50", "format=image/png"
  ].join("&")
}

// ---------------------------------------------------------------------------
// Air-quality level bands
// ---------------------------------------------------------------------------

// EEA-style bands per species, low→high. Higher is always worse. Used by the
// bar pill's colour and (later) the air-quality alert threshold; the values
// are the standard index cut-offs in the layer's own unit.
var BAND_NAMES = ["Good", "Fair", "Moderate", "Poor", "Very poor", "Extremely poor"]

var BAND_COLORS = [
  "#50f0e6", "#50ccaa", "#f0e641", "#ff5050", "#960032", "#7d2181"
]

var AQ_BANDS = {
  "pm2p5": [10, 20, 25, 50, 75],
  "pm10": [15, 30, 45, 60, 90],
  "o3": [60, 100, 120, 160, 200],
  "no2": [30, 60, 90, 120, 180],
  "so2": [100, 200, 350, 500, 750],
  "co": [2000, 4000, 8000, 10000, 15000]
}

function aqBandIndex(species, value) {
  var thresholds = AQ_BANDS[species]
  if (!thresholds || !isFinite(value)) return -1
  for (var i = 0; i < thresholds.length; i++) {
    if (value < thresholds[i]) return i
  }
  return thresholds.length
}

function aqLevel(species, value) {
  var band = aqBandIndex(species, value)
  if (band < 0) return null
  return { band: band, name: BAND_NAMES[band], color: BAND_COLORS[band] }
}

// The worst band across a set of readings — how the bar pill answers when the
// user tracks a species that is fine while another is not, and later how the
// air-quality alert escalates.
function worstBand(values) {
  var worst = -1
  for (var i = 0; i < values.length; i++) {
    var band = values[i]
    if (band > worst) worst = band
  }
  return worst
}

// The legend the map paints for a CAMS layer: one band per EEA rung, named and
// coloured from the tables above, low→high. `category` is the chip id, which
// picks which end labels the legend shows — air quality reads "Cleaner /
// More polluted", Allergens "Less pollen / More pollen", and so on. A category
// with no declared ends (the advanced tail) still names the bands; an air
// legend without its ends would be a scale without its names.
function legendEnds(category) {
  var ends = LEGEND_END_LABELS[category]
  return ends ? ends : LEGEND_END_LABELS["air-quality"]
}

// The six EEA rungs in display order, each with its colour and its index.
function airQualityLegend() {
  var rows = []
  for (var i = 0; i < BAND_NAMES.length; i++) {
    rows.push({ name: BAND_NAMES[i], color: BAND_COLORS[i], index: i })
  }
  return rows
}

// The legend's text, read as three levels rather than six rungs. The bar keeps
// its six EEA colours; the words pair adjacent bands so each label sits in an
// equal third the way the radar legend's do, and take the word a person would
// actually use rather than the EEA's stacked intensifiers ("Poor", not "Very
// poor", at the top). Same labels for every category: the ends already say what
// the scale measures.
var LEGEND_TIER_NAMES = ["Good", "Moderate", "Poor"]

function legendTiers() {
  var tiers = []
  for (var i = 0; i < LEGEND_TIER_NAMES.length; i++) {
    tiers.push({ name: LEGEND_TIER_NAMES[i], index: i })
  }
  return tiers
}
