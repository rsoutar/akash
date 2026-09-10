import QtQuick
import qs.Commons

// The panel's own top line: the plugin's name on the left, its live state on
// the right.
//
// The state is a dot that blinks like a terminal cursor — always blinking, so
// the panel never goes fully still — green while at rest and orange while a
// request is in flight. Green and orange are fixed literals rather than theme
// roles because the palette exposes neither; everything else is themed.
Item {
  id: root

  // True while any of the plugin's network work is in flight. The label and
  // the dot's colour both follow it.
  property bool fetching: false

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color liveColor: "#5FAF6F"
  readonly property color fetchColor: "#E08A3C"

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(title.implicitHeight, statusRow.implicitHeight)

  Text {
    id: title
    textFormat: Text.PlainText
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    text: "Akash"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
    font.bold: true
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
