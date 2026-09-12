import QtQuick
import qs.Commons

// The panel's own top line: the plugin's name on the left, its live state on
// the right.
//
// The state is a dot that blinks like a terminal cursor — always blinking, so
// the panel never goes fully still — green while at rest and orange while a
// request is in flight. Green and orange are fixed literals rather than theme
// roles because the palette exposes neither; everything else is themed.
//
// Between the location and the state sits how long ago the newest radar
// picture was published: "just now" or "10 min ago", dimmed like the city and
// fed by the service. The city elides first, so the readout and the state
// stay put whatever a long saved name does to the middle of the row.
Item {
  id: root

  // True while any of the plugin's network work is in flight. The label and
  // the dot's colour both follow it.
  property bool fetching: false

  // The configured location, shown dimmed right of the plugin's name. Empty
  // shows a prompt in its place. Clicking starts the location search.
  property string locationName: ""

  // When the newest radar frame was published, said as an age: "just now",
  // "10 min ago". Empty (never mind "Live"/locating) shows nothing.
  property string updatedAgo: ""

  signal locationClicked()

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color liveColor: "#5FAF6F"
  readonly property color fetchColor: "#E08A3C"

  // The status cluster sits on this many spacing units from the right edge;
  // the location text ends there rather than colliding with it.
  readonly property real statusSpace: Style.space(6)

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(titleRow.implicitHeight, statusRow.implicitHeight)

  Row {
    id: titleRow
    anchors.left: parent.left
    anchors.right: statusRow.left
    anchors.rightMargin: root.statusSpace
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(4)

    Text {
      id: title
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: "Akash"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.locationName !== ""
      text: "·"
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }

    // The location, dimmed as a quiet fact about where the radar is centred.
    // It is readable but never competes with the title. Clicking it starts
    // the location search, exactly as the LOCATION section's pencil used to.
    Item {
      id: locationHost
      anchors.verticalCenter: parent.verticalCenter
      // Track the drawn (possibly elided) text so the click target matches
      // what is actually visible.
      width: locationNameText.width
      height: locationNameText.height

      Text {
        id: locationNameText
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.top: parent.top
        text: root.locationName
        color: Qt.darker(root.foreground, 1.4)
        opacity: 0.85
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        // A long saved name must never shove the status cluster off the
        // header's right edge, so it ends where the cluster begins — and
        // yields to the latest-update readout first, which sits between the
        // city and the cluster.
        width: Math.max(0, Math.min(implicitWidth, titleRow.width - title.width - root.statusSpace - Style.space(8)
          - (updatedAgoText.visible ? updatedAgoText.implicitWidth + Style.space(4) : 0)))
        elide: Text.ElideRight
      }

      MouseArea {
        id: locationMouseArea
        anchors.fill: parent
        visible: root.locationName !== ""
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.locationClicked()
      }
    }

    // A dim prompt when nothing is configured. Clicking it starts the same
    // edit flow, so the affordance is discoverable even before a location
    // exists.
    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.locationName === ""
      text: "Set a location"
      color: Qt.darker(root.foreground, 1.5)
      opacity: 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.locationClicked()
      }
    }

    // How long ago the newest radar frame was published, the header's quiet
    // answer to "is this up to date?": "just now" under five minutes, then
    // the loop's own five-minute rounding. Hidden, it collapses — a fresh
    // load, before any manifest, reads as no readout at all rather than a
    // blank line. Never grows with the city: the city elides first, so this
    // text and the status cluster keep their places whatever the name does.
    Text {
      id: updatedAgoText
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.updatedAgo !== ""
      text: root.updatedAgo
      color: Qt.darker(root.foreground, 1.5)
      opacity: 0.7
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Row {
    id: statusRow
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(6)

    Rectangle {
      id: dot
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(7)
      height: width
      radius: width / 2
      color: root.fetching ? root.fetchColor : root.liveColor

      // Solid green at rest; only the fetching dot pulses, so a steady state
      // reads as steady rather than as an alarm that never stops.
      property real pulse: 1.0
      opacity: root.fetching ? pulse : 1.0

      SequentialAnimation on pulse {
        running: root.fetching
        loops: Animation.Infinite
        NumberAnimation { to: 0.2; duration: 500; easing.type: Easing.InOutQuad }
        NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutQuad }
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.fetching ? "Fetching" : "Live"
      color: root.fetching ? root.fetchColor : root.liveColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }
}
