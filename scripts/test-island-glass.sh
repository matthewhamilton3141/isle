#!/bin/zsh
# Builds and runs the glass panel tests (scripts/island-glass-tests.swift):
# Glass, Smoked and Fade (its band, curve and clear-glass lens: scrim, rim,
# glint, the cover's light and the sweep on open), the blend, the glow and
# the lifts, against Isle/Notch/IslandGlass.swift, Isle/Notch/IslandMotion.swift
# (the open spring the sweep waits on) and Isle/Core/PanelBackground.swift
# alone. No app, no window.
set -e
ROOT=${0:A:h:h}
OUT=${TMPDIR:-/tmp}/isle-island-glass-tests
mkdir -p $OUT
# Top-level test code has to be the module's main.swift.
cp $ROOT/scripts/island-glass-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -swift-version 5 -O \
  $ROOT/Isle/Notch/IslandGlass.swift \
  $ROOT/Isle/Notch/IslandMotion.swift \
  $ROOT/Isle/Core/PanelBackground.swift \
  $OUT/main.swift \
  -o $OUT/run
$OUT/run
