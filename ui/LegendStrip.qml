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
// the tile actually renders (`RadarModel.radarLegendFamilies`), and the air bar
// from the EEA bands (`CamsModel.BAND_COLORS`), so the legend stays faithful to
// the picture the way DESIGN.md's Picture section demands. The radar ramp is a
// key rather than a histogram: its three colour families — grey tans, blues,
// yellow-through-red — share the strip equally, because laying it out by the
// tile's alpha scale would give the near-identical tans three quarters of the
// bar. Every label is drawn in the theme's ink so the strip reads on a light
// Omarchy theme and a dark one. The ends — "Cleaner → More polluted", "Less
// pollen → More pollen", "Trace" to "Severe" — are passed in by the panel,
// which owns which category the map is showing.
Item {
  id: root

  // "radar" paints RainViewer's ramp; any other value (an air-quality category
  // id) paints the CAMS bands under that category's name.
  property string mode: "radar"

  // Exposed so the legend names what it shows: the CAMS layer the air overlay
  // is drawn from and the two words for what the ends of the scale mean. The
  // radar ramp is one palette whichever scheme is requested, so it takes no
  // scheme name.
  property string layerLabel: ""
  property string lowEnd: ""
  property string highEnd: ""

  // The widget, when the map can provide one, for the theme's foreground ink.
  property var bar: null

  readonly property var airRows: CamsModel.airQualityLegend()

  readonly property string title: {
    if (mode === "radar") return "Radar"
    var category = CamsModel.CATEGORY_LABELS[mode] || "Air quality"
    return layerLabel !== "" ? category + " · " + layerLabel : category
  }

  // One named rung of whichever ramp is showing. Radar names are the three
  // colour families, each centred on the equal third it paints; air names are
  // the three levels the six EEA bands pair into, centred on their thirds too.
  readonly property var tiers: {
    if (mode === "radar") {
      var families = RadarModel.radarLegendFamilies()
      var tiers = []
      for (var i = 0; i < families.length; i++) {
        tiers.push({ name: families[i].name, fraction: (i + 0.5) / families.length })
      }
      return tiers
    }
    var airTiers = CamsModel.legendTiers()
    var out = []
    for (var k = 0; k < airTiers.length; k++) {
      out.push({ name: airTiers[k].name, fraction: (k + 0.5) / airTiers.length })
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

  readonly property color ink: root.bar ? root.bar.foreground : Color.foreground

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Color.popups.background
    border.width: 1
    border.color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.25)
    opacity: 0.94
  }

  Text {
    anchors.top: parent.top
    anchors.topMargin: Style.space(6)
    anchors.left: parent.left
    anchors.leftMargin: root.pad
    textFormat: Text.PlainText
    text: root.title + (root.endTitle !== "" ? " · " + root.endTitle : "")
    color: root.ink
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
    width: root.width - root.pad * 2
  }

  // The ramp itself, painted as a seamless gradient from the palette the tile
  // renders in. The radar ramp is keyed by colour family across equal thirds,
  // blending smoothly without seams.
  Canvas {
    id: ramp
    anchors.left: parent.left
    anchors.leftMargin: root.pad
    anchors.right: parent.right
    anchors.rightMargin: root.pad
    anchors.verticalCenter: parent.verticalCenter
    height: root.barHeight
    renderTarget: Canvas.FramebufferObject

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    Connections {
      target: root
      function onModeChanged() { ramp.requestPaint() }
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (width <= 0 || height <= 0) return

      var r = Math.min(height / 2, Style.space(3))
      ctx.beginPath()
      ctx.moveTo(r, 0)
      ctx.lineTo(width - r, 0)
      ctx.arcTo(width, 0, width, r, r)
      ctx.arcTo(width, height, width - r, height, r)
      ctx.lineTo(r, height)
      ctx.arcTo(0, height, 0, height - r, r)
      ctx.arcTo(0, 0, r, 0, r)
      ctx.closePath()
      ctx.clip()

      if (root.mode === "radar") {
        var families = RadarModel.radarLegendFamilies()
        if (families.length === 0) return
        var grad = ctx.createLinearGradient(0, 0, width, 0)
        for (var f = 0; f < families.length; f++) {
          var stops = families[f].stops
          var n = stops.length
          for (var i = 0; i < n; i++) {
            var frac = (f + (i + 0.5) / n) / families.length
            if (f === 0 && i === 0) grad.addColorStop(0.0, stops[i])
            grad.addColorStop(Math.min(1.0, Math.max(0.0, frac)), stops[i])
            if (f === families.length - 1 && i === n - 1) grad.addColorStop(1.0, stops[i])
          }
        }
        ctx.fillStyle = grad
        ctx.fillRect(0, 0, width, height)
      } else {
        var rows = root.airRows
        if (rows.length === 0) return
        var grad = ctx.createLinearGradient(0, 0, width, 0)
        for (var j = 0; j < rows.length; j++) {
          grad.addColorStop(j / Math.max(1, rows.length - 1), rows[j].color)
        }
        ctx.fillStyle = grad
        ctx.fillRect(0, 0, width, height)
      }
    }
  }

  // The band names, each centred on the length of bar that it names, at the bottom.
  Repeater {
    model: root.tiers

    Text {
      required property var modelData
      textFormat: Text.PlainText
      text: modelData.name
      color: root.ink
      font.family: Style.font.family
      font.pixelSize: Style.font.caption * 0.92
      anchors.horizontalCenter: parent.left
      anchors.horizontalCenterOffset: root.pad + modelData.fraction * root.stripSpan
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(6)
    }
  }
}
