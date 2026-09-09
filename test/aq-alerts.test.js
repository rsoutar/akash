const { test } = require("node:test")
const assert = require("node:assert")
const { loadLibrary } = require("./load.js")

const Alerts = loadLibrary("Alerts.js")

// The air-quality latch: one notification per episode, escalate-only
// re-notify, re-arm below threshold. Bands are CamsModel's EEA index:
// 0 Good … 5 Extremely poor, -1 no reading.

// ------------------------------------------------------------------- latch

test("no reading holds the latch rather than re-arming it", () => {
  // A broken probe is not an improvement in the air: dropping the latch here
  // would re-notify from stale data the moment a probe worked again.
  const decision = Alerts.decideAqNotification(-1, 3, 3, true)
  assert.strictEqual(decision.notify, false)
  assert.strictEqual(decision.notifiedBand, 3)
})

test("a band under the threshold clears the latch", () => {
  const decision = Alerts.decideAqNotification(1, 3, 3, true)
  assert.strictEqual(decision.notify, false)
  assert.strictEqual(decision.notifiedBand, 0)
})

test("a band at the threshold notifies once and holds", () => {
  const first = Alerts.decideAqNotification(3, 0, 3, true)
  assert.strictEqual(first.notify, true)
  assert.strictEqual(first.notifiedBand, 3)

  // Same band an hour later: one episode, one notification.
  const again = Alerts.decideAqNotification(3, first.notifiedBand, 3, true)
  assert.strictEqual(again.notify, false)
  assert.strictEqual(again.notifiedBand, 3)
})

test("a worse band escalates", () => {
  const decision = Alerts.decideAqNotification(4, 3, 3, true)
  assert.strictEqual(decision.notify, true)
  assert.strictEqual(decision.notifiedBand, 4)
})

test("a better band inside the threshold does not re-notify", () => {
  // Escalation is upward only; improving from Very poor to Poor while the
  // threshold is Poor is the same episode continuing.
  const decision = Alerts.decideAqNotification(3, 4, 3, true)
  assert.strictEqual(decision.notify, false)
  assert.strictEqual(decision.notifiedBand, 4)
})

test("dropping below the threshold re-arms", () => {
  const armed = Alerts.decideAqNotification(2, 4, 3, true)
  assert.strictEqual(armed.notifiedBand, 0)

  const renotified = Alerts.decideAqNotification(3, armed.notifiedBand, 3, true)
  assert.strictEqual(renotified.notify, true)
})

test("the switch off clears and silences", () => {
  const decision = Alerts.decideAqNotification(5, 4, 3, false)
  assert.strictEqual(decision.notify, false)
  assert.strictEqual(decision.notifiedBand, 0)
})

// ----------------------------------------------------------------- wording

test("the status line explains each state the watch can be in", () => {
  assert.strictEqual(Alerts.aqAlertStatus({ enabled: false }), "off")
  assert.strictEqual(Alerts.aqAlertStatus({ enabled: true, checking: true }), "checking…")
  assert.strictEqual(Alerts.aqAlertStatus({ enabled: true, checking: false, everAnswered: false }),
    "starting…")
  assert.strictEqual(Alerts.aqAlertStatus({
    enabled: true, everAnswered: true, hasReading: false, failing: true }),
    "cannot reach the reading")
  assert.strictEqual(Alerts.aqAlertStatus({
    enabled: true, everAnswered: true, hasReading: false, failing: false }),
    "starting…")
  assert.strictEqual(Alerts.aqAlertStatus({
    enabled: true, everAnswered: true, hasReading: true,
    reading: "PM2.5 38 µg/m3 · Poor", stale: false }),
    "PM2.5 38 µg/m3 · Poor")
  assert.strictEqual(Alerts.aqAlertStatus({
    enabled: true, everAnswered: true, hasReading: true,
    reading: "PM2.5 38 µg/m3 · Poor", stale: true }),
    "PM2.5 38 µg/m3 · Poor · not updating")
})

test("the toast names the figure, the worsening, and the place", () => {
  const text = Alerts.aqNotificationText({
    band: 4,
    bandName: "Very poor",
    currentBand: 3,
    worstBand: 4,
    worstBandName: "Very poor",
    worstClock: "15:00",
    layerShort: "PM2.5",
    value: 38.2,
    unit: "µg/m3"
  }, "Bangkok")
  assert.strictEqual(text.headline, "Very poor air quality worsening")
  assert.strictEqual(text.description, "PM2.5 38.2 µg/m3, reaching Very poor around 15:00 at Bangkok")
  // Very poor is worth interrupting someone over.
  assert.strictEqual(text.urgency, "critical")
})

test("an episode that is already at its worst does not promise a worsening", () => {
  const text = Alerts.aqNotificationText({
    band: 3,
    bandName: "Poor",
    currentBand: 3,
    worstBand: 3,
    worstBandName: "Poor",
    worstClock: "15:00",
    layerShort: "PM2.5",
    value: 30,
    unit: "µg/m3"
  }, "")
  assert.strictEqual(text.headline, "Poor air quality")
  assert.strictEqual(text.description, "PM2.5 30 µg/m3")
  assert.strictEqual(text.urgency, "normal")
})

test("a markup-shaped place name cannot reach the notification body", () => {
  const text = Alerts.aqNotificationText({
    band: 3, bandName: "Poor", currentBand: 3, worstBand: 3, worstBandName: "Poor",
    worstClock: "", layerShort: "PM2.5", value: 30, unit: ""
  }, '<img src="http://x">')
  assert.ok(!text.description.includes("<img"))
})
