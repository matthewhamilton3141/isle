#!/bin/zsh
# Builds and runs the floating-island tests (scripts/island-float-tests.swift):
# an island taken off its notch — its shape, the closed capsule and what
# sizes it, the header's grabber, the edge, the glass with no black over it
# and Prism's pane — against Isle/Notch/IslandFloat.swift,
# Isle/Notch/IslandGlass.swift, Isle/Notch/IslandPrism.swift,
# Isle/Notch/IslandMotion.swift and Isle/Core/PanelBackground.swift alone. No
# app, no window.
set -e
ROOT=${0:A:h:h}
OUT=${TMPDIR:-/tmp}/isle-island-float-tests
mkdir -p $OUT
# Top-level test code has to be the module's main.swift.
cp $ROOT/scripts/island-float-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -swift-version 5 -O \
  $ROOT/Isle/Notch/IslandFloat.swift \
  $ROOT/Isle/Notch/IslandGlass.swift \
  $ROOT/Isle/Notch/IslandPrism.swift \
  $ROOT/Isle/Notch/IslandMotion.swift \
  $ROOT/Isle/Core/PanelBackground.swift \
  $OUT/main.swift \
  -o $OUT/run
$OUT/run
