const { test } = require("node:test")
const assert = require("node:assert")
const { loadLibrary, TileMath } = require("./load.js")

const CamsModel = loadLibrary("CamsModel.js", { TileMath })

// A slice of a real caps.json, shaped exactly as cams.py writes it.
const CAPS = {
  version: 1,
  layers: [
    { name: "composition_europe_pm2p5_forecast_surface", title: "Particulate matter < 2.5 um (provided by CAMS, implemented by …)",
      time: "2026-09-06T00:00:00Z/2026-09-09T00:00:00Z/PT3H",
      styles: ["default"], category: "air-quality", tier: "curated", region: "europe",
      short: "PM2.5", species: "pm2p5", variant: "forecast" },
    { name: "composition_europe_pm10_forecast_surface", title: "Particulate matter < 10 um",
      time: "2026-09-06T00:00:00Z/2026-09-09T00:00:00Z/PT3H",
      styles: [], category: "air-quality", tier: "curated", region: "europe",
      short: "PM10", species: "pm10", variant: "forecast" },
    { name: "composition_pm2p5", title: "Global PM2.5",
      time: "2026-09-06T00:00:00Z/2026-09-11T00:00:00Z/PT6H",
      styles: [], category: "air-quality", tier: "curated", region: "global",
      short: "PM2.5", species: "pm2p5", variant: "forecast" },
    { name: "composition_europe_pol_birch_forecast_surface_eea", title: "Birch pollen (index)",
      time: "2026-09-06T00:00:00Z/2026-09-09T00:00:00Z/PT1H",
      styles: [], category: "allergens", tier: "curated", region: "europe",
      short: "Birch", species: "birch", variant: "index" },
    { name: "composition_aod550", title: "Total aerosol optical depth at 550nm",
      time: "2026-09-06T00:00:00Z/2026-09-09T00:00:00Z/PT1H",
      styles: [], category: "aerosols", tier: "curated", region: "any",
      short: "Total AOD", species: "aod550", variant: "forecast" },
    { name: "composition_co2", title: "CO2 (something technical)",
      time: "2026-09-06T00:00:00Z/2026-09-09T00:00:00Z/PT1H",
      styles: [], category: "advanced", tier: "advanced", region: "any",
      short: "co2", species: "co2", variant: "gases" },
  ]
}

// ------------------------------------------------------------------ registry

test("the chip order is the declared order, filtered by what the region has", () => {
  assert.deepStrictEqual(
    CamsModel.categoriesFor(CAPS, "europe"),
    ["air-quality", "allergens", "aerosols", "advanced"])
})

test("a global region loses Allergens and the Europe layers", () => {
  assert.deepStrictEqual(
    CamsModel.categoriesFor(CAPS, "global"),
    ["air-quality", "aerosols", "advanced"])
})

test("categories with no layers at all are not offered", () => {
  const uvOnly = { layers: CAPS.layers.filter(l => l.category === "uv") }
  assert.deepStrictEqual(CamsModel.categoriesFor(uvOnly, "europe"), [])
})

test("a region only sees its own layers", () => {
  const europe = CamsModel.layersForCategory(CAPS, "air-quality", "europe")
  assert.deepStrictEqual(europe.map(l => l.name),
    ["composition_europe_pm2p5_forecast_surface", "composition_europe_pm10_forecast_surface"])

  const global = CamsModel.layersForCategory(CAPS, "air-quality", "global")
  assert.deepStrictEqual(global.map(l => l.name), ["composition_pm2p5"])
})

test("layers sort by the declared species order, not registry order", () => {
  const caps = { layers: [CAPS.layers[1], CAPS.layers[0]] } // PM10 before PM2.5
  const layers = CamsModel.layersForCategory(caps, "air-quality", "europe")
  assert.strictEqual(layers[0].species, "pm2p5")
  assert.strictEqual(layers[1].species, "pm10")
})

test("empty or absent caps answer with empty lists, never a throw", () => {
  assert.deepStrictEqual(CamsModel.categoriesFor(null, "europe"), [])
  assert.deepStrictEqual(CamsModel.layersForCategory(null, "air-quality", "europe"), [])
  assert.strictEqual(CamsModel.findLayer(null, "x"), null)
})

test("titles are shown without the WMS attribution suffix", () => {
  assert.strictEqual(
    CamsModel.layerLabel(CAPS.layers[0]),
    "Particulate matter < 2.5 um")
})

// ---------------------------------------------------------------- time steps

test("a start/end/period dimension expands to the steps it names", () => {
  const times = CamsModel.expandTimes("2026-09-06T00:00:00Z/2026-09-06T06:00:00Z/PT3H")
  assert.deepStrictEqual(times, [
    "2026-09-06T00:00:00Z", "2026-09-06T03:00:00Z", "2026-09-06T06:00:00Z"])
})

test("single instants and comma-separated tokens pass through", () => {
  assert.deepStrictEqual(
    CamsModel.expandTimes("2026-09-06T00:00:00Z,2026-09-06T01:00:00Z"),
    ["2026-09-06T00:00:00Z", "2026-09-06T01:00:00Z"])
})

test("a malformed interval degrades to its start rather than exploding", () => {
  assert.deepStrictEqual(
    CamsModel.expandTimes("2026-09-06T00:00:00Z/2026-09-09T00:00:00Z"),
    ["2026-09-06T00:00:00Z"])
  assert.deepStrictEqual(
    CamsModel.expandTimes("2026-09-06T00:00:00Z/2026-09-09T00:00:00Z/PNONSENSE"),
    ["2026-09-06T00:00:00Z"])
})

test("a pathological dimension stops expanding at the ceiling", () => {
  // PT1M over thirty days would be 43200 steps; the ceiling exists so no
  // capabilities document can freeze the shell building the list.
  const times = CamsModel.expandTimes("2026-08-01T00:00:00Z/2026-08-31T00:00:00Z/PT1M")
  assert.strictEqual(times.length, CamsModel.MAX_STEPS)
})

test("the nearest step to now is the one a fresh open lands on", () => {
  const times = CamsModel.expandTimes("2026-09-06T00:00:00Z/2026-09-06T06:00:00Z/PT3H")
  const now = Date.parse("2026-09-06T03:40:00Z")
  assert.strictEqual(CamsModel.nearestTimeIndex(times, now), 1)
})

// -------------------------------------------------------------------- bbox

test("the viewport bbox is the rectangle in metres the view covers", () => {
  // London at z6, a 500x320 viewport: centre near zero, edges symmetric.
  const bbox = CamsModel.viewportBbox(51.5072, -0.1276, 6, 500, 320)
  const centreX = (bbox.minx + bbox.maxx) / 2
  const centreY = (bbox.miny + bbox.maxy) / 2
  assert.ok(Math.abs(centreX - CamsModel.lonToMercX(-0.1276)) < 1, "x centres on the view")
  assert.ok(Math.abs(centreY - CamsModel.latToMercY(51.5072)) < 1, "y centres on the view")
  assert.ok(bbox.maxy > bbox.miny, "northing is positive north")
})

test("a view straddling the antimeridian still produces a min-first bbox", () => {
  const bbox = CamsModel.viewportBbox(-17.0, 179.9, 6, 500, 320)
  assert.ok(bbox.minx < bbox.maxx, "west edge east of the east edge is repaired")
})

test("mercator conversion agrees with the tile math both sides use", () => {
  // lonToMercX(0) must be 0, and one tile's width in metres at any zoom must
  // be the span divided by the tile count — the two projections share a world.
  assert.strictEqual(CamsModel.lonToMercX(0), 0)
  const left = CamsModel.lonToMercX(TileMath.tileXToLon(1, 7))
  const right = CamsModel.lonToMercX(TileMath.tileXToLon(2, 7))
  assert.ok(Math.abs((right - left) - CamsModel.MERCATOR_SPAN / 128) < 1)
})

// ------------------------------------------------------------------- urls

test("the GetMap URL carries layer, style, bbox, size and the requested time", () => {
  const url = CamsModel.mapUrl("composition_europe_pm2p5_forecast_surface", "",
    { minx: 1, miny: 2, maxx: 3, maxy: 4 }, 500, 320, "2026-09-06T00:00:00Z")
  assert.ok(url.startsWith("https://eccharts.ecmwf.int/wms/?token=public&"))
  assert.ok(url.includes("request=GetMap"))
  assert.ok(url.includes("layers=composition_europe_pm2p5_forecast_surface"))
  assert.ok(url.includes("bbox=1,2,3,4"), "EPSG:3857 axis order is easting,northing")
  assert.ok(url.includes("width=500&height=320"))
  assert.ok(url.includes("dim_time=2026-09-06T00%3A00%3A00Z"))
})

test("a layer name is encoded, not passed raw", () => {
  const url = CamsModel.mapUrl("a b&c", "", { minx: 1, miny: 2, maxx: 3, maxy: 4 }, 10, 10, "")
  assert.ok(url.includes("layers=a%20b%26c"))
})

// ------------------------------------------------------------------- bands

test("band cut-offs follow the EEA index per species", () => {
  assert.strictEqual(CamsModel.aqBandIndex("pm2p5", 5), 0)
  assert.strictEqual(CamsModel.aqBandIndex("pm2p5", 10), 1)   // boundary belongs up
  assert.strictEqual(CamsModel.aqBandIndex("pm2p5", 74), 4)
  assert.strictEqual(CamsModel.aqBandIndex("pm2p5", 75), 5)   // …and so here
  assert.strictEqual(CamsModel.aqBandIndex("pm2p5", 500), 5)  // beyond the top is still the top
})

test("a species with no table, or a value that is not a number, has no band", () => {
  assert.strictEqual(CamsModel.aqBandIndex("pine", 10), -1)
  assert.strictEqual(CamsModel.aqBandIndex("pm2p5", NaN), -1)
  assert.strictEqual(CamsModel.aqLevel("pm2p5", NaN), null)
})

test("the level carries the name and colour the pill renders", () => {
  const level = CamsModel.aqLevel("pm2p5", 30)
  assert.strictEqual(level.band, 3)
  assert.strictEqual(level.name, "Poor")
  assert.strictEqual(level.color, CamsModel.BAND_COLORS[3])
})

// ------------------------------------------------------------------ legend

// The CAMS render scales the map paints with, read off the served GetLegend
// images. Pinning the breaks here makes a CAMS restyle fail this suite rather
// than let the legend drift from the pixels.
const CAMS_LEGEND = {
  "pm2p5": { unit: "µg/m³", upTo: [2, 5, 10, 20, 30, 40, 50, 75, 100, 150, 200, 500] },
  "pm10": { unit: "µg/m³", upTo: [2, 5, 10, 20, 30, 40, 50, 75, 100, 150, 200, 500] },
  "o3": { unit: "µg/m³", upTo: [0, 20, 40, 60, 80, 100, 120, 140, 160, 180, 200, 240, 500] },
  "no2": { unit: "µg/m³", upTo: [0, 2, 5, 10, 20, 30, 40, 50, 75, 100, 150, 200, 300] },
  "so2": { unit: "µg/m³", upTo: [0, 2, 5, 10, 20, 30, 40, 50, 75, 100, 150, 200, 800] },
  "co": { unit: "µg/m³", upTo: [0, 50, 100, 150, 200, 250, 300, 350, 400, 500, 700, 1000, 2000] },
  "aod550": { unit: "AOD", upTo: [0.15, 0.2, 0.35, 0.5, 0.8, 1, 3] }
}

test("the legend rows are the CAMS render scale, low to high", () => {
  for (const [species, expected] of Object.entries(CAMS_LEGEND)) {
    const rows = CamsModel.camsLegendRows(species)
    assert.deepStrictEqual(rows.map(r => r.upTo), expected.upTo)
    assert.strictEqual(CamsModel.camsScaleUnit(species), expected.unit)
  }
})

test("every band carries a colour and its species' unit", () => {
  for (const species of Object.keys(CAMS_LEGEND)) {
    for (const row of CamsModel.camsLegendRows(species)) {
      assert.match(row.color, /^#[0-9A-F]{6}$/)
      assert.strictEqual(row.unit, CamsModel.camsScaleUnit(species))
    }
  }
})

test("a species with no read scale shows no bar and no unit", () => {
  assert.deepStrictEqual(CamsModel.camsLegendRows("birch"), [])
  assert.strictEqual(CamsModel.camsScaleUnit("birch"), "")
})

test("each category names the ends of its own ramp", () => {
  assert.strictEqual(CamsModel.legendEnds("air-quality").low, "Cleaner")
  assert.strictEqual(CamsModel.legendEnds("air-quality").high, "More polluted")
  assert.strictEqual(CamsModel.legendEnds("allergens").low, "Less pollen")
  assert.strictEqual(CamsModel.legendEnds("allergens").high, "More pollen")
  assert.strictEqual(CamsModel.legendEnds("aerosols").low, "Clearer")
  assert.strictEqual(CamsModel.legendEnds("aerosols").high, "Hazier")
  assert.strictEqual(CamsModel.legendEnds("uv").low, "Low UV")
  assert.strictEqual(CamsModel.legendEnds("uv").high, "Extreme UV")
})

test("an unnamed category still names its ends", () => {
  // The advanced tail has no declared ends; the scale must not lose its names.
  const ends = CamsModel.legendEnds("advanced")
  assert.ok(ends.low !== "" && ends.high !== "")
})
