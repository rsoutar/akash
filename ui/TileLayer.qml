import QtQuick
import "../lib/TileMath.js" as TileMath

// One raster layer of an XYZ tile map.
//
// MapCanvas stacks these — two per animated overlay, one per crossfade half —
// over the ground that BasemapLayer draws. The projection lives here rather
// than up there because every layer must share a centre and zoom: any drift
// between them would show up as the rain sitting next to the coastline
// instead of on it.
//
// Tiles are plain Image elements. Qt's pixmap cache keys on URL, and overlay
// tile URLs are immutable per frame, so scrubbing back through the loop or
// panning to somewhere already visited costs nothing the second time.
Item {
  id: root

  property real centerLatitude: 0
  property real centerLongitude: 0

  // Zoom of the viewport — the scale the user sees.
  property int zoom: 7

  // Zoom the tiles are actually requested at. Normally identical, but a layer
  // whose source runs out of resolution before the map does keeps asking for
  // its deepest real tiles and scales them up. Radar stops at z7 while the
  // basemap goes far deeper, and capping the whole map at the radar's limit
  // would be the wrong trade: people zoom in to see which town is under a
  // storm, and the town comes from the basemap.
  property int sourceZoom: zoom

  readonly property real sourceScale: Math.pow(2, zoom - sourceZoom)

  // function(zoom, x, y) -> string. Returning "" skips the tile, which is how
  // a layer stays blank until its data is ready.
  property var tileUrlFor: null

  // The panel can hand ownership of the map to another overlay. Disabling
  // the layer removes its tile delegates as well as hiding it, so switching
  // away from Radar stops both the old picture and its pending requests.
  property bool active: true

  // Bumped by the owner to force a reload when the URL scheme itself changes
  // (a new frame, a different palette) so the model rebuilds.
  property int revision: 0

  property int tileSize: 256
  property bool smooth: true

  // How many of the layer's current tiles are still on their way. A tile is
  // settled once it has decoded, errored, or has no URL to fetch at all — a
  // tile with no data (outside the frame's coverage) arrives transparent and
  // must not be waited on. The layer as a whole is ready when nothing is
  // pending, which is what the crossfade waits for: swapping before the
  // incoming tiles exist fades out the frame on screen and shows the ground
  // through the gap.
  //
  // The count is per delegate, and a model rebuild destroys and recreates
  // them — so between the two halves the count can momentarily touch zero
  // while the new tiles have not been counted yet. Readers re-check after
  // the burst (see the panel's commit, which defers to the end of the event
  // loop turn and looks again) rather than trusting the transient.
  property int pending: 0
  readonly property bool ready: pending === 0

  // Qt's Image has no timeout, so a request that never answers would leave its
  // tile counted in `pending` for the life of the delegate — pinning the panel
  // header to "Fetching" and the crossfade to its watchdog forever. When the
  // count has stood still this long, the outstanding tiles are written off.
  // A late arrival still settles cleanly: `settle()` never drives it negative.
  readonly property int stallMs: 6000
  property double lastProgressMs: 0
  onPendingChanged: lastProgressMs = Date.now()

  Timer {
    interval: 1000
    repeat: true
    running: root.pending > 0
    onTriggered: {
      if (Date.now() - root.lastProgressMs >= root.stallMs) root.pending = 0
    }
  }

  signal tileFailed()

  clip: true

  // Laid out in source-zoom space, then scaled onto the screen. Passing the
  // viewport through sourceScale is what lets one upscaled tile cover the
  // area several native-zoom tiles would have.
  readonly property var layout: TileMath.viewportTiles(
    centerLatitude, centerLongitude, sourceZoom,
    Math.max(1, width / sourceScale), Math.max(1, height / sourceScale))

  // Flattened tile list, rebuilt whenever the viewport moves. At the zoom
  // levels this plugin uses that is a few dozen entries, so the simple
  // approach beats an incremental one for readability.
  readonly property var tiles: {
    var list = []
    var view = layout
    if (!view || width <= 0 || height <= 0) return list
    // `revision` is read so the model rebuilds when the frame changes.
    var unused = revision
    var scale = sourceScale
    for (var y = view.minY; y <= view.maxY; y++) {
      if (!TileMath.isValidTileY(y, sourceZoom)) continue
      for (var x = view.minX; x <= view.maxX; x++) {
        list.push({
          tileX: TileMath.wrapTileX(x, sourceZoom),
          tileY: y,
          screenX: (view.originX + (x - view.minX) * root.tileSize) * scale,
          screenY: (view.originY + (y - view.minY) * root.tileSize) * scale
        })
      }
    }
    return list
  }

  Repeater {
    model: root.active ? root.tiles : []

    Image {
      id: tile
      required property var modelData

      x: modelData.screenX
      y: modelData.screenY
      width: root.tileSize * root.sourceScale
      height: root.tileSize * root.sourceScale

      source: root.tileUrlFor ? root.tileUrlFor(root.sourceZoom, modelData.tileX, modelData.tileY) : ""
      asynchronous: true
      cache: true
      // The loader is asked for a tile-sized surface rather than whatever the
      // response turns out to declare. Every other stream that reaches this
      // process carries a ceiling; an image arriving over the network is one
      // too, and its size is decided by whoever served it.
      sourceSize: Qt.size(root.tileSize, root.tileSize)
      // Upscaled tiles need the smoothing; native-resolution ones look
      // sharper without it.
      smooth: root.smooth || root.sourceScale > 1
      fillMode: Image.Stretch

      // A tile that has not arrived stays invisible rather than showing a
      // placeholder, which would read as a rendering fault. A tile with no
      // data arrives as a transparent image rather than as an error.
      visible: status === Image.Ready

      // The layer's pending count. `counted` makes the count-out idempotent:
      // a tile settles exactly once, whether that is Ready, Error, or being
      // destroyed mid-load by the next model rebuild.
      property bool counted: false

      function settle() {
        if (!counted) return
        counted = false
        if (root.pending > 0) root.pending--
      }

      Component.onCompleted: {
        // An image already decoded from the cache never emits another
        // statusChanged, so it must never be counted in.
        if (source !== "" && status !== Image.Ready && status !== Image.Error) {
          counted = true
          root.pending++
        }
      }

      onStatusChanged: {
        if (status === Image.Error) root.tileFailed()
        tile.settle()
      }

      Component.onDestruction: tile.settle()
    }
  }
}
