import QtQuick
import qs.Commons
import qs.Ui
import "../lib/Glyphs.js" as Glyphs

// Transport for the animated overlay loop: play/pause, a scrubber over the
// available frames, and the timestamp of the one on screen.
//
// The panel owns playback state; this reports intent and renders what it is
// given, so the same state drives the keyboard shortcuts without a second
// copy of it living down here. Generic over the frame source: radar past
// frames and CAMS forecast steps fit the same model.
Item {
  id: root

  // The bar this panel belongs to. `bar.foreground` already resolves the
  // surface for where the panel is mounted, which the global colour does not.
  property var bar: null

  property var frames: []
  property int frameIndex: 0
  property bool playing: false
  property string frameLabel: "--:--"
  // How far behind now the shown frame is — "35 min ago" while replaying or
  // scrubbed back, empty on the newest frame. Radar past frames only; a
  // forecast step has no ago.
  property string frameAgo: ""
  property bool isLatestFrame: true

  // Label box width. Fixed rather than implicit so the slider's anchor chain
  // cannot resize mid-drag, but the owner chooses it: a radar label stacks
  // the clock over "1 h 55 m ago", a CAMS step label names the day too.
  property int labelWidth: 0

  signal playToggled()
  signal frameRequested(int index)

  readonly property color foreground: bar ? bar.foreground : Color.foreground

  // Sources with no replay — a CAMS forecast is shown as its latest step, not
  // scrubbed — hide the whole transport row. Radar past frames keep it.
  property bool replayable: true

  height: Style.spacing.controlHeight
  visible: root.replayable && frames.length > 1

  Button {
    id: playButton
    anchors.left: parent.left
    anchors.leftMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    text: root.playing ? Glyphs.PAUSE : Glyphs.PLAY
    fontFamily: Style.font.family
    foreground: root.foreground
    tooltipText: root.playing ? "Pause (Enter)" : "Play the loop (Enter)"
    onClicked: root.playToggled()
  }

  PanelSlider {
    id: timeline
    anchors.left: playButton.right
    anchors.right: frameTime.left
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    bar: root.bar
    minimum: 0
    maximum: Math.max(1, root.frames.length - 1)
    integer: true
    step: 1
    tickCount: root.frames.length
    value: root.frameIndex
    onMoved: function(value) { root.frameRequested(Math.round(value)) }
  }

  // Fixed width, and no suffix that appears and disappears. The label sits
  // at the end of the slider's anchor chain, so any change to its width
  // resizes the track — which, mid-drag, slides the knob out from under the
  // pointer. The box is sized for its widest line whatever is showing, so
  // the "ago" line arriving and leaving cannot do that either.
  Column {
    id: frameTime
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    width: root.labelWidth > 0 ? root.labelWidth : Style.space(44)
    spacing: 0

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignRight
      text: root.frameLabel
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      opacity: root.isLatestFrame ? 0.9 : 0.6
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignRight
      visible: root.frameAgo !== ""
      text: root.frameAgo
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption * 0.85
      opacity: 0.5
    }
  }
}
