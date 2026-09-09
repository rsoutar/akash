import QtQuick
import qs.Commons
import qs.Ui
import "../lib/CamsModel.js" as CamsModel

// Which overlay the timeline drives, and which layer of that overlay is shown.
//
// The chips are one row of equal buttons — "Radar" first, then the CAMS
// categories the region actually has. Under the active chip, the category's
// layers render as a wrapping row of pills sized to their labels, because
// "PM2.5" and "Wildfire smoke" want different boxes and equal-width cells
// would leave a five-column table with three empty columns.
//
// The long tail (the ⚙ "Other" category, ~60 technical layers) gets a filter
// field rather than a sixty-pill row. A checklist of enabled layers, opacity
// sliders per layer and the style dropdown live in settings; this picker is
// the everyday path.
Column {
  id: root

  property var bar: null

  // Category ids, "radar" first. Computed by the panel from the caps cache.
  property var categories: []
  property string activeCategory: "radar"

  // Layer records for the active category (see CamsModel.layersForCategory).
  property var layers: []
  property string selectedLayerName: ""

  signal categoryChosen(string id)
  signal layerChosen(var layer)
  signal layerCleared()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  property string filterQuery: ""

  spacing: Style.space(6)

  Row {
    spacing: Style.space(6)

    Repeater {
      model: root.categories

      Button {
        required property var modelData
        text: modelData === "radar" ? "Radar" : (CamsModel.CATEGORY_LABELS[modelData] || modelData)
        fontSize: Style.font.bodySmall
        fontFamily: Style.font.family
        foreground: root.foreground
        background: root.bar ? root.bar.background : Color.background
        bordered: true
        active: modelData === root.activeCategory
        onClicked: root.categoryChosen(modelData)
      }
    }
  }

  // Only the long tail needs a filter; a category the curation already
  // narrowed to a handful of layers gets no field to ignore.
  TextField {
    width: parent.width
    visible: root.layers.length > 10
    placeholderText: "Filter layers"
    foreground: root.foreground
    font.family: Style.font.family
    onTextChanged: root.filterQuery = text
  }

  Flow {
    width: parent.width
    spacing: Style.space(6)

    Button {
      visible: root.selectedLayerName !== ""
      text: "✕"
      fontSize: Style.font.bodySmall
      fontFamily: Style.font.family
      foreground: root.foreground
      background: root.bar ? root.bar.background : Color.background
      bordered: true
      tooltipText: "Hide the overlay"
      onClicked: root.layerCleared()
    }

    Repeater {
      model: root.layers.filter(function(layer) {
        if (root.filterQuery === "") return true
        return CamsModel.layerLabel(layer).toLowerCase().indexOf(root.filterQuery.toLowerCase()) !== -1
      })

      Button {
        required property var modelData
        text: CamsModel.layerLabel(modelData)
        fontSize: Style.font.bodySmall
        fontFamily: Style.font.family
        foreground: root.foreground
        background: root.bar ? root.bar.background : Color.background
        bordered: true
        active: modelData.name === root.selectedLayerName
        onClicked: root.layerChosen(modelData)
      }
    }
  }
}
