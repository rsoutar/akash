import QtQuick
import qs.Commons
import "../lib/Basemap.js" as Basemap

// The ground under the overlays, drawn from geometry that ships with the
// plugin.
//
// Colour here is chrome, not data. The radar's palette encodes reflectivity
// and must stay fixed whatever the theme, but the coastline it sits on is
// just a coastline: it takes its tones from the theme like everything else,
// so the map belongs to whichever of Omarchy's themes is running rather than
// to the one it was built against.
//
// Every tone is mixed between the panel surface's own background and text —
// `Color.popups.*` rather than the global colours, because a theme overrides
// those roles independently and a panel painted with the global background is
// wrong in the themes that do. Mixing rather than naming colours is what
// makes the same code work on a light theme: the ground stays near the
// surface it sits on, and the ink stays near the text beside it.
Canvas {
  id: root

  property var basemap: null
  property real centerLatitude: 0
  property real centerLongitude: 0
  property int zoom: 7

  // Drawn in this order, back to front. Taken from a list here rather than
  // from the file's own order, so what sits on top of what is a decision in
  // the renderer and not an accident of how the data was generated.
  readonly property var drawOrder: ["land-lo", "land", "lakes", "urban", "rivers", "admin1", "admin0"]

  readonly property color surface: Color.popups.background
  readonly property color ink: Color.popups.text

  function mix(from, to, amount) {
    return Qt.rgba(from.r + (to.r - from.r) * amount,
                   from.g + (to.g - from.g) * amount,
                   from.b + (to.b - from.b) * amount,
                   1)
  }

  // Sea sits just off the surface so the panel does not read as a hole, land
  // lifts off the sea, and everything drawn on land is ink at a weight that
  // says how much attention it wants.
  readonly property color seaColor: mix(surface, ink, 0.05)
  readonly property color landColor: mix(surface, ink, 0.13)
  readonly property color urbanColor: mix(surface, ink, 0.21)
  readonly property color coastColor: mix(surface, ink, 0.34)
  readonly property color riverColor: mix(surface, ink, 0.26)
  readonly property color admin1Color: mix(surface, ink, 0.22)
  readonly property color admin0Color: mix(surface, ink, 0.42)
  readonly property color labelColor: mix(surface, ink, 0.72)
  readonly property color dotColor: mix(surface, ink, 0.55)

  readonly property int labelSize: Math.round(Style.font.caption * 0.92)

  // Anything that changes the picture asks for a repaint. Qt folds repeated
  // requests into the next frame on its own, so a drag does not queue one
  // per mouse event.
  onBasemapChanged: requestPaint()
  onCenterLatitudeChanged: requestPaint()
  onCenterLongitudeChanged: requestPaint()
  onZoomChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  onSurfaceChanged: requestPaint()
  onInkChanged: requestPaint()

  renderTarget: Canvas.FramebufferObject

  // Add one feature's rings to the current path. `outline` asks for the shape
  // as a coastline rather than as a closed area, which breaks it wherever the
  // stored polygon runs along the edge of the projection to close itself.
  function tracePaths(ctx, layer, index, view, outline) {
    var paths = Basemap.featurePaths(layer, index, view, undefined, outline === true)
    for (var p = 0; p < paths.length; p++) {
      var path = paths[p]
      ctx.moveTo(path[0], path[1])
      for (var c = 2; c < path.length; c += 2) ctx.lineTo(path[c], path[c + 1])
    }
  }

  // Both helpers walk every copy of the world the viewport overlaps, since
  // the world repeats east-west and a view straddling the antimeridian draws
  // the same stored geometry twice, at two offsets.

  // Per-layer render style: fill colour, optional coastline stroke and width.
  // A table instead of a branch per layer name in onPaint, so adding a layer
  // is adding a row rather than another `else if`.
  readonly property var layerStyles: {
    "land":    { fill: landColor,   stroke: coastColor, width: 1   },
    "land-lo": { fill: landColor,   stroke: coastColor, width: 1   },
    "lakes":   { fill: seaColor,    stroke: coastColor, width: 0.8 },
    "urban":   { fill: urbanColor },
    "rivers":  { stroke: riverColor, width: 0.9 },
    "admin1":  { stroke: admin1Color, width: 0.8 },
    "admin0":  { stroke: admin0Color, width: 1.1 }
  }

  // Filled layers are drawn one feature at a time.
  //
  // What cuts a lake out of the island it sits in is winding: the rule is
  // nonzero, and every interior ring in data/basemap.bin runs opposite the
  // exterior around it, so the lake subtracts. That is the whole mechanism,
  // so the basemap tests hold it — a rebuild that emitted a hole wound the
  // same way as its exterior would paint the lake as land, and nothing on
  // this side would report it.
  //
  // It has to be scoped to the feature that owns the hole. In a path holding
  // a whole layer, one feature's hole ring lands over another feature's
  // interior and cancels it, leaving a gap showing whatever is underneath —
  // a patch of sea over land that appears and disappears as panning changes
  // which features are in the path.
  function fillLayer(ctx, layer, view, window, offsets, style) {
    for (var o = 0; o < offsets.length; o++) {
      var copyWindow = Basemap.shiftWindow(window, offsets[o])
      var copyView = Basemap.shiftView(view, offsets[o])
      var indices = Basemap.featuresInBounds(layer, copyWindow)
      for (var i = 0; i < indices.length; i++) {
        ctx.beginPath()
        tracePaths(ctx, layer, indices[i], copyView, false)
        ctx.fillStyle = style.fill
        ctx.fill()
        if (style.stroke !== undefined) {
          // A shape cut open to be drawn on a cylinder has to be traced
          // twice: the fill needs the ring closed, the coastline must leave
          // out the edge that closes it. Only a handful of features are cut
          // that way, so the rest are stroked from the path already in hand.
          if (Basemap.featureTouchesDomainEdge(layer, indices[i])) {
            ctx.beginPath()
            tracePaths(ctx, layer, indices[i], copyView, true)
          }
          ctx.strokeStyle = style.stroke
          ctx.lineWidth = style.width
          ctx.stroke()
        }
      }
    }
  }

  // Stroked layers have no interior, so the whole layer is one path and one
  // stroke.
  function strokeLayer(ctx, layer, view, window, offsets, style) {
    ctx.beginPath()
    for (var o = 0; o < offsets.length; o++) {
      var copyWindow = Basemap.shiftWindow(window, offsets[o])
      var copyView = Basemap.shiftView(view, offsets[o])
      var indices = Basemap.featuresInBounds(layer, copyWindow)
      for (var i = 0; i < indices.length; i++) tracePaths(ctx, layer, indices[i], copyView, false)
    }
    ctx.strokeStyle = style.stroke
    ctx.lineWidth = style.width
    ctx.stroke()
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()

    // Chosen rather than inherited. QtQuick's Context2D.fill() takes no
    // argument — `fill("evenodd")` reads like a rule and is discarded — so
    // the rule is whatever `fillRule` holds, and reset() leaves that at
    // Qt.WindingFill. Naming it is what stops the renderer and the data from
    // disagreeing without saying so.
    ctx.fillRule = Qt.WindingFill

    ctx.fillStyle = seaColor
    ctx.fillRect(0, 0, width, height)

    if (!basemap || width <= 0 || height <= 0) return

    var view = {
      centerLatitude: root.centerLatitude,
      centerLongitude: root.centerLongitude,
      zoom: root.zoom,
      width: root.width,
      height: root.height
    }

    var window = Basemap.viewBounds(view)
    var offsets = Basemap.worldOffsets(window)

    for (var d = 0; d < drawOrder.length; d++) {
      var name = drawOrder[d]
      var layer = basemap.layers[name]
      var style = layerStyles[name]
      if (!style || !Basemap.layerAppliesAt(layer, view.zoom)) continue
      if (style.fill !== undefined) fillLayer(ctx, layer, view, window, offsets, style)
      else strokeLayer(ctx, layer, view, window, offsets, style)
    }

    var places = Basemap.placesInView(basemap.layers["places"], view, {
      labelWidth: Style.space(64),
      labelHeight: Style.space(13),
      limit: 45
    })
    if (places.length === 0) return

    ctx.font = root.labelSize + "px \"" + Style.font.family + "\""
    ctx.textBaseline = "middle"

    for (var q = 0; q < places.length; q++) {
      var place = places[q]
      ctx.fillStyle = dotColor
      ctx.beginPath()
      ctx.arc(place.x, place.y, 1.6, 0, Math.PI * 2)
      ctx.fill()
      ctx.fillStyle = labelColor
      ctx.fillText(place.name, place.x + 5, place.y + 1)
    }
  }
}
