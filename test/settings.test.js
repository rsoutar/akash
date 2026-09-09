const { test } = require("node:test")
const assert = require("node:assert")
const { readFileSync } = require("node:fs")
const { join } = require("node:path")
const { loadLibrary, RadarModel, TileMath } = require("./load.js")

const Alerts = loadLibrary("Alerts.js")
const CamsModel = loadLibrary("CamsModel.js", { TileMath })
const Settings = loadLibrary("Settings.js", { RadarModel, Alerts, CamsModel })

const manifest = JSON.parse(readFileSync(join(__dirname, "..", "manifest.json"), "utf8"))
const widget = manifest.barWidget
const schemaFor = key => widget.schema.find(entry => entry.key === key)

// ------------------------------------------------- the manifest and the code

test("the code's defaults are the manifest's defaults", () => {
  // The manifest is what a fresh install gets; DEFAULTS is what the code falls
  // back to. If they drift, new users and existing users run different
  // plugins, and nothing anywhere reports it.
  assert.deepStrictEqual(Settings.DEFAULTS, widget.defaults)
})

test("every setting declares the same default in both halves of the manifest", () => {
  for (const entry of widget.schema) {
    assert.deepStrictEqual(entry.defaultValue, widget.defaults[entry.key],
      `${entry.key}: schema says ${JSON.stringify(entry.defaultValue)}, ` +
      `defaults say ${JSON.stringify(widget.defaults[entry.key])}`)
  }
})

test("every setting the code reads is a setting the manifest declares", () => {
  const declared = new Set(widget.schema.map(entry => entry.key))
  for (const key of Object.keys(Settings.DEFAULTS)) {
    assert.ok(declared.has(key), `${key} is read by the code but the manifest does not declare it`)
  }
})

test("the threshold options offered are the ones the alert logic understands", () => {
  assert.deepStrictEqual(schemaFor("alertMinIntensity").options, Alerts.THRESHOLD_OPTIONS)
})

test("the air-quality band options are real EEA bands, and the default is one of them", () => {
  const options = schemaFor("aqAlertBand").options
  for (const name of options) {
    assert.ok(CamsModel.BAND_NAMES.includes(name), `${name} is not a band CamsModel knows`)
    assert.ok(Alerts.AQ_BAND_NAMES.includes(name), `${name} is not a band Alerts knows`)
  }
  assert.ok(options.includes(widget.defaults.aqAlertBand),
    "the default band must be one the picker offers")
  // Bands below Moderate are most days in most places; a watch that fires
  // daily is switched off.
  assert.ok(CamsModel.BAND_NAMES.indexOf(widget.defaults.aqAlertBand) >= 2,
    "the default threshold must be Moderate or above")
})

test("the air-quality threshold resolves to the band index the decision uses", () => {
  assert.strictEqual(Settings.aqThresholdBand({ aqAlertBand: "Poor" }), 3)
  assert.strictEqual(Settings.aqThresholdBand({ aqAlertBand: "Very poor" }), 4)
  assert.strictEqual(Settings.aqThresholdBand({ aqAlertBand: "nonsense" }),
    Settings.aqThresholdBand({}))
})

test("the colour schemes offered are ones the API knows", () => {
  const offered = schemaFor("colorScheme").options
  assert.deepStrictEqual(offered, RadarModel.COLOR_SCHEMES.map(scheme => scheme.name))
  for (const name of offered) {
    assert.notStrictEqual(RadarModel.colorSchemeName(Settings.colorSchemeId({ colorScheme: name })),
      "Unknown", name)
  }
})

test("the declared ranges match the ones the code enforces", () => {
  const radius = schemaFor("alertRadiusKm")
  assert.strictEqual(radius.min, Settings.RADIUS_MIN_KM)
  assert.strictEqual(radius.max, Settings.RADIUS_MAX_KM)
  assert.strictEqual(radius.step, Settings.RADIUS_STEP_KM)

  const zoom = schemaFor("defaultZoom")
  assert.strictEqual(zoom.min, RadarModel.MIN_RADAR_ZOOM)
  assert.strictEqual(zoom.max, RadarModel.MAX_MAP_ZOOM)
})

test("every radius preset is a value the declared range allows", () => {
  for (const preset of Settings.RADIUS_PRESETS_KM) {
    assert.ok(preset >= Settings.RADIUS_MIN_KM && preset <= Settings.RADIUS_MAX_KM, `${preset}`)
    assert.strictEqual(preset % Settings.RADIUS_STEP_KM, 0, `${preset} is not on the step`)
  }
})

// ------------------------------------------------------------------ readiness

test("settings that have not arrived yet are not settings that are off", () => {
  // Treating the empty object as "alerts are off" makes the arrival of real
  // settings look like the user switching them on, which re-arms the latch and
  // can announce the same weather twice.
  assert.strictEqual(Settings.isReady({}), false)
  assert.strictEqual(Settings.isReady(null), false)
  assert.strictEqual(Settings.isReady(undefined), false)
  assert.strictEqual(Settings.isReady({ alertsEnabled: false }), true)

  assert.strictEqual(Settings.alertsEnabled({}), false)
  assert.strictEqual(Settings.alertsEnabled({ alertsEnabled: true }), true)
})

// ------------------------------------------------------------------ coercion

test("an absent setting falls back to its default", () => {
  assert.strictEqual(Settings.alertRadiusKm({}), 100)
  assert.strictEqual(Settings.alertThreshold({}), "Heavy")
  assert.strictEqual(Settings.defaultZoom({}), 7)
  assert.strictEqual(Settings.smoothTiles({ smoothTiles: true }), true)
  assert.strictEqual(Settings.showSnow({ showSnow: true }), true)
  assert.strictEqual(Settings.showLabel({}), false)
})

test("a null radius falls back rather than clamping to the minimum", () => {
  // Number(null) is 0, which would clamp to 25 km and quietly narrow the watch
  // to a quarter of what the user set.
  for (const value of [null, undefined, "", "abc", NaN]) {
    assert.strictEqual(Settings.alertRadiusKm({ alertRadiusKm: value }), 100, JSON.stringify(value))
  }
})

test("a radius outside the declared range is clamped into it", () => {
  assert.strictEqual(Settings.alertRadiusKm({ alertRadiusKm: 0 }), 25)
  assert.strictEqual(Settings.alertRadiusKm({ alertRadiusKm: -50 }), 25)
  assert.strictEqual(Settings.alertRadiusKm({ alertRadiusKm: 9999 }), 250)
  assert.strictEqual(Settings.alertRadiusKm({ alertRadiusKm: "150" }), 150, "a string number still counts")
  assert.strictEqual(Settings.alertRadiusKm({ alertRadiusKm: 137.6 }), 138)
})

test("a threshold the code does not understand falls back to the default", () => {
  for (const value of ["Catastrophic", "", null, 3, "heavy"]) {
    assert.strictEqual(Settings.alertThreshold({ alertMinIntensity: value }), "Heavy",
      JSON.stringify(value))
  }
  assert.strictEqual(Settings.alertThreshold({ alertMinIntensity: "Light" }), "Light")
})

test("an unknown colour scheme falls back to the default rather than to nothing", () => {
  const fallback = Settings.colorSchemeId({ colorScheme: "TITAN" })
  for (const value of ["Nonexistent", "", null, 42]) {
    assert.strictEqual(Settings.colorSchemeId({ colorScheme: value }), fallback, JSON.stringify(value))
  }
  assert.strictEqual(Settings.colorSchemeId({ colorScheme: "NEXRAD Level III" }), 5)
})

test("the opening zoom stays inside the map's own limits", () => {
  assert.strictEqual(Settings.defaultZoom({ defaultZoom: 0 }), RadarModel.MIN_RADAR_ZOOM)
  assert.strictEqual(Settings.defaultZoom({ defaultZoom: 99 }), RadarModel.MAX_MAP_ZOOM)
  assert.strictEqual(Settings.defaultZoom({ defaultZoom: null }), 7)
  assert.strictEqual(Settings.defaultZoom({ defaultZoom: "9" }), 9)
})

test("a boolean setting is only true when it is actually true", () => {
  // shell.json is hand-editable, so "true" and 1 both turn up. Neither is a
  // boolean, and reading them as one would make the setting mean whatever the
  // user's JSON style happened to be.
  for (const value of ["true", 1, "yes", {}]) {
    assert.strictEqual(Settings.showLabel({ showLabel: value }), false, JSON.stringify(value))
  }
  assert.strictEqual(Settings.showLabel({ showLabel: true }), true)
})

// ------------------------------------------------------------------ presets

test("the radius presets always contain the value in force", () => {
  // A control that cannot represent its own current value changes it the
  // moment anyone touches it.
  assert.deepStrictEqual(Settings.radiusPresets(100), ["50", "100", "150", "200"])
  assert.deepStrictEqual(Settings.radiusPresets(137), ["50", "100", "137", "150", "200"])
  assert.deepStrictEqual(Settings.radiusPresets(25), ["25", "50", "100", "150", "200"])
  assert.deepStrictEqual(Settings.radiusPresets(250), ["50", "100", "150", "200", "250"])
})

test("the presets are not mutated by being read", () => {
  Settings.radiusPresets(137)
  assert.deepStrictEqual(Settings.RADIUS_PRESETS_KM, [50, 100, 150, 200])
})

test("an unusable default colour scheme yields a colour, not a stack overflow", () => {
  // The fallback used to be a call back into the same function, whose base case
  // lived in another file: it ended only because DEFAULTS.colorScheme happened
  // to name a scheme RadarModel declares. Renaming one without the other would
  // not have produced the wrong colour, it would have overflowed the stack
  // while the panel was being built.
  const stranded = loadLibrary("Settings.js", {
    RadarModel: { COLOR_SCHEMES: [{ id: 7, name: "Something Else" }] },
    Alerts: Alerts
  })

  assert.strictEqual(stranded.colorSchemeId({ colorScheme: "Nonexistent" }), 7)
  assert.strictEqual(stranded.colorSchemeId({}), 7, "and with no setting at all")
})

// ------------------------------------------------------------ the opening view

test("the view options offered are the ones the mapping understands", () => {
  const offered = schemaFor("defaultView").options
  assert.deepStrictEqual(offered, Settings.VIEW_OPTIONS)
  for (const name of offered) {
    assert.ok(name in Settings.VIEW_IDS, `${name} has no category id`)
  }
})

test("an unknown view falls back to the default rather than to nothing", () => {
  for (const value of ["Satellite", "", null, 7, "radar"]) {
    assert.strictEqual(Settings.defaultView({ defaultView: value }), "Radar", JSON.stringify(value))
  }
  assert.strictEqual(Settings.defaultView({}), "Radar")
  assert.strictEqual(Settings.defaultView({ defaultView: "UV" }), "UV")
})

test("every offered view maps to the category id the panel's state uses", () => {
  // The ids are the chips': they must match what chooseCategory stores and
  // what CamsModel.layersForCategory answers to, or the panel would open on a
  // category the picker does not light up.
  const expected = {
    "Radar": "radar",
    "Air quality": "air-quality",
    "Allergens": "allergens",
    "Aerosols": "aerosols",
    "UV": "uv",
    "Last used": "last"
  }
  for (const name of Settings.VIEW_OPTIONS) {
    assert.strictEqual(Settings.viewIdFor(name), expected[name], name)
  }
})

test("an id the mapping does not know reads as radar, never as undefined", () => {
  // "Last used" resolves from a persisted string that is under the user's
  // hand via shell.json; a value that is not a chip must not become a
  // category the picker has never heard of.
  for (const value of ["bogus", "", null, undefined, 42]) {
    assert.strictEqual(Settings.viewIdFor(value), "radar", JSON.stringify(value))
  }
})
