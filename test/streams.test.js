const { test } = require("node:test")
const assert = require("node:assert")
const { readFileSync, readdirSync } = require("node:fs")
const { join } = require("node:path")
const { RadarModel } = require("./load.js")

// Every stream that reaches the shell process, pinned by name.
//
// The plugin does not run beside the desktop, it runs inside it: one process
// owns the bar, the panels, the lock screen and the polkit dialog. Anything
// collected whole into it is collected into all of that, so each stream needs
// a ceiling — and the ceilings that get forgotten are the ones nobody has
// written down. This list is the inventory, and the tests below hold the
// sources to it, so a stream added later fails here rather than turning up in
// a review.
//
// Where the ceilings live differs by path. The Open-Meteo and RainViewer
// requests are curl, and their ceilings sit in the RadarModel command
// builders, checked here against the numbers measured off the endpoints. The
// CAMS paths go through cams.py, which caps its own reads while streaming —
// pinned in test/cams.test.py and inventoried here as a document.

const ROOT = join(__dirname, "..")
const QML = ["BarWidget.qml", "BoundedProcess.qml", "Panel.qml", "Service.qml"]
  .concat(readdirSync(join(ROOT, "ui")).filter(name => name.endsWith(".qml")).map(name => "ui/" + name))

const source = Object.fromEntries(QML.map(name => [name, readFileSync(join(ROOT, name), "utf8")]))
const everything = Object.values(source).join("\n")

// `bounded` means it runs through BoundedProcess, which owns the answered
// flag and the one collector. `collects` marks the ones whose stdout is read
// back into this process at all — notifyProc hands a message to
// omarchy-notification-send and reads nothing back.
const PROCESSES = [
  { id: "manifestProc", file: "Service.qml", bounded: true, collects: true, builder: "manifestCommand" },
  { id: "camsInitProc", file: "Service.qml", bounded: true, collects: true, builder: null },
  { id: "aqProc", file: "Service.qml", bounded: true, collects: true, builder: null },
  { id: "forecastProc", file: "Service.qml", bounded: true, collects: true, builder: "forecastCommand" },
  { id: "notifyProc", file: "Service.qml", bounded: false, collects: false, builder: null },
  { id: "geocodeProc", file: "Panel.qml", bounded: true, collects: true, builder: "geocodingCommand" },
  { id: "locationSaveProc", file: "Panel.qml", bounded: true, collects: false, builder: null },
]

// Files read straight into the process, and why each one carries no ceiling
// of its own. locationFile is Omarchy's own state file and basemapFile is a
// vendored asset. The two CAMS files are this plugin's own directory, written
// by cams.py out of responses it capped while streaming, and distilled — the
// caps.json holds one small record per layer, never the document it came from.
const FILE_READS = [
  { id: "locationFile", file: "Service.qml" },
  { id: "basemapFile", file: "Service.qml" },
  { id: "camsCapsFile", file: "Service.qml" },
  { id: "camsStateFile", file: "Service.qml" },
]

function idsOf(pattern) {
  const found = []
  for (const [file, text] of Object.entries(source)) {
    for (const match of text.matchAll(pattern)) found.push({ id: match[1], file })
  }
  return found
}

// ------------------------------------------------------------------ inventory

test("the processes in the sources are the ones written down here", () => {
  // BoundedProcess.qml holds the component definition, not an instance.
  const found = idsOf(/(?:(?:Bounded)?Process) \{\s*\n\s*id: (\w+)/g)
    .filter(p => p.file !== "BoundedProcess.qml")
  assert.deepStrictEqual(
    found.map(p => `${p.file}:${p.id}`).sort(),
    PROCESSES.map(p => `${p.file}:${p.id}`).sort())
})

test("the file reads in the sources are the ones written down here", () => {
  const found = idsOf(/FileView \{\s*\n\s*id: (\w+)/g)
  assert.deepStrictEqual(
    found.map(f => `${f.file}:${f.id}`).sort(),
    FILE_READS.map(f => `${f.file}:${f.id}`).sort())
})

test("collection is centralised, and BoundedProcess is the one collector", () => {
  // Every stdout read in the tree is the one inside BoundedProcess.qml; a
  // second StdioCollector anywhere is a stream that skipped the inventory.
  const found = []
  for (const [file, text] of Object.entries(source)) {
    for (const match of text.matchAll(/StdioCollector/g)) found.push(file)
  }
  assert.deepStrictEqual(found, ["BoundedProcess.qml"])
})

test("the processes written down as bounded really are", () => {
  for (const process of PROCESSES.filter(p => p.bounded)) {
    const re = new RegExp(`BoundedProcess \\{\\s*\\n\\s*id: ${process.id}\\b`)
    assert.match(source[process.file], re, `${process.id} is not bounded`)
  }
})

// ------------------------------------------------------------------ ceilings

test("every request carries a ceiling on bytes as well as on time", () => {
  // `--max-time` bounds how long a transfer may run, not how much it may
  // deliver: a host that answers fast enough can send as much as the link
  // carries for the whole window.
  for (const name of ["manifestCommand", "geocodingCommand", "forecastCommand"]) {
    const command = name === "manifestCommand" ? RadarModel.manifestCommand()
      : name === "geocodingCommand" ? RadarModel.geocodingCommand("x", 5)
      : RadarModel.forecastCommand([{ latitude: 0, longitude: 0 }], 4, 2)

    assert.strictEqual(command[0], "curl", name)
    assert.ok(command.includes("--max-time"), `${name} has no time limit`)
    assert.ok(command.includes("--max-filesize"), `${name} has no size limit`)
    assert.ok(command.includes("-fsS"), `${name} would parse an error page as data`)

    const bytes = Number(command[command.indexOf("--max-filesize") + 1])
    const seconds = Number(command[command.indexOf("--max-time") + 1])
    assert.ok(bytes > 0 && bytes <= 1024 * 1024, `${name} caps at ${bytes} bytes`)
    assert.ok(seconds > 0 && seconds <= 30, `${name} waits up to ${seconds}s`)
  }
})

test("the ceilings leave room above what the endpoints actually return", () => {
  // Measured against the real endpoints, as upstream measured them: the
  // RainViewer manifest is 766 bytes, a five-result geocoding answer 1,834,
  // and a five-point forecast at the widest window this plugin asks for
  // 9,269. A ceiling under what the service really sends is an outage nobody
  // would think to look for.
  assert.ok(RadarModel.MANIFEST_MAX_BYTES >= 766 * 10)
  assert.ok(RadarModel.GEOCODING_MAX_BYTES >= 1834 * 10)
  assert.ok(RadarModel.FORECAST_MAX_BYTES >= 9269 * 10)
})

test("the CAMS helper is the one place the network is read without curl", () => {
  // The CAMS paths run through cams.py instead, and its ceilings are pinned
  // where its logic lives: one urlopen in the whole file, behind the
  // per-chunk budget of fetch_bytes, whose numbers are asserted in
  // test/cams.test.py against what the endpoints actually return.
  const camsPy = readFileSync(join(ROOT, "cams.py"), "utf8")
  assert.strictEqual((camsPy.match(/urlopen\(/g) || []).length, 1,
    "a second network read in cams.py is a stream that skipped its ceiling")
  assert.match(camsPy, /def fetch_bytes\(/, "the capped read path is missing")
  assert.match(camsPy, /max_bytes/, "fetch_bytes takes no budget")
  assert.match(camsPy, /CAPABILITIES_MAX_BYTES/)
  assert.match(camsPy, /PROBE_MAX_BYTES/)
  assert.match(camsPy, /LEGEND_MAX_BYTES/)
})

test("no request is built outside the places that put the ceilings on", () => {
  // A curl command assembled at a call site is a command that can be written
  // without the ceilings. The QML never mentions curl: its requests come from
  // the RadarModel builders, its CAMS calls from cams.py's argv.
  assert.ok(!/"curl"/.test(everything),
    "QML builds a curl command of its own")
})

// ------------------------------------------------------------------ answering

test("a fork that never ran is answered once, in BoundedProcess", () => {
  // A process that cannot be started emits neither `started` nor `exited` and
  // goes from running to not running in silence. BoundedProcess answers that
  // case centrally — with a flag reset on every launch, so a previous run's
  // answer can never mask the next one.
  const block = source["BoundedProcess.qml"]
  assert.match(block, /property bool answered: false/)
  assert.match(block, /function launch\([\s\S]{0,120}answered = false/)
  assert.match(block, /onRunningChanged[\s\S]{0,240}answered/,
    "BoundedProcess does not answer a fork that never ran")
})

test("no decision is taken in a collector, where the exit code does not exist yet", () => {
  // `onStreamFinished` fires before `onExited`, so a transfer cut short by a
  // ceiling would be read there as one that completed.
  assert.ok(!/onStreamFinished\s*:/.test(everything), "a collector is deciding something")
})

test("a flag that gates everything is cleared before the answer can return", () => {
  // `checking` and `aqChecking` gate the next check and what the UI shows
  // while waiting, so if either is left set the plugin does not degrade, it
  // freezes. Clearing them further down, past a guard on the exit code, is
  // the version of this that looks right.
  const start = source["Service.qml"].indexOf("function applyForecastResponse(")
  assert.ok(start > 0, "applyForecastResponse is missing from Service.qml")
  const body = source["Service.qml"].slice(start, start + 900)
  const cleared = body.indexOf("checking = false")
  const returns = body.indexOf("return")
  assert.ok(cleared > 0, "applyForecastResponse never clears checking")
  assert.ok(returns < 0 || cleared < returns,
    "applyForecastResponse can return before clearing checking")

  const aqStart = source["Service.qml"].indexOf("id: aqProc")
  const aqBody = source["Service.qml"].slice(aqStart, aqStart + 2000)
  assert.match(aqBody, /onResponded: function\([^)]*\) \{\s*\n\s*root\.aqChecking = false/,
    "aqProc answers before clearing its in-flight flag")
})

// ------------------------------------------------------------------ images

test("the radar and air tiles are decoded at the size they were asked for", () => {
  // Images are streams too, and their size is decided by whoever serves them.
  assert.match(source["ui/TileLayer.qml"], /sourceSize: Qt\.size\(/, "tiles decode unbounded")
  const air = source["ui/AirLayer.qml"]
  assert.strictEqual((air.match(/sourceSize: Qt\.size\(/g) || []).length, 2,
    "the CAMS overlay decodes unbounded")
})

test("the coverage probe is the one image decode without a ceiling, on purpose", () => {
  // Context2D reads pixels from an image it loaded itself. Handed an Image
  // item — which is what would carry a sourceSize — drawImage produces nothing
  // to read, and every location comes back reported as covered. There is no
  // form of this that both bounds the decode and answers the question.
  //
  // Pinned so that removing the exception means removing this test, rather
  // than the ceiling quietly never having been there.
  assert.match(source["ui/CoverageProbe.qml"], /loadImage\(source\)/)
  // The property assignment, not the word: the comment above it names it.
  assert.ok(!/sourceSize\s*:/.test(source["ui/CoverageProbe.qml"]),
    "if this ever gains a sourceSize, check it still reads pixels before believing it")

  // What bounds it instead.
  assert.strictEqual(RadarModel.isTileHost("https://tilecache.rainviewer.com"), true)
  assert.strictEqual(RadarModel.isTileHost("http://elsewhere"), false)
})

test("the host every tile URL is built from is checked before it is used", () => {
  assert.strictEqual(RadarModel.isTileHost("https://tilecache.rainviewer.com"), true)
  assert.strictEqual(RadarModel.isTileHost("http://tilecache.rainviewer.com"), false)
  assert.strictEqual(RadarModel.isTileHost("anything at all"), false)
})
