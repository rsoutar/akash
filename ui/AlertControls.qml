import QtQuick
import qs.Commons
import qs.Ui
import "../lib/Alerts.js" as Alerts

// The storm alert controls, in the panel: turning the watch on is one click
// from the thing you are looking at, the way the audio panel keeps its mute
// switch beside the thing it mutes. It is also the only place they exist —
// a schema entry is not an interface.
//
// Laid out as the network panel lays out its band section — a heading, the
// switch that governs everything under it on the same line, and the choices
// below.
//
// Nothing here writes a setting. Persisting belongs to the panel, which owns
// the shell entry; this reports what the user asked for.
Column {
  id: root

  property var bar: null

  // The service. Read for its live check state, never written to.
  property var service: null

  property bool alertsEnabled: false
  property string locationState: "unset"
  property int alertLeadMinutes: 120
  property int alertRadiusKm: 100
  property var radiusPresets: []
  property string alertThreshold: "Heavy"
  property var thresholdOptions: []

  signal alertsToggled()
  signal radiusChosen(int km)
  signal thresholdChosen(string name)
  signal aqAlertsToggled()
  signal aqBandChosen(string name)

  property bool aqAlertsEnabled: false
  property string aqBandName: "Poor"
  property var aqBandOptions: []

  // Proof the air-quality switch is doing something. Wording lives in
  // Alerts.aqAlertStatus, where it can be tested.
  readonly property string aqStatus: Alerts.aqAlertStatus({
    enabled: aqAlertsEnabled,
    checking: service ? service.aqChecking === true : false,
    everAnswered: service ? service.aqCheckTime > 0 : false,
    failing: service ? service.aqFailures > 0 : false,
    hasReading: service ? isFinite(service.aqValue) : false,
    reading: service ? service.aqSummary : "",
    stale: service ? service.aqStale : false
  })

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color background: bar ? bar.background : Color.background

  // Proof the switch is doing something, rather than a silent toggle the user
  // has to take on faith. The wording lives in Alerts.alertStatus, which is
  // where it can be tested — it has been wrong twice.
  readonly property string alertStatus: Alerts.alertStatus({
    alertsEnabled: alertsEnabled,
    locationState: locationState,
    checking: service ? service.checking === true : false,
    everAnswered: service ? service.lastAnswerTime > 0 : false,
    failing: service ? service.consecutiveFailures > 0 : false,
    hasReading: service ? service.lastCheckTime > 0 : false,
    outlookLevel: service ? service.outlookLevel : 0,
    outlookLabel: service ? service.outlookLabel : "",
    outlookAtClock: service ? service.outlookAtClock : ""
  })

  // The heading and the line under it are one block, with the switch centred
  // against the whole of it rather than against the heading alone — see
  // ui/AlertSection.qml, shared by both watches.
  AlertSection {
    width: parent.width
    title: "STORM ALERTS"
    status: root.alertStatus
    checked: root.alertsEnabled
    busy: root.alertsEnabled && root.service ? root.service.checking : false
    foreground: root.foreground
    onToggled: root.alertsToggled()
  }

  // Only while alerts are on: with them off there is nothing to tune, and
  // the rings these control are not drawn either.
  ChoiceSection {
    width: parent.width
    visible: root.alertsEnabled
    bar: root.bar
    title: "ALERT RADIUS"
    // The kilometres are what the rings show; the hours are what the number
    // actually means. Saying both keeps the control honest about being an
    // approximation.
    caption: "about " + Alerts.humanizeLead(root.alertLeadMinutes) + " of warning"
    options: root.radiusPresets
    value: String(root.alertRadiusKm)
    onChosen: function(picked) {
      var km = parseInt(picked, 10)
      if (isFinite(km) && km !== root.alertRadiusKm) root.radiusChosen(km)
    }
  }

  // The radius decides how far ahead to look; this decides how bad it has to
  // be to be worth interrupting for. Without it, a two-hour window in a wet
  // season would fire on every passing shower, and the plugin would be
  // switched off — taking the alert that mattered with it.
  ChoiceSection {
    width: parent.width
    visible: root.alertsEnabled
    bar: root.bar
    title: "NOTIFY ME ABOUT"
    caption: Alerts.thresholdCaption(root.alertThreshold)
    options: root.thresholdOptions
    value: root.alertThreshold
    onChosen: function(picked) {
      if (picked !== root.alertThreshold) root.thresholdChosen(picked)
    }
  }

  // The air-quality watch, laid out like the storm's. It shares the probe
  // cadence — hourly, the model's own — rather than the storm's ten minutes,
  // because the model behind it updates no faster.
  AlertSection {
    width: parent.width
    title: "AIR QUALITY"
    status: root.aqStatus
    checked: root.aqAlertsEnabled
    busy: root.aqAlertsEnabled && root.service ? root.service.aqChecking : false
    foreground: root.foreground
    onToggled: root.aqAlertsToggled()
  }

  // Band cut-offs are per species — "Poor" is 25 µg/m³ of PM2.5 and 90 of
  // NO2 — so the threshold is a band name rather than a number, and means
  // the right concentration whatever layer the bar tracks.
  ChoiceSection {
    width: parent.width
    visible: root.aqAlertsEnabled
    bar: root.bar
    title: "AIR QUALITY THRESHOLD"
    caption: "on the layer the bar tracks"
    options: root.aqBandOptions
    value: root.aqBandName
    onChosen: function(picked) {
      if (picked !== root.aqBandName) root.aqBandChosen(picked)
    }
  }
}
