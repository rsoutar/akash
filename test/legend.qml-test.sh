#!/usr/bin/env bash
#
# The legend QML compiles and renders under a real QML engine.
#
# Node pins the legend's pure half — the bands, the ramp, the end labels —
# but the legend itself is QML: canvases painted at load, a repeater per rung,
# anchors evaluated against the theme. A typo there is not something a source
# regex catches. This runs `LegendStrip.qml` and `MapCanvas.qml` under
# Quickshell and reads the rungs back out of the live components.
#
# The legend imports the shell's own `qs.Commons`/`qs.Ui` modules (it follows
# the map's chrome exactly), which Quickshell resolves from the host Omarchy
# shell's module directories. So the probe stages those beside the plugin —
# the same module layout the running shell provides the widget.
#
# Offline by construction, like the other shell tests: nothing here reads the
# network, and the probe instantiates the legend and the map standalone rather
# than wiring a whole panel. Needs `qs` and the Omarchy shell modules; skips
# without them, and AERORADAR_REQUIRE_QS turns the skip into a failure (what
# CI sets).

set -uo pipefail

cd "$(dirname "$0")/.."
plugin=$PWD

if ! command -v qs > /dev/null 2>&1; then
  if [[ -n ${AERORADAR_REQUIRE_QS:-} ]]; then
    echo "AERORADAR_REQUIRE_QS is set and there is no qs on PATH" >&2
    exit 1
  fi
  echo "no qs on PATH; skipping (set AERORADAR_REQUIRE_QS to make this fatal)"
  exit 0
fi

if [[ ! -d /usr/share/omarchy/shell/Commons || ! -d /usr/share/omarchy/shell/Ui ]]; then
  if [[ -n ${AERORADAR_REQUIRE_QS:-} ]]; then
    echo "AERORADAR_REQUIRE_QS is set and the Omarchy shell modules are missing" >&2
    exit 1
  fi
  echo "Omarchy shell modules not found; skipping"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Commons" "$work/Ui" "$work/ui" "$work/lib"
cp "$plugin/ui/"*.qml "$work/ui/"
cp "$plugin/lib/"*.js "$work/lib/"
cp /usr/share/omarchy/shell/Commons/* "$work/Commons/"
cp /usr/share/omarchy/shell/Ui/* "$work/Ui/"

cat > "$work/probe.qml" <<'PROBE'
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ui"
ShellRoot {
  id: harness

  function report(key, value) { console.log("PROBE " + key + "=" + value) }

  MapCanvas {
    id: map
    width: 500
    height: 320
    Component.onCompleted: harness.report("map-loaded", "yes")
  }

  LegendStrip {
    id: ls
    width: 304
    mode: "radar"
    schemeName: "TITAN"
    Component.onCompleted: {
      harness.report("radar-tiers", ls.tiers.map(function(t) { return t.name }).join(","))
      harness.report("radar-title", ls.title + " | " + ls.endTitle)
      ls.mode = "air-quality"
      ls.layerLabel = "PM2.5"
      ls.lowEnd = "Cleaner"
      ls.highEnd = "More polluted"
      harness.report("air-tiers", ls.tiers.map(function(t) { return t.name }).join(","))
      harness.report("air-title", ls.title + " | " + ls.endTitle)
      Qt.quit()
    }
  }
}
PROBE

out=$(env QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR="$work/runtime" \
      timeout 90 qs -p "$work/probe.qml" 2>&1 | sed -n 's/.*PROBE //p')

failures=0
check() {
  local label=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    printf '  ok    %s\n' "$label"
  else
    printf '  FAIL  %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

value() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | tail -1; }

if [[ $(value map-loaded) != "yes" ]]; then
  echo "  FAIL  MapCanvas.qml did not load under Quickshell" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

check "MapCanvas.qml still loads without the legend inside it"      "yes" "$(value map-loaded)"
check "the radar legend names the painted rungs"      "light,moderate,heavy" "$(value radar-tiers)"
check "the radar legend names the palette"           "Radar · TITAN | " "$(value radar-title)"
check "the air legend names the EEA bands"            "Good,Fair,Moderate,Poor,Very poor,Extremely poor" "$(value air-tiers)"
check "the air legend names layer and ends"           "Air quality · PM2.5 | Cleaner → More polluted" "$(value air-title)"

echo
if (( failures > 0 )); then
  echo "legend qml: $failures check(s) failed"
  exit 1
fi
echo "legend qml: all checks passed"