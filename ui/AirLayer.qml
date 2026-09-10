import QtQuick
import "../lib/CamsModel.js" as CamsModel

// One WMS GetMap overlay for the exact viewport, double-buffered.
//
// CAMS does not serve XYZ tiles — it renders one image for one bounding box.
// That makes this layer different from the radar's TileLayers: the image
// belongs to a viewport, so panning invalidates it, and every step change is
// a fresh request rather than a cache hit. The two buffers exist so stepping
// and playing never flash blank: the next frame loads into the idle buffer
// while the current one stays on screen.
//
// While the view moves, the held frame no longer matches the ground under it,
// so it is hidden until the fresh frame arrives — a gap that reads better
// than an overlay sitting a street away from where it belongs.
Item {
  id: root

  // View state, owned by the panel like the map's.
  property real centerLatitude: 0
  property real centerLongitude: 0
  property int zoom: 7

  // False clears the buffers and asks for nothing.
  property bool active: false

  property string layerName: ""
  property string layerStyle: ""
  property string stepTime: ""
  property real overlayOpacity: 0.6

  // True while the next frame is on its way — the panel surfaces this.
  property int liveBuffer: -1    // which buffer is shown (-1 = none yet)
  property int pendingBuffer: -1 // which buffer is loading the next frame
  readonly property bool loading: pendingBuffer !== -1

  readonly property bool laidOut: width >= 1 && height >= 1

  function scheduleRebuild() {
    overlayDebounce.restart()
  }

  function clearBuffers() {
    bufA.source = ""
    bufB.source = ""
    liveBuffer = -1
    pendingBuffer = -1
  }

  function rebuildOverlay() {
    if (!active || !layerName) { clearBuffers(); return }
    // Hidden: there is no viewport to fit, and holding a pending marker would
    // keep the panel header saying "Fetching" for a map nobody can see. The
    // layer refetches for the live viewport when it next becomes visible.
    if (!visible) { clearBuffers(); return }
    // Not laid out yet (panel still opening): retry rather than clear, so the
    // overlay heals itself once the viewport has a real size.
    if (!laidOut) { scheduleRebuild(); return }
    var bbox = CamsModel.viewportBbox(centerLatitude, centerLongitude, zoom, width, height)
    applyOverlay(CamsModel.mapUrl(layerName, layerStyle, bbox, width, height, stepTime))
  }

  function applyOverlay(src) {
    var target = liveBuffer === 0 ? 1 : 0
    var img = target === 0 ? bufA : bufB
    // Mark pending BEFORE touching source: a cached image can flip to Ready
    // synchronously on assignment, firing statusChanged while pendingBuffer
    // is still stale — bufferReady would then bail and leave it stuck.
    pendingBuffer = target
    if (String(img.source) !== src) img.source = src
    // A cached/already-loaded image will not emit statusChanged again, so
    // settle now.
    if (img.status === Image.Ready) bufferReady(target)
    else if (img.status === Image.Error) bufferFailed(target)
  }

  function bufferReady(index) {
    if (pendingBuffer !== index) return
    liveBuffer = index
    pendingBuffer = -1
  }

  function bufferFailed(index) {
    if (pendingBuffer === index) pendingBuffer = -1
  }

  // Any change to what the frame depicts asks for a new one. The debounce
  // folds a drag burst into one request after the movement settles.
  onActiveChanged: scheduleRebuild()
  onLayerNameChanged: scheduleRebuild()
  onLayerStyleChanged: scheduleRebuild()
  onStepTimeChanged: scheduleRebuild()
  onCenterLatitudeChanged: viewportMoving()
  onCenterLongitudeChanged: viewportMoving()
  onZoomChanged: viewportMoving()
  onWidthChanged: scheduleRebuild()
  onHeightChanged: scheduleRebuild()
  onVisibleChanged: if (visible) scheduleRebuild()
  Component.onCompleted: scheduleRebuild()

  // Hide the held frame while the view is moving: it no longer matches the
  // ground under it. Restored when the fresh frame lands.
  function viewportMoving() {
    if (liveBuffer !== -1 && pendingBuffer === -1) liveBuffer = -1
    scheduleRebuild()
  }

  Image {
    id: bufA
    anchors.fill: parent
    asynchronous: true
    cache: true
    fillMode: Image.Stretch
    // The decode is bounded to the viewport's own pixels. Every stream that
    // reaches this process carries a ceiling; an image served for whatever
    // size the response declares is a stream like any other.
    sourceSize: Qt.size(Math.max(1, root.width), Math.max(1, root.height))
    opacity: (root.liveBuffer === 0 && root.pendingBuffer === -1) ? root.overlayOpacity : 0
    Behavior on opacity { NumberAnimation { duration: 150 } }
    onStatusChanged: {
      if (status === Image.Ready) root.bufferReady(0)
      else if (status === Image.Error) root.bufferFailed(0)
    }
  }

  Image {
    id: bufB
    anchors.fill: parent
    asynchronous: true
    cache: true
    fillMode: Image.Stretch
    sourceSize: Qt.size(Math.max(1, root.width), Math.max(1, root.height))
    opacity: (root.liveBuffer === 1 && root.pendingBuffer === -1) ? root.overlayOpacity : 0
    Behavior on opacity { NumberAnimation { duration: 150 } }
    onStatusChanged: {
      if (status === Image.Ready) root.bufferReady(1)
      else if (status === Image.Error) root.bufferFailed(1)
    }
  }

  // The same guard for the overlay: a GetMap request that never answers would
  // otherwise leave `pendingBuffer` set — and the panel header reading
  // "Fetching" — until the layer changes. Give up after this long; the next
  // viewport or step change asks again.
  readonly property int loadStallMs: 8000

  Timer {
    interval: root.loadStallMs
    running: root.pendingBuffer !== -1
    onTriggered: if (root.pendingBuffer !== -1) root.bufferFailed(root.pendingBuffer)
  }

  Timer {
    id: overlayDebounce
    interval: 250
    onTriggered: root.rebuildOverlay()
  }
}
