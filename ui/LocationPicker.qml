import QtQuick
import qs.Commons
import qs.Ui
import "../lib/Glyphs.js" as Glyphs

// The location row and its search results, mirroring the stock weather
// widget's picker so both offer the same candidates for the same query.
//
// The location itself belongs to Omarchy, not to this plugin: it lives in
// omarchy-weather-location's own state file, which the stock weather widget
// reads too. Nothing here writes it. The panel does the saving, and only
// because the user asked — a plugin that wrote shared state on its own
// opinion would be overwriting configuration it does not own.
Column {
  id: root

  property var bar: null

  property string locationName: ""
  property string locationState: "unset"
  property bool coverageMissing: false

  property bool editing: false
  property bool saving: false
  property var suggestions: []
  property int suggestionIndex: 0

  // Which entry the edit session is using: "city" is the geocoding search,
  // "coordinates" is exact GPS lat/lon. A typed coordinate is not a second
  // location — it is a sharper version of the same one, stored through the
  // same shared weather.json.
  property string editingMode: "city"

  // The search text. The panel reads it to commit and writes it to seed the
  // field, so it is exposed rather than mirrored.
  property alias query: locationField.text

  // The coordinate edit's three fields, exposed like `query` so the panel
  // reads them at commit and seeds them when the edit starts.
  property alias coordinateName: coordNameField.text
  property alias coordinateLatitude: coordLatField.text
  property alias coordinateLongitude: coordLonField.text

  // Why a coordinate commit was refused, shown until the next edit. Empty
  // (the resting state) shows nothing.
  property string coordinateError: ""

  signal editRequested()
  signal cancelRequested()
  signal commitRequested()
  signal clearRequested()
  signal queryEdited()
  signal suggestionHighlighted(int index)
  signal suggestionPicked(var suggestion)
  signal modeSwitchRequested(var mode)
  signal coordinateCommitRequested()

  readonly property color foreground: bar ? bar.foreground : Color.foreground

  // Whether any edit field currently owns the keyboard, so a parent can hang
  // its key-catcher temporarily — typing "s" in the middle of a latitude must
  // edit, not close the settings page.
  readonly property bool fieldFocused: locationField.activeFocus
    || coordNameField.activeFocus || coordLatField.activeFocus || coordLonField.activeFocus

  function focusQuery() {
    locationField.forceActiveFocus()
  }

  // The same for the coordinate fields, which the panel calls after a mode
  // switch so the session picks up on the name rather than a hidden field.
  function focusCoordinates() {
    coordNameField.forceActiveFocus()
  }

  Item {
    width: parent.width
    height: Style.spacing.controlHeight

    // Resting state: the current city, the pencil to change it, and any
    // warnings. The name leads so the row says what the location is; the
    // pencil is the affordance; the warnings are the facts.
    Row {
      visible: !root.editing
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      // The city in the body size, dimmed when nothing is configured so the
      // empty state reads as a prompt rather than as an answer.
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.locationName !== "" ? root.locationName : "Set a location"
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        opacity: root.locationName !== "" ? 1 : 0.6
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: Glyphs.PENCIL
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        opacity: 0.45
      }

      // Both warnings sit here rather than over the map: they are facts
      // about the configured location, not about whatever the view happens
      // to be showing.
      //
      // A name saved with nothing picked behind it is stored, and is a
      // location for the stock weather widget, which resolves names itself.
      // Here it is a name and nothing else — no point to centre on, no
      // coordinate to forecast for — and the map going quiet is otherwise
      // the only sign of it.
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: root.locationState === "unresolved"
        text: "no coordinates — pick one from the list"
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        opacity: 0.9
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: root.coverageMissing
        text: "no radar coverage"
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        opacity: 0.9
      }
    }

    MouseArea {
      anchors.fill: parent
      visible: !root.editing
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.editRequested()
    }

    Row {
      visible: root.editing && root.editingMode !== "coordinates"
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      TextField {
        id: locationField
        width: Style.space(220)
        enabled: !root.saving
        placeholderText: "Search city"
        foreground: root.foreground
        font.family: Style.font.family

        onTextChanged: if (root.editing && !root.saving) root.queryEdited()

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancelRequested()
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            if (root.suggestionIndex < root.suggestions.length - 1) {
              root.suggestionHighlighted(root.suggestionIndex + 1)
            }
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            if (root.suggestionIndex > 0) root.suggestionHighlighted(root.suggestionIndex - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.commitRequested()
            event.accepted = true
          }
        }
      }

      // Clear back to IP auto-detect; becomes a spinner while saving.
      Rectangle {
        width: Style.space(18)
        height: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        radius: Math.min(4, Style.cornerRadius)
        color: !root.saving && clearLocationArea.containsMouse
          ? Style.hoverFillFor(root.foreground, Color.accent)
          : "transparent"

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: root.saving ? Glyphs.PROGRESS_CLOCK : "✕"
          font.family: Style.font.family
          color: Qt.darker(root.foreground, 1.4)
          font.pixelSize: Style.font.bodySmall

          RotationAnimator on rotation {
            running: root.saving
            from: 0
            to: 360
            duration: 800
            loops: Animation.Infinite
          }
        }

        MouseArea {
          id: clearLocationArea
          anchors.fill: parent
          hoverEnabled: true
          enabled: !root.saving
          cursorShape: Qt.PointingHandCursor
          onClicked: root.clearRequested()
        }
      }
    }

    // Exact GPS coordinates: a name (what the header shows) plus a lat/lon
    // pair, entered as text. The panel validates on commit and refuses with a
    // reason rather than saving a point on the wrong street.
    Row {
      visible: root.editing && root.editingMode === "coordinates"
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      TextField {
        id: coordNameField
        width: Style.space(140)
        enabled: !root.saving
        placeholderText: "Name"
        foreground: root.foreground
        font.family: Style.font.family

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancelRequested()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.coordinateCommitRequested()
            event.accepted = true
          }
        }
      }

      TextField {
        id: coordLatField
        width: Style.space(92)
        enabled: !root.saving
        placeholderText: "Latitude"
        foreground: root.foreground
        font.family: Style.font.family

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancelRequested()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.coordinateCommitRequested()
            event.accepted = true
          }
        }
      }

      TextField {
        id: coordLonField
        width: Style.space(92)
        enabled: !root.saving
        placeholderText: "Longitude"
        foreground: root.foreground
        font.family: Style.font.family

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancelRequested()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.coordinateCommitRequested()
            event.accepted = true
          }
        }
      }

      Button {
        // A clicked save can land twice before the panel's `savingLocation`
        // latch is set; the guard in commitCoordinates() is what stops it.
        text: "Save"
        fontSize: Style.font.bodySmall
        fontFamily: Style.font.family
        foreground: root.foreground
        accent: Color.accent
        background: "transparent"
        bordered: true
        onClicked: root.coordinateCommitRequested()
      }
    }
  }

  // Which entry the edit is in, offered beside the search so the GPS path is
  // discoverable rather than hidden behind a setting. The active chip is
  // filled the way the suggestion rows are; a switch is immediate and the
  // panel re-focuses the right field.
  Row {
    visible: root.editing
    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: "SET BY"
      color: Qt.darker(root.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      width: cityChipText.implicitWidth + Style.space(14)
      height: cityChipText.implicitHeight + Style.space(6)
      radius: Math.min(4, Style.cornerRadius)
      color: root.editingMode === "city"
        ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

      Text {
        id: cityChipText
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: "City"
        color: root.editingMode === "city"
          ? Style.hoverStateColor(root.foreground, Color.accent) : root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.modeSwitchRequested("city")
      }
    }

    Rectangle {
      width: coordChipText.implicitWidth + Style.space(14)
      height: coordChipText.implicitHeight + Style.space(6)
      radius: Math.min(4, Style.cornerRadius)
      color: root.editingMode === "coordinates"
        ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

      Text {
        id: coordChipText
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: "GPS coordinates"
        color: root.editingMode === "coordinates"
          ? Style.hoverStateColor(root.foreground, Color.accent) : root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.modeSwitchRequested("coordinates")
      }
    }
  }

  // Why a coordinate commit was refused: the pair is out of range, or it has
  // no name to show in the header. Its own line so the message never crowds
  // the chips, styled like the resting warnings and kept close to the fields.
  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: root.editingMode === "coordinates" && root.coordinateError !== ""
    text: root.coordinateError
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    opacity: 0.9
    wrapMode: Text.WordWrap
  }

  Column {
    width: parent.width
    spacing: 0
    visible: root.editing && root.editingMode === "city" && !root.saving
      && root.suggestions.length > 0

    Repeater {
      model: root.suggestions

      Rectangle {
        required property var modelData
        required property int index

        readonly property bool highlighted: index === root.suggestionIndex

        width: parent.width
        height: suggestionRow.implicitHeight + Style.space(12)
        radius: Style.cornerRadius
        color: highlighted ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

        Row {
          id: suggestionRow
          anchors.left: parent.left
          anchors.leftMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: modelData.name
            color: highlighted ? Style.hoverStateColor(root.foreground, Color.accent) : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            text: modelData.description
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPositionChanged: root.suggestionHighlighted(index)
          onClicked: root.suggestionPicked(modelData)
        }
      }
    }
  }
}
