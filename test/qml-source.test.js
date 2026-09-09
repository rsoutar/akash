// What the QML says about itself.
//
// The rest of the suite runs the plugin's plain functions. These files cannot
// be run here at all — they need a QML engine and the shell's own modules — so
// what is checked is the source, and only claims a reader could verify by
// looking. The same strings are rendered under Qt by test/first-run.sh, which
// is what turns these into evidence rather than intent.

const { test } = require("node:test")
const assert = require("node:assert")
const { readFileSync, readdirSync } = require("node:fs")
const { join } = require("node:path")

const ROOT = join(__dirname, "..")

function qmlFiles() {
  const here = readdirSync(ROOT).filter(name => name.endsWith(".qml"))
  const ui = readdirSync(join(ROOT, "ui")).filter(name => name.endsWith(".qml"))
  return [...here.map(n => n), ...ui.map(n => join("ui", n))]
}

function read(relative) {
  return readFileSync(join(ROOT, relative), "utf8")
}

// QML's Text defaults to Text.AutoText, which decides per string whether it is
// markup — so a place name shaped like an img tag is parsed as one and its
// source is fetched by the process that owns the bar, the panels and the lock
// screen. Three of these render strings this plugin did not write: the stored
// location name, and the name and description of a geocoding suggestion.
//
// The rule is every Text rather than only those three, because which value
// reaches which label changes with every edit, and a rule with exceptions is a
// rule somebody has to re-derive before adding a component.
test("every Text element declares Text.PlainText", () => {
  const offenders = []

  for (const relative of qmlFiles()) {
    const lines = read(relative).split("\n")
    lines.forEach((line, index) => {
      if (!/^\s*Text\s*\{\s*$/.test(line)) return
      // The declaration is required inside the block, not necessarily on the
      // next line: what matters is that the element carries it before its
      // properties are read, and a block is short enough to look at whole.
      const block = lines.slice(index, index + 30).join("\n")
      const end = block.indexOf("\n  }")
      const body = end === -1 ? block : block.slice(0, end)
      if (!/textFormat\s*:\s*Text\.PlainText/.test(body)) {
        offenders.push(`${relative}:${index + 1}`)
      }
    })
  }

  assert.deepStrictEqual(offenders, [],
    "a Text left on the default parses markup out of whatever it is given")
})

// A count, so that deleting the elements is not a way to pass the rule above.
test("the plugin still renders text", () => {
  const total = qmlFiles()
    .map(relative => (read(relative).match(/^\s*Text\s*\{\s*$/gm) || []).length)
    .reduce((sum, n) => sum + n, 0)

  assert.ok(total >= 12, `only ${total} Text elements found`)
})

test("radar rendering is disabled when an air category owns the map", () => {
  const canvas = read(join("ui", "MapCanvas.qml"))
  const tileLayer = read(join("ui", "TileLayer.qml"))
  const panel = read("Panel.qml")

  assert.match(canvas, /property bool radarOverlayVisible: true/)
  assert.match(canvas, /active: root\.radarOverlayVisible/)
  assert.match(canvas, /visible: root\.radarOverlayVisible/)
  assert.match(panel, /radarOverlayVisible: root\.radarMode/)
  assert.match(tileLayer, /model: root\.active \? root\.tiles : \[\]/)
})

test("the legend sits on the map and names whichever overlay is showing", () => {
  const canvas = read(join("ui", "MapCanvas.qml"))
  const legend = read(join("ui", "LegendStrip.qml"))
  const panel = read("Panel.qml")

  // The legend is map chrome, mounted in the canvas next to the attribution —
  // not in the bar pill, which keeps its own one-line reading.
  assert.match(canvas, /LegendStrip \{\s*\n\s*id: legend/)
  assert.match(legend, /textFormat\s*:\s*Text\.PlainText/)
  assert.match(legend, /Color\.popups\.background/)

  // The radar legend names the palette the tile was requested in, the air
  // legend the layer the overlay draws; both come from the panel's selection,
  // never from a palette hardcoded here.
  assert.match(canvas, /schemeName: root\.legendSchemeName/)
  assert.match(canvas, /layerLabel: root\.legendLayerLabel/)
  assert.match(panel, /legendSchemeName: RadarModel\.colorSchemeName\(root\.colorSchemeId\)/)
  assert.match(panel, /legendLayerLabel: root\.activeLayer \? CamsModel\.layerLabel/)
})

// Strings that leave this plugin for components it does not own. Notification
// bodies are rendered by Omarchy's notification stack, which cannot be pinned
// to PlainText and whose body field is markup-capable.
test("notification bodies make the place name inert", () => {
  const source = read(join("lib", "Alerts.js"))

  // Both notifications a place name reaches — the storm alert and the AQ
  // breach — go through the same helper, so the count is part of the pin.
  const sites = source.match(/description \+= " at " \+ inertText\(locationName\)/g) || []
  assert.ok(sites.length >= 2,
    "a notification body builds its place name without inertText")
})
