import QtQuick
import qs.Commons
import qs.Ui

// One alert watch section: the heading, the line beneath it saying what the
// watch is doing, and the master switch — aligned against the whole of both,
// like the network panel's own section header.
//
// Neither of the alert types differs here except in words and wiring, so one
// component paints both. The heading and the status are one block with the
// switch centred against it: the two lines say what the watch is and what it
// is doing, which is a single thing; separating them by a section gap read as
// two.
Item {
  id: root

  property string title: ""
  property string status: ""
  property bool checked: false
  property bool busy: false
  property color foreground: Color.foreground

  signal toggled()

  implicitHeight: Math.max(heading.implicitHeight, switchControl.implicitHeight)

  Column {
    id: heading
    anchors.left: parent.left
    anchors.right: switchControl.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    PanelSectionHeader {
      text: root.title
      foreground: root.foreground
      fontFamily: Style.font.family
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.status
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      opacity: 0.55
      elide: Text.ElideRight
    }
  }

  ToggleSwitch {
    id: switchControl
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    checked: root.checked
    busy: root.busy
    foreground: root.foreground
    onToggled: root.toggled()
  }
}