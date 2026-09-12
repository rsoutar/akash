// RainViewer data model: URL construction, manifest and location parsing,
// forecast sampling and echo analysis.
//
// Everything here is a pure function over plain values, so the networking and
// rendering layers stay thin and the parts that are easy to get subtly wrong —
// a manifest that half-parses, a location carrying no coordinates, the
// reflectivity bands — are pinned by test/radar-model.test.js.
//
// The storm alert bands live in Alerts.js rather than here: these are
// reflectivity read off a radar image, those are rain rate read off a
// forecast.
//
// API reference: https://www.rainviewer.com/api/weather-maps-api.html

.pragma library

.import "TileMath.js" as TileMath

// ---------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------

var MANIFEST_URL = "https://api.rainviewer.com/public/weather-maps.json"
var FORECAST_URL = "https://api.open-meteo.com/v1/forecast"

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

// Every response is collected whole into the process that owns the bar, the
// panels and the lock screen, so every request carries a ceiling on bytes as
// well as on time. `--max-time` bounds only how long a transfer may run: a
// host that answers fast enough can send as much as the link carries for the
// whole window, and a captive portal or a hijacked name is an ordinary thing
// to meet on a laptop.
//
// Measured against the real endpoints, with room for them to grow: the
// RainViewer manifest is 766 bytes, a five-result geocoding answer 1,834, and
// a five-point forecast at the widest window this plugin asks for 9,269.
//
// curl enforces this during the transfer rather than only against a declared
// length — checked against a chunked 26 MB response, which it cut at the
// ceiling and left with exit 63.
var MANIFEST_MAX_BYTES = 65536
var GEOCODING_MAX_BYTES = 65536
var FORECAST_MAX_BYTES = 262144

// The one place a request is built, so that no call site can leave a ceiling
// off. `-f` makes an HTTP error an exit code rather than an error page parsed
// as data.
function fetchCommand(url, seconds, maxBytes) {
  return ["curl", "-fsS",
          "--max-time", String(seconds),
          "--max-filesize", String(maxBytes),
          url]
}

function manifestCommand() {
  return fetchCommand(MANIFEST_URL, 10, MANIFEST_MAX_BYTES)
}

// Open-Meteo takes several coordinates in one request and answers with an
// array, which is how five sample points around a town cost one call.
function forecastUrl(points, slots, hours) {
  var latitudes = []
  var longitudes = []
  for (var i = 0; i < points.length; i++) {
    latitudes.push(points[i].latitude.toFixed(4))
    longitudes.push(points[i].longitude.toFixed(4))
  }
  return FORECAST_URL
    + "?latitude=" + latitudes.join(",")
    + "&longitude=" + longitudes.join(",")
    + "&minutely_15=precipitation,precipitation_probability"
    + "&hourly=cape,wind_gusts_10m"
    + "&forecast_minutely_15=" + slots
    + "&forecast_hours=" + hours
    + "&timezone=auto"
}

function forecastCommand(points, slots, hours) {
  return fetchCommand(forecastUrl(points, slots, hours), 12, FORECAST_MAX_BYTES)
}

function geocodingCommand(query, count) {
  return fetchCommand(geocodingUrl(query, count), 5, GEOCODING_MAX_BYTES)
}

// RainViewer publishes a frame every 10 minutes. Polling faster only re-fetches
// bytes we already have, so this is the floor for every timer in the plugin.
var FRAME_INTERVAL_SEC = 600

// Open-Meteo's minutely_15 series is quarter-hourly, which is the finest the
// forecast can be different from what is already held. Named separately from
// the radar's cycle because they are different sources that happen to be close
// — borrowing one for the other is right until one of them changes.
var FORECAST_INTERVAL_SEC = 900

// RainViewer's tile pyramid stops at z7 (~1.1 km/px at mid latitudes). The
// endpoint serves deeper zooms, but they only upscale the same data.
//
// The map still goes past that, because the reason people zoom in is to find
// out which town sits under a storm, and the town comes from the basemap. So
// the radar layer keeps requesting z7 and is scaled up over ground that is
// still sharpening: honest about its own limit without holding the rest of the
// map hostage to it.
//
// It stops at z9 rather than going deeper because that is where the ground
// runs out too. The basemap is Natural Earth at 1:10 million, which is drawn
// for scales down to roughly 1:2 million; past z9 the coastline would be
// magnified beyond the accuracy it claims, over radar that was already being
// upscaled two levels earlier. A zoom level where neither layer has anything
// left to say is a zoom level that only looks like detail.
var MAX_RADAR_ZOOM = 7
var MIN_RADAR_ZOOM = 3
var MAX_MAP_ZOOM = 9

// The scheme documented as greyscale, kept for the id rather than for what it
// was believed to give.
//
// It does not return a greyscale tile. Measured 2026-08-30 at z7, the deepest
// zoom RainViewer serves: schemes 0 through 9 collapse to at most two distinct
// images — southern Brazil returned one for 0,1,2,3,7,8 and another for
// 4,5,6,9, while the US midwest and western Europe returned a single image for
// all ten — and every variant is fully coloured, with no greyscale pixels at
// all in any of the three. Values that are not schemes return a scheme's image
// too, so the parameter is inert or close to it.
//
// Nothing reads this. It is left because the id is still the id, and removed
// belief is cheaper to correct than absent belief is to rediscover.
var MEASUREMENT_SCHEME = 0

// Colour schemes offered to the user. IDs are RainViewer's; the names follow
// their published scheme list.
var COLOR_SCHEMES = [
  { id: 2, name: "TITAN" },
  { id: 4, name: "Meteored" },
  { id: 5, name: "NEXRAD Level III" },
  { id: 6, name: "Rainbow" },
  { id: 3, name: "The Weather Channel" },
  { id: 1, name: "Universal Blue" },
  { id: 7, name: "Dark Sky" },
  { id: 0, name: "Greyscale" }
]

function isKnownColorScheme(id) {
  for (var i = 0; i < COLOR_SCHEMES.length; i++) if (COLOR_SCHEMES[i].id === id) return true
  return false
}

function colorSchemeName(id) {
  for (var i = 0; i < COLOR_SCHEMES.length; i++) if (COLOR_SCHEMES[i].id === id) return COLOR_SCHEMES[i].name
  return "Unknown"
}

// ---------------------------------------------------------------------------
// URL construction
// ---------------------------------------------------------------------------

// Standard XYZ tile, used by the pannable map.
//   {host}{framePath}/{size}/{z}/{x}/{y}/{color}/{smooth}_{snow}.png
function tileUrl(host, framePath, size, zoom, x, y, colorScheme, smooth, snow) {
  if (!host || !framePath) return ""
  return host + framePath + "/" + size + "/" + zoom + "/" + x + "/" + y
    + "/" + colorScheme + "/" + (smooth ? 1 : 0) + "_" + (snow ? 1 : 0) + ".png"
}

// Coordinate-centred tile: the returned image is centred exactly on lat/lon
// rather than on a tile boundary. RainViewer documents this as the widget
// case, and it is what the alert samples — the centre pixel is the user's
// location by construction, so no grid arithmetic can drift.
function centeredTileUrl(host, framePath, size, zoom, lat, lon, colorScheme, smooth, snow) {
  if (!host || !framePath) return ""
  // The API requires a decimal point in both coordinates.
  return host + framePath + "/" + size + "/" + zoom + "/" + decimal(lat) + "/" + decimal(lon)
    + "/" + colorScheme + "/" + (smooth ? 1 : 0) + "_" + (snow ? 1 : 0) + ".png"
}

// Coverage mask: transparent where ground radar exists, opaque black where it
// does not. Lets the plugin say "no radar covers you" instead of showing an
// empty map that reads as a bug.
function coverageTileUrl(host, size, zoom, lat, lon) {
  if (!host) return ""
  return host + "/v2/coverage/0/" + size + "/" + zoom + "/" + decimal(lat) + "/" + decimal(lon) + "/0/0_0.png"
}

function decimal(value) {
  var text = String(Number(value))
  return text.indexOf(".") === -1 ? text + ".0" : text
}

// ---------------------------------------------------------------------------
// Manifest parsing
// ---------------------------------------------------------------------------

// Parse the weather-maps manifest into the shape the rest of the plugin uses.
// Returns null on anything unparseable so callers keep their previous state
// rather than blanking the map on one bad response.
function parseManifest(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null

  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!data || !data.radar) return null

  // Every tile and mask this plugin requests is built from `host`, so a
  // manifest that carried anything else would redirect all of them. Accepting
  // "a string" is not accepting a URL.
  if (!isTileHost(data.host)) return null

  var past = normalizeFrames(data.radar.past)
  if (past.length === 0) return null

  // `nowcast` carries short-range forecast frames. It has been observed empty
  // on the public endpoint, so it is optional throughout.
  var nowcast = normalizeFrames(data.radar.nowcast)

  return {
    host: data.host,
    generated: Number(data.generated) || 0,
    past: past,
    nowcast: nowcast,
    frames: past.concat(nowcast)
  }
}

// The manifest names the host its tiles come from. It must be a plain https
// origin: http would be a silent downgrade of everything that follows, and
// anything else is not somewhere to send a request at all.
function isTileHost(value) {
  if (typeof value !== "string") return false
  if (value.length === 0 || value.length > 256) return false
  if (value.indexOf("https://") !== 0) return false
  if (/[\s"'<>\\]/.test(value)) return false
  return value.length > "https://".length
}

function normalizeFrames(list) {
  if (!Array.isArray(list)) return []
  var frames = []
  for (var i = 0; i < list.length; i++) {
    var frame = list[i]
    if (!frame || typeof frame.path !== "string" || frame.path === "") continue
    var time = Number(frame.time)
    if (!isFinite(time) || time <= 0) continue
    frames.push({ time: time, path: frame.path })
  }
  frames.sort(function(a, b) { return a.time - b.time })
  return frames
}

function latestFrame(manifest) {
  // Checks the field rather than only the object: a caller can hold something
  // manifest-shaped that is not one of ours, and a missing `past` should read
  // as "no frames" rather than throw.
  if (!manifest || !manifest.past || manifest.past.length === 0) return null
  return manifest.past[manifest.past.length - 1]
}

// ---------------------------------------------------------------------------
// Location
// ---------------------------------------------------------------------------

// Omarchy stores the user's weather location in
// ~/.local/state/omarchy/settings/weather.json, owned by
// omarchy-weather-location. Reading the same file means the radar and the
// stock weather widget can never disagree about where "here" is, and the user
// configures it in one place.
function parseLocationFile(raw) {
  var unset = { name: "", latitude: null, longitude: null, valid: false }
  var text = String(raw || "").trim()
  if (text === "") return unset

  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return unset
  }
  if (!data) return unset

  var latitude = parseFloat(data.latitude)
  var longitude = parseFloat(data.longitude)
  var valid = isFinite(latitude) && isFinite(longitude)
    && latitude >= -90 && latitude <= 90
    && longitude >= -180 && longitude <= 180

  return {
    name: String(data.name || ""),
    latitude: valid ? latitude : null,
    longitude: valid ? longitude : null,
    valid: valid
  }
}

// What a stored location can actually be used for.
//
// The file is shared with the stock weather widget, and a name with no
// coordinates is a legitimate thing to find in it: that widget resolves names
// server-side, so "Marmeleiro" alone is a location as far as it is concerned.
// This plugin cannot use one — a map has to be centred on a coordinate and the
// forecast is fetched by coordinate — so the three cases are different states
// rather than two, and saying "no location" for a name somebody just typed
// would be telling them nothing happened when something did.
//
//   "ready"       coordinates, everything works
//   "unresolved"  a name, but nothing to centre or forecast on
//   "unset"       nothing stored
function locationState(location) {
  if (!location) return "unset"
  if (location.valid === true) return "ready"
  return String(location.name || "") !== "" ? "unresolved" : "unset"
}

// Geocoding, for the city picker. Same endpoint and same response shape the
// stock weather widget uses, so both pickers offer the same candidates for the
// same query.
var GEOCODING_URL = "https://geocoding-api.open-meteo.com/v1/search"

function geocodingUrl(query, count) {
  return GEOCODING_URL + "?name=" + encodeURIComponent(String(query || ""))
    + "&count=" + (count || 5) + "&language=en&format=json"
}

// Open-Meteo geocoding response → suggestion rows.
function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results
    if (!results || !results.length) return []

    var out = []
    for (var i = 0; i < results.length; i++) {
      var r = results[i]
      if (!r || !r.name || r.latitude === undefined || r.longitude === undefined) continue
      var region = [r.admin1, r.country].filter(function(part) { return !!part }).join(", ")
      out.push({
        name: String(r.name),
        description: region,
        latitude: r.latitude,
        longitude: r.longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// What pressing Enter in the search field should commit: the highlighted
// suggestion when there is one, otherwise the raw text with no coordinates —
// which omarchy-weather-location stores as a name for the forecast provider to
// resolve. A name without coordinates cannot centre a map, so the radar treats
// that case as "no location" until the file gains coordinates.
function locationCommit(text, suggestions, selectedIndex) {
  var name = String(text || "").replace(/^\s+|\s+$/g, "")
  if (name === "") return { name: "", latitude: null, longitude: null }

  var choices = suggestions || []
  var index = Math.max(0, Math.min(parseInt(selectedIndex, 10) || 0, choices.length - 1))
  var suggestion = choices[index]
  if (suggestion) return suggestion

  return { name: name, latitude: null, longitude: null }
}

// How far around the configured point the forecast is sampled, in kilometres.
//
// A point forecast is a point, but a town is not. The model runs on a grid
// roughly 8-10 km across, and a stored coordinate lands wherever it lands
// inside that grid — measured against Marmeleiro, the centre of town resolves
// to a cell 3.8 km away, and a point 1 km south already belongs to the next
// cell over. Sampling only the centre therefore answers for one arbitrary
// 8 km patch rather than for the place someone lives in.
//
// Five kilometres is chosen to cover a town's own footprint without becoming a
// regional forecast. Anything inside it is still "here" by any ordinary
// reading; widening it to the alert radius would mean announcing every shower
// within an hour's drive.
var SAMPLE_RADIUS_KM = 5

// Centre plus the four cardinal points at SAMPLE_RADIUS_KM. Five coordinates
// travel in a single request, so the extra coverage costs a larger response
// rather than more requests.
function samplePoints(lat, lon, km) {
  // parseFloat rather than Number, because an unset location carries null and
  // Number(null) is 0 — a guard built on it would admit the exact case it
  // exists to reject and place the caller off the coast of west Africa.
  // parseFloat(null) and parseFloat("") are both NaN, which is what is meant.
  lat = parseFloat(lat)
  lon = parseFloat(lon)
  if (!isFinite(lat) || !isFinite(lon)) return []

  var radius = km || SAMPLE_RADIUS_KM
  var dLat = radius / 111.32
  // Longitude degrees shrink towards the poles; without the cosine the
  // east-west samples would be far too close together at high latitude.
  var cos = Math.cos(TileMath.toRadians(lat))
  var dLon = Math.abs(cos) < 0.01 ? 0 : radius / (111.32 * cos)

  return [
    { latitude: lat, longitude: lon },
    { latitude: clampLat(lat + dLat), longitude: lon },
    { latitude: clampLat(lat - dLat), longitude: lon },
    { latitude: lat, longitude: TileMath.wrapLongitude(lon + dLon) },
    { latitude: lat, longitude: TileMath.wrapLongitude(lon - dLon) }
  ]
}

function clampLat(lat) {
  return Math.max(-90, Math.min(90, lat))
}

// ---------------------------------------------------------------------------
// Echo analysis
// ---------------------------------------------------------------------------

// Reflectivity bands, expressed on the 0-255 luminance of the greyscale
// scheme. RainViewer does not publish the exact luminance-to-dBZ mapping, so
// these are calibrated against the scheme's 22 quantisation steps and named
// for what they mean to a person rather than claiming a dBZ figure the API
// does not guarantee.
var INTENSITY_NONE = 0
var INTENSITY_LIGHT = 60      // drizzle to light rain
var INTENSITY_MODERATE = 120  // steady rain
var INTENSITY_HEAVY = 170     // downpour, convective core
var INTENSITY_SEVERE = 210    // very intense core, hail likely

function intensityLabel(value) {
  if (value >= INTENSITY_SEVERE) return "severe"
  if (value >= INTENSITY_HEAVY) return "heavy"
  if (value >= INTENSITY_MODERATE) return "moderate"
  if (value >= INTENSITY_LIGHT) return "light"
  if (value > INTENSITY_NONE) return "trace"
  return "clear"
}

// ---------------------------------------------------------------------------
// Map legend
// ---------------------------------------------------------------------------

// The map's legend key: the ramp the tile paints, read as three colour
// families. A legend is a key, not a histogram — the tile's alpha scale spends
// most of its 0-255 range on near-identical tans, and laying the bar out by
// value would give that grey run three quarters of the strip while blue,
// yellow and red shared the rest. So each family — the translucent tans, the
// opaque blues, the yellow-through-red cores — gets one equal third, with its
// stops painting a gradient inside it. The names describe the colour, not the
// `intensityLabel` thresholds above: the blue family opens at the severe band,
// and the legend says so with its own three words.
//
// The run lengths are the three runs already visible in the stop table below.
var RADAR_FAMILY_RUNS = [
  { name: "Light", count: 25 },    // translucent tans, values 20-190
  { name: "Moderate", count: 20 }, // opaque blues, 192-230
  { name: "Heavy", count: 19 }     // yellow through darkest red, 237-255
]

// The three families, each carrying the slice of stops it paints, in order.
function radarLegendFamilies() {
  var families = []
  var at = 0
  for (var i = 0; i < RADAR_FAMILY_RUNS.length; i++) {
    families.push({
      name: RADAR_FAMILY_RUNS[i].name,
      stops: RADAR_GRADIENT_STOPS.slice(at, at + RADAR_FAMILY_RUNS[i].count)
    })
    at += RADAR_FAMILY_RUNS[i].count
  }
  return families
}

// The gradient the map paints over the radar ramp. Sampling fresh radar tiles
// from the public API, the eight documented colour schemes collapse to one
// picture: request any of the schemes 0-7 and the bytes come back identical
// (md5-equal, measured 2026-09-10 at z7 over Brazil and Florida, the deepest
// zoom RainViewer serves). So there is one honest ramp to show, with exactly
// the bins the tile quantises to, faintest on the left and strongest on the
// right.
//
// The bins were read off the tiles themselves, two ways. The raw tiles
// (smooth=0) enumerate the palette without any interpolation, and a pixel
// walk from a storm core's fringe to its centre fixes the order the renderer
// climbs through them: translucent tans brighten as the echo strengthens,
// then the opaque bins take over — blues darkening, then yellow, orange and
// finally red as the core intensifies. The strongest colour the palette
// carries is the darkest red; an earlier version of this table had it first,
// which put the heaviest rain at the faint end of the legend.
//
// The tile encodes intensity in the alpha channel, and the renderer caps it
// at 255 once a bin is fully opaque: the 25 tan bins carry their exact value
// (alpha = intensity on the 0-255 scale), while the 39 opaque bins' values
// are an estimate — spaced to fill 192-255 above the last tan — because the
// tile cannot distinguish them. Their order is the measured one; only the
// spacing between opaque bins is an assumption, kept in the value table below
// for the record even though the legend no longer lays its cells out by it.
//
// The scheme list is still what the widget offers and requests, and a change
// upstream may split the schemes into genuinely different palettes again; the
// legend then has to sample the tile the way the map does instead of carrying
// a table. Until the API shows a difference, every scheme's legend is this
// ramp, which is a true statement about the map.
var RADAR_GRADIENT_STOPS = [
  // Translucent tan ladder: intensity 20-190, the value is the measured alpha.
  "#636159", "#66635a", "#69665c", "#6c685d", "#6f6b5f", "#726e61",
  "#757062", "#787364", "#7c7565", "#7f7867", "#827b69", "#857d6a",
  "#88806c", "#8b826d", "#8e856f", "#928871", "#9e9375", "#aa9e79",
  "#b6a97e", "#c2b482", "#cec087", "#d2c48b", "#d6c88f", "#dacc93",
  "#ded097",
  // Opaque blues, pale at the faint end darkening to the last blue bin.
  "#88ddee", "#6cd1eb", "#51c5e8", "#36bae5", "#1baee2", "#00a3e0",
  "#009ad5", "#0091ca", "#0088bf", "#007fb4", "#0077aa", "#0070a3",
  "#00699c", "#006295", "#005b8e", "#005588", "#005180", "#004e78",
  "#004a70", "#004768",
  // Storm cores: yellow climbing through orange into the darkest red.
  "#ffee00", "#ffe000", "#ffd200", "#ffc500", "#ffb700", "#ffaa00",
  "#ff9f00", "#ff9500", "#ff8b00", "#ff8100", "#ff4400", "#f23600",
  "#e62800", "#d91b00", "#cd0d00", "#c10000", "#a80000", "#760000",
  "#5d0000"
]

// Each stop's place on the 0-255 intensity scale, in the same order. The tan
// values are the alphas the tiles carry; the opaque bins are estimates, spaced
// to fill 192-255 above the last tan as the comment above explains. Kept for
// the record and pinned by test, but the legend now keys the ramp by colour
// family rather than by these values, so it does not paint from them.
var RADAR_STOP_VALUES = [
  20, 25, 30, 36, 41, 46, 52, 57, 62, 68, 73, 78, 84, 89, 94, 100, 110, 120,
  130, 140, 150, 160, 170, 180, 190,
  192, 194, 196, 198, 200, 202, 204, 206, 208, 210, 212, 214, 216, 218, 220,
  222, 224, 226, 228, 230,
  237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251,
  252, 253, 254, 255
]

// Scan a coordinate-centred greyscale tile for the strongest echo within
// `radiusKm` of the centre — which is the user's location.
//
// `pixels` is the RGBA byte array from Canvas getImageData; `size` is the tile
// edge in pixels. Returns the strongest cell found plus where it sits, so the
// alert can say "heavy rain 42 km SW" instead of just "rain nearby".
function analyzeEchoes(pixels, size, lat, zoom, radiusKm) {
  var result = {
    found: false,
    intensity: 0,
    label: "clear",
    distanceKm: 0,
    bearing: 0,
    compass: "",
    coveredPixels: 0
  }
  if (!pixels || size <= 0) return result

  var center = size / 2
  var metersPerPixel = TileMath.metersPerPixel(lat, zoom)
  var radiusPixels = radiusKm * 1000 / metersPerPixel
  var maxRadius = Math.min(radiusPixels, center)

  // Walk only the bounding box of the search circle; at z7 with a 100 km
  // radius that is roughly a 180x180 window inside a 512 tile.
  var lo = Math.max(0, Math.floor(center - maxRadius))
  var hi = Math.min(size - 1, Math.ceil(center + maxRadius))

  for (var y = lo; y <= hi; y++) {
    for (var x = lo; x <= hi; x++) {
      var dx = x - center
      var dy = y - center
      var distancePixels = Math.sqrt(dx * dx + dy * dy)
      if (distancePixels > maxRadius) continue

      var offset = (y * size + x) * 4
      // Alpha is zero where there is no echo at all, which is the one part of
      // this that holds.
      //
      // The red channel is *not* an intensity. This was written for the tile
      // MEASUREMENT_SCHEME was believed to return, and that tile does not
      // exist — see the measurement there. On the coloured tile the endpoint
      // actually serves, reading one channel reads a component of a colour,
      // and the palette is not monotonic in it. Nothing calls this function,
      // so nothing is wrong today; reviving it means deriving a reading from
      // all three channels against whichever palette arrives, which is not
      // controllable either.
      if (pixels[offset + 3] === 0) continue
      var intensity = pixels[offset]
      if (intensity <= INTENSITY_NONE) continue

      result.coveredPixels++
      if (intensity > result.intensity) {
        result.found = true
        result.intensity = intensity
        result.distanceKm = distancePixels * metersPerPixel / 1000
        // Screen y grows south, so north is -dy.
        result.bearing = (TileMath.toDegrees(Math.atan2(dx, -dy)) + 360) % 360
      }
    }
  }

  result.label = intensityLabel(result.intensity)
  result.compass = result.found ? TileMath.compassPoint(result.bearing) : ""
  return result
}

// Is the centre pixel of a coverage mask transparent? Transparent means a
// ground radar reaches this location.
function hasCoverageAtCenter(pixels, size) {
  if (!pixels || size <= 0) return true
  var center = Math.floor(size / 2)
  var offset = (center * size + center) * 4
  return pixels[offset + 3] === 0
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

function formatFrameTime(epochSeconds) {
  if (!epochSeconds) return ""
  var date = new Date(epochSeconds * 1000)
  return pad(date.getHours()) + ":" + pad(date.getMinutes())
}

function pad(value) {
  return value < 10 ? "0" + value : String(value)
}

// How far behind now a frame is, for the loop's caption: "35 min ago". The
// clock beside it says when; this says how stale the picture is, which while
// replaying is the number the eye actually wants.
//
// Frames arrive every ten minutes, so anything finer than five minutes is
// precision the data does not carry: a frame 34 minutes old is the 30-minutes
// one or the 35-minutes one depending on when the manifest landed. Under five
// minutes reads as the newest frame and answers "" — the caption is only
// filled while the picture is genuinely in the past.
function formatFrameAgo(epochSeconds, nowMs) {
  if (!epochSeconds || !nowMs) return ""
  var seconds = Math.round(nowMs / 1000) - epochSeconds
  if (seconds < 300) return ""
  return formatAge(seconds)
}

// How long ago the newest radar picture was published, for the header's
// "latest update" readout: "just now" while that frame is under five minutes
// old, then the same five-minute rounding as the loop's caption. Unlike
// formatFrameAgo the readout never hints at its own absence once frames
// exist — a "latest update" that blinks away on the freshest frame is not a
// readout at all. A frame stamped in the future is the clock moving, not
// RainViewer publishing ahead, and reads the same as fresh.
function formatUpdateAge(epochSeconds, nowMs) {
  if (!epochSeconds || !nowMs) return ""
  var seconds = Math.round(nowMs / 1000) - epochSeconds
  if (seconds < 300) return "just now"
  return formatAge(seconds)
}

// The tail the two ages share, rounded to the five-minute blocks the data
// actually arrives in.
function formatAge(seconds) {
  var minutes = Math.round(seconds / 300) * 5
  if (minutes < 60) return minutes + " min ago"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  return rest === 0 ? hours + " h ago" : hours + " h " + pad(rest) + " m ago"
}

function formatDistance(km) {
  if (km >= 100) return Math.round(km) + " km"
  if (km >= 10) return km.toFixed(0) + " km"
  return km.toFixed(1) + " km"
}

// Short bar label, e.g. "heavy 42 km SW" or "clear".
function summaryLabel(echo) {
  if (!echo || !echo.found) return "clear"
  return echo.label + " " + formatDistance(echo.distanceKm) + " " + echo.compass
}
