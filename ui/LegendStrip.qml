import QtQuick
import qs.Commons
import qs.Ui
import "../lib/RadarModel.js" as RadarModel
import "../lib/CamsModel.js" as CamsModel

// What the map's colours mean.
//
// The map draws two kinds of tile: a radar frame from RainViewer and a CAMS
// air-quality overlay. Neither carries its own legend, so this strip sits
// docked under the map in the panel and names the ramp the map is drawing. It
// lives below the map, at the map's width, so it reads as part of the map
// without covering the corner of it — and it stays out of the bar pill, which
// keeps its own, briefer language.
//
// Colours here are data, not chrome: the radar bar is painted from the palette
// the tile actually renders (`RadarModel.radarGradientStops`), and the air bar
// from the EEA bands (`CamsModel.BAND_COLORS`), so the legend stays faithful to
// the picture the way DESIGN.md's Picture section demands. Every label is
// drawn in the theme's ink so the strip reads on a light Omarchy theme and a
// dark one. The ends — "Cleaner → More polluted", "Less pollen → More pollen",
// "Trace" to "Severe" — are passed in by the panel, which owns which category
// the map is showing.
Item {
  id: root

  // "radar" paints RainViewer's ramp; any other value (an air-quality category
  // id) paints the CAMS bands under that category's name.
  property string mode: "radar"

  // Exposed so the legend names what it shows: the palette the radar is
  // requested in, the CAMS layer the air overlay is drawn from, and the two
  // words for what the ends of the scale mean.
  property string schemeName: ""
  property string layerLabel: ""
  property string lowEnd: ""
  property string highEnd: ""

  // The widget, when the map can provide one, for the theme's foreground ink.
  property var bar: null

  readonly property var airRows: CamsModel.airQualityLegend()

  readonly property string title: {
    if (mode === "radar") return "Radar · " + schemeName
    var category = CamsModel.CATEGORY_LABELS[mode] || "Air quality"
    return layerLabel !== "" ? category + " · " + layerLabel : category
  }

  // One named rung of whichever ramp is showing. Radar names come from the
  // intensity ladder the band table owns and sit at the band's own place on
  // the 0-255 scale; air names are the EEA rungs, spread evenly over the six
  // band colours.
  readonly property var tiers: {
    if (mode === "radar") {
      var bands = RadarModel.radarLegendBands()
      var tiers = []
      for (var i = 0; i < bands.length; i++) {
        tiers.push({ name: bands[i].name, fraction: RadarModel.radarLegendFraction(bands[i].value) })
      }
      return tiers
    }
    var rows = airRows
    var out = []
    for (var k = 0; k < rows.length; k++) {
      out.push({ name: rows[k].name, fraction: rows.length === 1 ? 0 : rows[k].index / (rows.length - 1) })
    }
    return out
  }

  readonly property string endTitle: {
    if (lowEnd === "" && highEnd === "") return ""
    if (lowEnd === "" || highEnd === "") return lowEnd + highEnd
    return lowEnd + " → " + highEnd
  }

  readonly property int pad: Style.space(10)
  readonly property int barHeight: Style.space(6)

  // The bar's paintable length, so the labels and the paint share a measure.
  readonly property real stripSpan: Math.max(1, root.width - root.pad * 2)

  implicitWidth: root.pad * 2 + Style.space(224)
  implicitHeight: Style.space(52)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Color.popups.background
    border.width: 1
    border.color: root.bar ? root.bar.foreground : Color.foreground
    opacity: 0.94
  }

  Text {
    anchors.top: parent.top
    anchors.topMargin: Style.space(4)
    anchors.left: parent.left
    anchors.leftMargin: root.pad
    textFormat: Text.PlainText
    text: root.title + (root.endTitle !== "" ? " · " + root.endTitle : "")
    color: root.bar ? root.bar.foreground : Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
    width: root.width - root.pad * 2
  }

  // The ramp itself, painted from the palette the tile renders in. RainViewer
  // quantises the ramp to a handful of steps and so does this: the paint draws
  // one solid run per stop rather than a smooth gradient two timers' worth of
  // pixels were squashed to.
  Canvas {
    id: ramp
    x: root.pad
    y: Style.space(17)
    width: root.width - root.pad * 2
    height: root.barHeight
    renderTarget: Canvas.FramebufferObject

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (width <= 0 || height <= 0) return

      if (root.mode === "radar") {
        var stops = RadarModel.RADAR_GRADIENT_STOPS
        var values = RadarModel.RADAR_STOP_VALUES
        if (stops.length === 0) return
        // Each cell spans its own share of the 0-255 scale the bins sit on,
        // bounded by the midpoints of its neighbours, so a label anchored at
        // value/255 lands on the colour of the bin that value belongs to.
        // The first cell reaches back to the strip's edge and the last runs
        // to the right end, so the ramp fills the bar it lives in.
        for (var i = 0; i < stops.length; i++) {
          var start = i === 0 ? 0 : (values[i - 1] + values[i]) / 2
          var end = i === stops.length - 1 ? 255 : (values[i] + values[i + 1]) / 2
          var left = Math.round(start / 255 * width)
          var right = Math.round(end / 255 * width)
          if (right <= left) continue
          ctx.fillStyle = stops[i]
          ctx.fillRect(left, 0, right - left, height)
        }
      } else {
        var rows = root.airRows
        if (rows.length === 0) return
        var gap = 2
        var cell = (width - gap * (rows.length - 1)) / rows.length
        for (var j = 0; j < rows.length; j++) {
          ctx.fillStyle = rows[j].color
          ctx.fillRect(Math.round(j * (cell + gap)), 0, Math.ceil(cell), height)
        }
      }
    }
  }

  // The band names, each centred on the length of bar that it names.
  Repeater {
    model: root.tiers

    Text {
      required property var modelData
      textFormat: Text.PlainText
      text: modelData.name
      color: root.bar ? root.bar.foreground : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption * 0.92
      anchors.horizontalCenter: parent.left
      anchors.horizontalCenterOffset: root.pad + modelData.fraction * root.stripSpan
      anchors.top: parent.top
      anchors.topMargin: Style.space(20)
    }
  }
}