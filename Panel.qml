import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ui"
import "lib/Alerts.js" as Alerts
import "lib/CamsModel.js" as CamsModel
import "lib/Frames.js" as Frames
import "lib/Settings.js" as Settings
import "lib/TileMath.js" as TileMath
import "lib/RadarModel.js" as RadarModel

// The aeroradar panel.
//
// Opens centred on the location Omarchy already knows about, stacks the
// latest radar frame over a basemap, and can play the last two hours as a
// loop. The alert toggle lives down here, so turning the watch on is one
// click from the thing you are looking at — and because a schema entry is
// not an interface: nothing in the installed shell renders one, so a control
// that is not in a panel is nowhere.
//
// This file owns the state the pieces in ui/ share — where the map is
// looking, which frame is on screen, what is being edited — plus the
// lifecycle, the keyboard map and the IPC surface. Everything drawn is a
// component in ui/; everything computed is a function in lib/.
Panel {
  id: root
  moduleName: "aeroradar"
  ipcTarget: "aeroradar"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  property bool openedFromHotkey: false

  // The bar tracks the widget in its slot, not this nested panel, so anything
  // the popout coordinator compares against has to be the widget.
  readonly property var barIdentity: hostWidget || root

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  // Every reading goes through Settings.js, which the service reads through
  // as well, so the panel and the alert that fires from it cannot disagree
  // about what the user configured.
  readonly property bool alertsEnabled: Settings.alertsEnabled(settings)
  readonly property int alertRadiusKm: Settings.alertRadiusKm(settings)
  readonly property var radiusPresets: Settings.radiusPresets(alertRadiusKm)
  readonly property string alertThreshold: Settings.alertThreshold(settings)
  readonly property var thresholdOptions: Alerts.THRESHOLD_OPTIONS
  readonly property bool aqAlertsEnabled: Settings.aqAlertsEnabled(settings)
  readonly property string aqBandName: {
    var band = Settings.aqThresholdBand(settings)
    return band >= 0 && band < Alerts.AQ_BAND_NAMES.length ? Alerts.AQ_BAND_NAMES[band] : "Poor"
  }
  // Alerts below Moderate are noise: the EEA's own band-1 days are most days
  // in most places, and a watch that fires daily is switched off.
  readonly property var aqBandOptions: ["Moderate", "Poor", "Very poor", "Extremely poor"]
  readonly property bool smoothTiles: Settings.smoothTiles(settings)
  readonly property bool showSnow: Settings.showSnow(settings)
  readonly property int colorSchemeId: Settings.colorSchemeId(settings)
  readonly property string defaultView: Settings.defaultView(settings)

  // The service is the authority on lead time whenever it is mounted; the
  // fallback covers the moment before it is.
  readonly property int alertLeadMinutes: service ? service.leadMinutes : Alerts.leadMinutesFor(alertRadiusKm)

  // Write one field back to this widget's inline shell.json entry, preserving
  // every other field. Same approach the first-party panels use.
  function persistSetting(key, value) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
    entry[key] = value
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---------------------------------------------------------------------------
  // Map state
  // ---------------------------------------------------------------------------

  readonly property bool hasLocation: service ? service.hasLocation === true : false
  // Held rather than bound, so an absent coordinate leaves them alone instead
  // of becoming a real one. A binding must yield a number — there is no way
  // to say "unchanged" — and any binding over the gap while `hasLocation`
  // catches up would place home at 0,0, off the coast of west Africa.
  property real homeLatitude: 0
  property real homeLongitude: 0
  // Deliberately not gated on `hasLocation`: that flag is derived from the
  // same object and settles a moment later, so requiring it here would
  // discard the one call that carries the coordinates. The parse below is
  // the only test that matters.
  function updateHome() {
    if (!service || !service.location) return
    var la = parseFloat(service.location.latitude)
    var lo = parseFloat(service.location.longitude)
    if (!isFinite(la) || !isFinite(lo)) return

    homeLatitude = la
    homeLongitude = lo

    // Recentre here rather than from a change handler on each coordinate.
    // Such a handler fires between the two writes, on the new latitude
    // beside the old longitude — a point that never existed, which the map
    // would centre on and fetch a full round of tiles for before being
    // corrected.
    if (!panned) recenter()
  }

  Connections {
    target: root.service
    function onLocationChanged() { root.updateHome() }
  }

  onServiceChanged: updateHome()
  readonly property string locationName: service ? service.locationName : ""
  readonly property string locationState: service ? service.locationState : "unset"

  property real viewLatitude: 0
  property real viewLongitude: 0
  property int zoom: Settings.defaultZoom(settings)

  // The map's own height, declared once because the limit on how far north
  // or south the view may sit is a question about the viewport rather than
  // about the centre: half a panel of world has to stay on each side of it.
  readonly property real mapHeight: Style.space(320)

  // Reapplied on zoom as well as on panning. Zooming out makes the same
  // panel cover more of the globe, so a centre that was legal deep in stops
  // being legal — without this, zooming out near a pole puts the world's
  // edge across the middle of the map.
  onZoomChanged: viewLatitude = TileMath.constrainLatitude(viewLatitude, zoom, mapHeight)

  // The radar layers stop requesting new detail here and get scaled up
  // instead, so the basemap can keep sharpening past the data's limit.
  readonly property int overlaySourceZoom: Math.min(zoom, RadarModel.MAX_RADAR_ZOOM)

  function recenter() {
    // Nothing to centre on before a location exists; recentring on the
    // placeholder would move the view to 0,0 rather than leave it alone.
    if (!hasLocation) return
    viewLatitude = TileMath.constrainLatitude(homeLatitude, zoom, mapHeight)
    viewLongitude = homeLongitude
  }

  onHasLocationChanged: updateHome()
  property bool panned: false

  // ---------------------------------------------------------------------------
  // CAMS categories and layers
  // ---------------------------------------------------------------------------
  //
  // The chips decide which overlay the timeline drives: "Radar" animates the
  // last two hours, a CAMS category animates its forecast steps. The overlays
  // themselves stack — selecting a CAMS layer draws it over the radar, and
  // switching back to Radar leaves it in place, frozen at its step, until it
  // is cleared with the ✕ in the picker.

  property string activeCategory: "radar"
  readonly property bool radarMode: activeCategory === "radar"

  readonly property string camsRegion: service ? service.camsRegion : "europe"
  readonly property var camsCategories: CamsModel.categoriesFor(service ? service.camsCaps : null, camsRegion)
  readonly property var chipCategories: ["radar"].concat(camsCategories)

  readonly property var camsLayers: radarMode
    ? [] : CamsModel.layersForCategory(service ? service.camsCaps : null, activeCategory, camsRegion)

  // One selection per category, so switching chips does not forget which
  // layer each one was showing.
  property var selectedLayerNames: ({})

  function setSelectedLayer(category, name) {
    var next = {}
    for (var key in selectedLayerNames) next[key] = selectedLayerNames[key]
    next[category] = name
    selectedLayerNames = next
  }

  function selectedLayerFor(category) {
    var name = selectedLayerNames[category]
    return name ? CamsModel.findLayer(service ? service.camsCaps : null, name) : null
  }

  readonly property var activeLayer: radarMode ? null : selectedLayerFor(activeCategory)

  function chooseCategory(id) {
    activeCategory = id
    // Written on every switch, whatever the default-view setting is, so that
    // "Last used" is accurate from the first chip the user ever touches — and
    // stays a record of the journey for anyone who switches the setting later.
    persistSetting("lastView", id)
    // A category visited for the first time opens on its first layer —
    // air-quality's is PM2.5, the one the bar tracks — rather than on a
    // picker with nothing chosen.
    if (id !== "radar" && !selectedLayerNames[id]) {
      var layers = CamsModel.layersForCategory(service ? service.camsCaps : null, id, camsRegion)
      if (layers.length > 0) setSelectedLayer(id, layers[0].name)
    }
  }

  // What the panel shows each time it opens: the widget's default-view
  // setting, resolved against the region. Allergens is Europe-only pollen, so
  // a default of it elsewhere reads as air quality — the same fallback
  // switching to that chip by hand gets. "Last used" reads the chip persisted
  // on every switch, falling back to radar before the first one.
  function applyDefaultView() {
    var id = Settings.viewIdFor(defaultView)
    if (id === "last") id = String(settings.lastView || "radar")
    if (id === "allergens" && camsRegion !== "europe") id = "air-quality"
    if (activeCategory === id) return
    chooseCategory(id)
  }

  function chooseLayer(layer) {
    if (!layer) return
    setSelectedLayer(activeCategory, layer.name)
  }

  // Air quality is the plugin's reason to exist, so as soon as the caps
  // arrive its first layer is selected — the overlay is on before the first
  // click. Clearing it from the picker is one ✕ away.
  Connections {
    target: root.service
    function onCamsCapsChanged() { root.autoSelectAirQuality() }
  }

  function autoSelectAirQuality() {
    if (!service || !service.camsCaps) return
    if (selectedLayerNames["air-quality"]) return
    var layers = CamsModel.layersForCategory(service.camsCaps, "air-quality", camsRegion)
    if (layers.length > 0) setSelectedLayer("air-quality", layers[0].name)
  }

  // What the map is actually drawing. The chips are exclusive: whichever
  // menu is active, only its overlay is on the map — radar frames come off
  // when a CAMS category is chosen, and the air layer comes off when the
  // Radar chip comes back. Both are held separately from the selection, so
  // switching chips never forget which layer each side had.
  property string shownAirLayerName: ""
  property string shownAirStepTime: ""

  function syncAirOverlay() {
    // Not the air menu, no air overlay — the selection stays for the return.
    if (radarMode) {
      shownAirLayerName = ""
      shownAirStepTime = ""
      return
    }
    var layer = activeLayer
    if (!layer) return
    shownAirLayerName = layer.name
    var steps = CamsModel.layerSteps(layer)
    if (steps.length === 0) return
    var index = Frames.clampIndex(camsFrames, camsFrameIndex)
    shownAirStepTime = steps[Math.min(index, steps.length - 1)]
  }

  function clearAirOverlay() {
    shownAirLayerName = ""
    shownAirStepTime = ""
    // The selection goes with it, so re-entering the category re-selects its
    // default rather than silently resurrecting what was cleared.
    if (!radarMode) setSelectedLayer(activeCategory, undefined)
  }

  // The radar half of the same exclusivity. The timeline position
  // (`frameIndex`, `shownTime`, `followingLatest`) is untouched either way —
  // only what the map draws comes and goes — so returning to the Radar chip
  // resumes exactly where the loop was, at whatever frame the list now holds.
  function syncRadarOverlay() {
    if (radarMode) {
      if (frames.length > 0) showFrame(Frames.clampIndex(frames, frameIndex))
      return
    }
    frameA = -1
    frameB = -1
    swapPending = false
    swapWatchdog.stop()
  }

  onActiveCategoryChanged: {
    syncAirOverlay()
    syncRadarOverlay()
  }

  // ---------------------------------------------------------------------------
  // CAMS forecast steps
  // ---------------------------------------------------------------------------

  readonly property var activeStepTimes: activeLayer ? CamsModel.layerSteps(activeLayer) : []
  readonly property var camsFrames: activeStepTimes.map(function(iso) {
    return { time: Date.parse(iso) / 1000, iso: iso }
  })

  property int camsFrameIndex: 0
  property real camsShownTime: 0
  property bool camsFollowingLatest: true

  // Same survival rule as the radar frames: remember the moment, not the
  // index, because the list is replaced whenever the layer or its dimension
  // changes.
  function recordCamsStep() {
    var frame = camsFrames.length ? camsFrames[Frames.clampIndex(camsFrames, camsFrameIndex)] : null
    camsShownTime = frame ? frame.time : 0
    camsFollowingLatest = Frames.isLatest(camsFrames, camsFrameIndex)
  }

  onCamsFramesChanged: {
    if (camsFrames.length === 0) return
    var next = Frames.reselect(camsFrames, camsShownTime, camsFollowingLatest)
    if (next !== camsFrameIndex) camsFrameIndex = next
    else { showCamsFrame(camsFrameIndex); recordCamsStep() }
  }

  function showCamsFrame(index) {
    if (index < 0 || camsFrames.length === 0) return
    syncAirOverlay()
  }

  onCamsFrameIndexChanged: {
    showCamsFrame(camsFrameIndex)
    recordCamsStep()
  }

  // A newly chosen layer opens on ~now, not on the analysis time.
  onActiveLayerChanged: {
    if (!activeLayer) return
    camsFrameIndex = CamsModel.nearestTimeIndex(CamsModel.layerSteps(activeLayer))
    syncAirOverlay()
  }

  // ---------------------------------------------------------------------------
  // Unified timeline
  // ---------------------------------------------------------------------------

  readonly property var timelineFrames: radarMode ? frames : camsFrames
  readonly property int timelineIndex: radarMode ? frameIndex : camsFrameIndex
  readonly property var timelineFrame: radarMode ? currentFrame
    : (camsFrames.length ? camsFrames[Frames.clampIndex(camsFrames, camsFrameIndex)] : null)
  readonly property string timelineLabel: !timelineFrame ? "--:--"
    : (radarMode ? RadarModel.formatFrameTime(timelineFrame.time)
                 : CamsModel.formatStepTime(timelineFrame.iso))
  // How stale the shown radar picture is, under the clock. Empty on the
  // newest frame — "ago" is only an answer while the picture is in the past —
  // and never set for CAMS, whose steps are forecasts rather than history.
  readonly property string timelineAgo: radarMode && timelineFrame && !timelineAtLatest
    ? RadarModel.formatFrameAgo(timelineFrame.time, Date.now()) : ""
  readonly property bool timelineAtLatest: radarMode
    ? isLatestFrame : Frames.isLatest(camsFrames, camsFrameIndex)

  function setTimelineIndex(index) {
    playing = false
    if (radarMode) frameIndex = index
    else camsFrameIndex = index
  }

  function setTimelinePlaying(next) {
    playing = next
  }

  // ---------------------------------------------------------------------------
  // Location editing
  // ---------------------------------------------------------------------------
  //
  // Deliberately the same picker as the stock weather widget: same geocoding
  // endpoint, same suggestion rows, same omarchy-weather-location call.
  // There is one location on this machine, and it is the weather widget's
  // file. Changing the city here moves the stock weather widget too, and
  // vice versa — both watch the file.

  property bool editingLocation: false
  property bool savingLocation: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

  function startEditingLocation() {
    if (editingLocation) return
    editingLocation = true
    locationSuggestions = []
    suggestionIndex = 0
    locationPicker.query = root.locationName
    Qt.callLater(function() { locationPicker.focusQuery() })
  }

  function cancelEditingLocation() {
    editingLocation = false
    savingLocation = false
    locationSuggestions = []
    suggestionIndex = 0
    geocodePendingQuery = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function commitLocation() {
    var choice = RadarModel.locationCommit(locationPicker.query, locationSuggestions, suggestionIndex)
    if (!choice.name) {
      clearLocation()
      return
    }
    savingLocation = true
    persistLocation(choice.name, choice.latitude, choice.longitude)
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    savingLocation = true
    persistLocation(suggestion.name, suggestion.latitude, suggestion.longitude)
  }

  function clearLocation() {
    savingLocation = true
    persistLocation("", null, null)
  }

  // What the last save asked for, so a save that changes nothing can be told
  // apart from one that does.
  property real pendingLatitude: NaN
  property real pendingLongitude: NaN

  function persistLocation(name, latitude, longitude) {
    pendingLatitude = parseFloat(latitude)
    pendingLongitude = parseFloat(longitude)

    if (name && latitude !== null && longitude !== null)
      locationSaveProc.launch(["omarchy-weather-location", "--set", name, latitude + "," + longitude])
    else if (name)
      locationSaveProc.launch(["omarchy-weather-location", "--set", name])
    else
      locationSaveProc.launch(["omarchy-weather-location", "--clear"])
  }

  // Debounced so typing a city name is one request per pause, not one per
  // keystroke. Only one curl is in flight at a time; a query that moved on
  // while a fetch was running is issued as soon as that one returns.
  function requestGeocode() {
    var query = locationPicker.query.trim()
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!geocodeProc.running) startGeocode()
  }

  function startGeocode() {
    geocodeActiveQuery = geocodePendingQuery
    geocodeProc.launch(RadarModel.geocodingCommand(geocodeActiveQuery, 5))
  }

  Timer {
    id: geocodeDebounce
    interval: 220
    onTriggered: root.requestGeocode()
  }

  BoundedProcess {
    id: geocodeProc
    onResponded: function(exitCode, text) { root.applyGeocodeResponse(exitCode, text) }
  }

  function applyGeocodeResponse(exitCode, text) {
    // A failed search leaves no suggestions rather than stale ones: a list
    // from the previous query, under the letters just typed, is a wrong
    // answer presented as a current one.
    root.locationSuggestions = (exitCode === 0 && root.editingLocation)
      ? RadarModel.parseGeocodingResults(text) : []
    root.suggestionIndex = 0

    // Only when there is still a search to run. cancelEditingLocation()
    // clears the pending query, and a successful save routes through it too
    // — so a request in flight when the user presses Escape would come back,
    // find pending and active different, and go out again for the empty
    // string: a real call to the geocoder for nothing, after the field is
    // closed.
    if (!root.editingLocation || root.geocodePendingQuery === "") return
    if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startGeocode)
  }

  BoundedProcess {
    id: locationSaveProc
    onResponded: function(exitCode, text) { root.applyLocationSave(exitCode) }
  }

  function applyLocationSave(exitCode) {
    root.savingLocation = false
    if (exitCode !== 0) return

    // Clear `panned` before anything can deliver a location, so the order of
    // what follows cannot decide whether the map recentres.
    root.panned = false

    // Recentre now only when what was saved is what home already holds —
    // re-choosing the stored city, where identical coordinates mean no
    // property changes and so nothing else would fire. Doing it
    // unconditionally would snap the map to the previous city first on a
    // move, and onto the city just removed on a clear.
    if (isFinite(root.pendingLatitude)
        && root.pendingLatitude === root.homeLatitude
        && root.pendingLongitude === root.homeLongitude) root.recenter()

    // Then ask the service to re-read rather than waiting for its file
    // watch. The first location ever written lands in a directory that did
    // not exist when that watch was set up, so nothing would announce it.
    if (root.service && root.service.reloadLocation) root.service.reloadLocation()

    root.cancelEditingLocation()
  }

  // ---------------------------------------------------------------------------
  // Frames
  // ---------------------------------------------------------------------------

  readonly property var frames: service ? service.frames : []
  property int frameIndex: 0
  property bool playing: false

  // What the user is looking at, expressed so that it survives the list
  // being replaced: the moment on screen, and whether they chose to follow
  // the newest frame. Both are recorded while the list that produced them is
  // still in hand — an index into the old list means nothing in the new one.
  property real shownTime: 0
  property bool followingLatest: true

  // Bumped whenever the list is replaced. At an unchanged index a new
  // manifest is still a different frame, and without this the tile layers
  // keep the tiles they already have.
  property int frameEpoch: 0

  readonly property var currentFrame: {
    var index = Frames.clampIndex(frames, frameIndex)
    return index < 0 ? null : frames[index]
  }

  readonly property string frameLabel: currentFrame ? RadarModel.formatFrameTime(currentFrame.time) : "--:--"
  readonly property bool isLatestFrame: Frames.isLatest(frames, frameIndex)

  // Jump to the newest frame in hand, and follow it from here. What "newest"
  // means is decided again each time the list is replaced, so this holds even
  // when the list on screen is hours old and the real one has not arrived.
  function showLatestFrame() {
    followingLatest = true
    var latest = frames.length - 1
    if (latest >= 0 && frameIndex !== latest) frameIndex = latest
    else recordShownFrame()
  }

  function recordShownFrame() {
    var frame = currentFrame
    shownTime = frame ? frame.time : 0
    followingLatest = Frames.isLatest(frames, frameIndex)
  }

  // A new manifest arrives every ten minutes, and the panel is opened against
  // lists it has never seen. Someone parked on the newest frame wants the
  // newest frame whatever the new list looks like; someone who scrubbed back
  // to a time wants that time, at whatever index it now sits.
  onFramesChanged: {
    if (frames.length === 0) return
    frameEpoch++

    var next = Frames.reselect(frames, shownTime, followingLatest)
    if (next !== frameIndex) {
      frameIndex = next
    } else {
      // The same position in a different list is a different frame, so the
      // layers are told even though the index did not move.
      showFrame(frameIndex)
      recordShownFrame()
    }

    // First frames after a manifest: only the radar chip populates the
    // layers. While a CAMS category owns the map the position is kept in
    // `frameIndex` alone, ready for the return.
    if (radarMode && frameA < 0) { frameA = frameIndex; frontIsA = true }
  }

  // Crossfade state. Two tile layers alternate: the incoming frame is staged
  // into whichever is currently behind, and the two swap opacity only once
  // that layer has every tile it asks for.
  //
  // Swapping the moment the frame is assigned reads as a flash: the incoming
  // tiles have not decoded, so the 380 ms fade runs against a blank layer —
  // the current frame fades out, the ground shows through, and the new frame
  // pops in afterwards. Gating the swap on readiness turns the same animation
  // into a dissolve between two fully drawn frames, and paces the loop to the
  // network: a step takes as long as its tiles do, not less.
  property int frameA: -1
  property int frameB: -1
  property bool frontIsA: true
  property bool swapPending: false

  onFrameIndexChanged: showFrame(frameIndex)

  function showFrame(index) {
    if (index < 0 || frames.length === 0) return
    // Another chip owns the map: the radar keeps its timeline position but
    // draws nothing. Choosing the Radar chip again stages this frame.
    if (!radarMode) return
    if (frontIsA) frameB = index
    else frameA = index
    swapPending = true
    // A tile the network never answers must not park the loop forever. Two
    // seconds in, the swap goes ahead regardless: on a dead connection that
    // degrades to the old flash rather than to a frozen map.
    swapWatchdog.restart()
    commitIfReady()
  }

  function commitIfReady() {
    if (!swapPending || !map.backReady) return
    finishSwap()
  }

  function commitForced() {
    if (!swapPending) return
    finishSwap()
  }

  function finishSwap() {
    swapPending = false
    frontIsA = !frontIsA
    // The caption moves with the picture, not with the request.
    recordShownFrame()
    // While playing, the layer now behind is idle: hand it the next frame so
    // its tiles decode during the hold, and the next swap is a crossfade
    // between two loaded frames instead of a wait. A cache hit answers
    // synchronously, so on the second pass through the loop the swap is
    // immediate.
    if (playing && frames.length > 1) {
      var next = Frames.nextIndex(frames, frameIndex)
      if (frontIsA) frameB = next
      else frameA = next
    }
  }

  Timer {
    id: swapWatchdog
    interval: 2000
    onTriggered: root.commitForced()
  }

  function tileUrlForFrame(index, z, x, y) {
    if (!root.service || !root.service.tileHost) return ""
    if (index < 0 || index >= root.frames.length) return ""
    return RadarModel.tileUrl(root.service.tileHost, root.frames[index].path, 256,
      z, x, y, root.colorSchemeId, root.smoothTiles, root.showSnow)
  }

  Timer {
    id: playbackTimer
    // Radar: slow enough to read the motion rather than watch a strobe, with
    // a longer hold on the newest frame — and slow enough that the tile decode
    // of the next frame usually finishes before the clock asks for it. When it
    // does not, the tick below waits: advancing past a frame still loading
    // would abandon it and start another wait, and the loop would stutter
    // rather than breathe. CAMS: steps are hourly, so a steady pace; the
    // overlay's double buffer absorbs frames that load slower than the clock.
    interval: radarMode ? (isLatestFrame ? 2000 : 850) : 1200
    repeat: true
    running: root.playing && root.opened && timelineFrames.length > 1
    onTriggered: {
      if (radarMode) {
        if (root.swapPending) return
        root.frameIndex = Frames.nextIndex(frames, root.frameIndex)
      }
      else root.camsFrameIndex = Frames.nextIndex(camsFrames, root.camsFrameIndex)
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.onOpened()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.onOpened()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.playing = false
    if (root.editingLocation) root.cancelEditingLocation()
    if (root.manifestHeld) {
      if (root.service && root.service.releaseManifest) root.service.releaseManifest()
      root.manifestHeld = false
    }
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  property bool manifestHeld: false

  // A bar surface is rebuilt per monitor, so a panel can be destroyed while
  // it still holds the manifest — unplugging a screen with the map open.
  // Without this the refcount never comes back down and the service keeps
  // fetching frames for a panel nobody has.
  Component.onDestruction: {
    if (manifestHeld && root.service && root.service.releaseManifest) root.service.releaseManifest()
  }

  function onOpened() {
    // Opening is a question about now, so the view and the clock both start
    // there. While the panel is open, Frames.reselect keeps whoever is
    // studying a particular time on that time as the list moves under them.
    panned = false
    if (hasLocation) recenter()
    showLatestFrame()
    applyDefaultView()
    // The CAMS overlay opens on ~now too, wherever it was left.
    if (activeLayer) {
      camsFrameIndex = CamsModel.nearestTimeIndex(CamsModel.layerSteps(activeLayer))
      syncAirOverlay()
    }
    if (root.service && !manifestHeld) {
      root.service.acquireManifest()
      manifestHeld = true
    }

    // Opening the map is a request for current information, and the frames,
    // the forecast and the air reading are all things that can have gone
    // stale or started failing while it was closed.
    if (root.service && root.service.refreshIfStale) root.service.refreshIfStale()
    if (root.service && root.service.refreshAqIfStale) root.service.refreshAqIfStale()

    // Ask the tile layers to fetch again. Qt never retries an Image that
    // failed, and the frame list can be current while the tiles under it
    // were requested during an outage. Anything already held is served from
    // the cache, so this costs a request only for what is actually missing.
    frameEpoch++
    // The canvas can only read pixels while it is on screen, so opening is
    // the moment to ask.
    Qt.callLater(function() { coverageProbe.probe() })
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (!root.bar) return
    // PluginBarApi exposes centerHoverRevealSuppressed as readonly. In QML,
    // setCenterHoverRevealSuppressed() is that property's setter and throws,
    // which aborts close() before the panel actually hides.
    if (typeof root.bar._setCenterHoverRevealSuppressed === "function") {
      root.bar._setCenterHoverRevealSuppressed(value)
      return
    }
    try {
      root.bar.centerHoverRevealSuppressed = value
    } catch (e) {}
  }

  IpcHandler {
    target: root.ipcTarget

    function open() { root.openFromHotkey() }
    function close() { root.close() }
    function show() { root.openFromHotkey() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
  }

  // ---------------------------------------------------------------------------
  // Map wiring
  // ---------------------------------------------------------------------------

  // The ground is drawn from geometry that ships with the plugin, decoded
  // once by the service. See ui/BasemapLayer.qml for why its colours follow
  // the theme while the radar's do not.
  readonly property var basemap: service ? service.basemap : null

  // Credit for everything drawn on the map, in one place so it cannot fall
  // out of step with where the data actually comes from.
  readonly property string attribution: "RainViewer · Natural Earth"

  function tileUrlA(z, x, y) { return root.tileUrlForFrame(root.frameA, z, x, y) }
  function tileUrlB(z, x, y) { return root.tileUrlForFrame(root.frameB, z, x, y) }

  // Large parts of the world have no ground radar at all, and there the map
  // is simply empty — which is indistinguishable from "no rain today" and
  // reads as a broken plugin. RainViewer publishes a coverage mask that is
  // transparent where a radar reaches and opaque black where none does, so
  // the question is answerable: fetch the mask centred on the user and read
  // the middle pixel, which is their location by construction.
  //
  // The probe is mounted in the panel's tree rather than in the service
  // because reading pixels needs a scene to render into, and a headless
  // singleton has none. See ui/CoverageProbe.qml.
  readonly property string coverageProbeUrl: {
    if (!service || !service.tileHost || !hasLocation) return ""
    if (service.coverageChecked) return ""
    return RadarModel.coverageTileUrl(service.tileHost, 256, RadarModel.MAX_RADAR_ZOOM,
      homeLatitude, homeLongitude)
  }

  readonly property bool coverageMissing: service ? (service.coverageChecked && !service.hasCoverage) : false

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field has focus its keystrokes are text, not
      // shortcuts: without this, typing a city name would scrub the
      // timeline and zoom the map.
      blocked: root.editingLocation
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onReturnRequested: root.playing = !root.playing

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Left) {
          root.setTimelineIndex(Math.max(0, root.timelineIndex - 1))
          event.accepted = true
        } else if (event.key === Qt.Key_Right) {
          root.setTimelineIndex(Math.min(root.timelineFrames.length - 1, root.timelineIndex + 1))
          event.accepted = true
        } else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) {
          root.zoom = Math.min(RadarModel.MAX_MAP_ZOOM, root.zoom + 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Minus) {
          root.zoom = Math.max(RadarModel.MIN_RADAR_ZOOM, root.zoom - 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Home) {
          root.panned = false
          root.recenter()
          event.accepted = true
        }
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        MapCanvas {
          id: map
          width: parent.width
          height: root.mapHeight
          bar: root.bar
          basemap: root.basemap

          centerLatitude: root.viewLatitude
          centerLongitude: root.viewLongitude
          zoom: root.zoom
          overlaySourceZoom: root.overlaySourceZoom

          tileUrlA: root.tileUrlA
          tileUrlB: root.tileUrlB
          radarOverlayVisible: root.radarMode

          frameA: root.frameA
          frameB: root.frameB
          frameEpoch: root.frameEpoch
          frontIsA: root.frontIsA
          colorSchemeId: root.colorSchemeId
          smoothTiles: root.smoothTiles

          hasLocation: root.hasLocation
          homeLatitude: root.homeLatitude
          homeLongitude: root.homeLongitude
          alertsEnabled: root.alertsEnabled
          alertRadiusKm: root.alertRadiusKm

          loading: root.frames.length === 0
          overlayUnavailable: root.service ? root.service.frameFailures > 0 : false
          attribution: root.attribution

          airOverlayVisible: root.shownAirLayerName !== ""
          airLayerName: root.shownAirLayerName
          airStepTime: root.shownAirStepTime

          onDragged: function(latitude, longitude) {
            root.viewLatitude = TileMath.constrainLatitude(latitude, root.zoom, root.mapHeight)
            // Normalised as it is stored, so panning east indefinitely keeps
            // the centre a real coordinate rather than letting it grow
            // without bound. The ground draws the world repeatedly either
            // way; this is about what everything else positioned against the
            // centre sees.
            root.viewLongitude = TileMath.wrapLongitude(longitude)
            root.panned = true
          }
          onRecenterRequested: {
            root.panned = false
            root.recenter()
          }

          // The staged frame finished loading: the swap may go ahead. The
          // callLater matters — a model rebuild first destroys the old tile
          // delegates and then creates the new ones, and between those halves
          // the layer can briefly report ready with nothing counted yet.
          // Deferring to the end of the event loop turn and looking again
          // reads the settled count instead of the transient.
          onBackReadyChanged: if (map.backReady) Qt.callLater(root.commitIfReady)
          onZoomRequested: function(zoom, latitude, longitude) {
            root.zoom = zoom
            var wrapped = TileMath.wrapLongitude(longitude)
            // Zooming towards the pointer moves the view, so it counts as
            // panning — otherwise the next location update would snap the
            // map back. Zooming on the centre moves nothing and must not.
            var constrained = TileMath.constrainLatitude(latitude, zoom, root.mapHeight)
            if (!TileMath.samePosition(constrained, wrapped, root.viewLatitude, root.viewLongitude)) {
              root.viewLatitude = constrained
              root.viewLongitude = wrapped
              root.panned = true
            }
          }

          CoverageProbe {
            id: coverageProbe
            source: root.coverageProbeUrl
            onResolved: function(covered) {
              if (root.service && root.service.reportCoverage) root.service.reportCoverage(covered)
              if (!covered) console.log("aeroradar: no ground radar reaches the configured location")
            }
          }
        }

        LayerPicker {
          width: parent.width
          bar: root.bar
          categories: root.chipCategories
          activeCategory: root.activeCategory
          layers: root.camsLayers
          selectedLayerName: root.activeLayer ? root.activeLayer.name : ""

          onCategoryChosen: function(id) { root.chooseCategory(id) }
          onLayerChosen: function(layer) { root.chooseLayer(layer) }
          onLayerCleared: root.clearAirOverlay()
        }

        Timeline {
          width: parent.width
          bar: root.bar
          frames: root.timelineFrames
          frameIndex: root.timelineIndex
          playing: root.playing
          frameLabel: root.timelineLabel
          frameAgo: root.timelineAgo
          isLatestFrame: root.timelineAtLatest
          labelWidth: Style.space(96)
          onPlayToggled: root.playing = !root.playing
          onFrameRequested: function(index) { root.setTimelineIndex(index) }
        }

        PanelSeparator { width: parent.width }

        // Separator, then a small-caps heading at the content edge, then the
        // rows inset under it. That rail is the shape every dense
        // first-party panel is built on.
        PanelSectionHeader {
          text: "LOCATION"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: Style.font.family
        }

        LocationPicker {
          id: locationPicker
          width: parent.width
          spacing: Style.space(6)
          bar: root.bar
          locationName: root.locationName
          locationState: root.locationState
          coverageMissing: root.coverageMissing
          editing: root.editingLocation
          saving: root.savingLocation
          suggestions: root.locationSuggestions
          suggestionIndex: root.suggestionIndex

          onEditRequested: root.startEditingLocation()
          onCancelRequested: root.cancelEditingLocation()
          onCommitRequested: root.commitLocation()
          onClearRequested: root.clearLocation()
          onQueryEdited: geocodeDebounce.restart()
          onSuggestionHighlighted: function(index) { root.suggestionIndex = index }
          onSuggestionPicked: function(suggestion) { root.pickSuggestion(suggestion) }
        }

        PanelSeparator { width: parent.width }

        AlertControls {
          width: parent.width
          // Sections need more air between them than rows do inside one.
          spacing: Style.space(12)
          bar: root.bar
          service: root.service
          alertsEnabled: root.alertsEnabled
          locationState: root.locationState
          alertLeadMinutes: root.alertLeadMinutes
          alertRadiusKm: root.alertRadiusKm
          radiusPresets: root.radiusPresets
          alertThreshold: root.alertThreshold
          thresholdOptions: root.thresholdOptions

          onAlertsToggled: {
            var next = !root.alertsEnabled
            root.persistSetting("alertsEnabled", next)
            // Fire the first check immediately so enabling produces a
            // visible result instead of up to ten minutes of silence.
            if (next && root.service && root.service.checkNow) Qt.callLater(root.service.checkNow)
          }
          // The service watches for these and re-checks on its own, so a
          // value edited into shell.json by hand behaves the same as one
          // chosen here.
          onRadiusChosen: function(km) { root.persistSetting("alertRadiusKm", km) }
          onThresholdChosen: function(name) { root.persistSetting("alertMinIntensity", name) }

          aqAlertsEnabled: root.aqAlertsEnabled
          aqBandName: root.aqBandName
          aqBandOptions: root.aqBandOptions

          onAqAlertsToggled: {
            var next = !root.aqAlertsEnabled
            root.persistSetting("aqAlertsEnabled", next)
            // Enabling answers with the reading in hand, if there is one —
            // the probe cadence is hourly, too long to wait for a first word.
            if (next && root.service && root.service.evaluateAqAlert) Qt.callLater(root.service.evaluateAqAlert)
          }
          onAqBandChosen: function(name) { root.persistSetting("aqAlertBand", name) }
        }
      }
    }
  }
}
