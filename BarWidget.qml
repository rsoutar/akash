import QtQuick
import qs.Commons
import "lib/Alerts.js" as Alerts
import "lib/Glyphs.js" as Glyphs
import "lib/Settings.js" as Settings
import qs.Ui

// Bar pill for akash.
//
// Structure follows the first-party pattern: the widget owns the button and
// lazily loads the panel, forwarding the open/close contract the bar's
// popout coordinator expects. All state comes from the plugin's service, so
// two monitors show the same thing without either of them polling.
BarWidget {
  id: root
  moduleName: "akash"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("akash") : null

  // Defined in Glyphs so the bar and the notification cannot drift.
  readonly property string icon: Glyphs.RADAR

  readonly property bool showLabel: Settings.showLabel(settings)
  readonly property string summary: service ? service.barSummary : ""
  readonly property int outlookLevel: service ? service.outlookLevel : 0

  // The air-quality pill: value + unit, tinted by severity. The full reading
  // lives in the tooltip, where there is room for layer, unit and band name.
  readonly property string aqSummary: service ? service.aqSummary : ""
  readonly property string aqPillText: service ? service.aqPillText : ""
  readonly property int aqBand: service && service.aqLevel ? service.aqLevel.band : -1

  readonly property color defaultForeground: bar ? bar.foreground : Color.foreground

  // Tint the pill when weather is on the way, the same way the stock
  // indicators signal state: accent for something worth knowing, urgent for
  // a severe outlook. Anything below that stays the ordinary bar foreground
  // so the bar does not become a christmas tree.
  readonly property color iconColor: {
    if (!service || !service.alertsEnabled) return defaultForeground
    if (outlookLevel >= Alerts.SEVERE) return Color.urgent
    if (outlookLevel >= Alerts.HEAVY) return Color.accent
    return defaultForeground
  }

  // The AQ pill tints the same way, from the EEA band. The band's own colours
  // are pale pastels that wash out on a light theme, so severity — not the
  // palette — is what reaches the bar: Moderate is accent, Poor and up are
  // urgent, and the tooltip names the band exactly.
  readonly property color aqColor: {
    if (aqBand >= 3) return Color.urgent
    if (aqBand === 2) return Color.accent
    return defaultForeground
  }

  // The shell injects `settings` into widgets but not into services, so the
  // widget forwards them. On a multi-monitor setup every bar instance writes
  // the same value, which is harmless — they all read the same shell.json
  // entry.
  function syncService() {
    if (root.service && "settings" in root.service) root.service.settings = root.settings
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: the bar identifies
  // a panel by the widget mounted in its slot, so open/close/opened have to
  // live on this root rather than on the nested panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: pillRow.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: { injectPanel(); syncService() }
  onServiceChanged: { injectPanel(); syncService() }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Row {
    id: pillRow
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(6)

    BarIconButton {
      id: button
      bar: root.bar
      // The label prints the alert's own outlook, so with alerts off there is
      // nothing for it to say and the icon stands alone.
      text: root.showLabel && root.summary !== "" ? root.icon + "  " + root.summary : root.icon
      foreground: root.iconColor
      slotSize: Style.bar.statusSlot
      // The full reading — layer, value, unit, band — fits in a tooltip and
      // nowhere else on a bar.
      tooltipText: root.aqSummary

      onPressed: function(b) {
        if (b === Qt.MiddleButton && root.service) root.service.checkNow()
        else root.togglePanel()
      }
    }

    // The air-quality figure, in the band's severity colour. Clickable like
    // the icon: it is the same panel.
    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.aqPillText !== ""
      text: root.aqPillText
      color: root.aqColor
      font.family: Style.font.family
      font.pixelSize: Style.font.caption

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.togglePanel()
      }
    }
  }
}
