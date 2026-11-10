#!/bin/zsh
# Builds and runs the status light tests (scripts/status-light-tests.swift):
# which status lights which colour, the wrap and motion rules, the blend with
# the cover, the pulse and the flash, against Isle/Notch/StatusLight.swift
# and IslandGlass.swift (and what it needs) alone. No app, no window.
set -e
ROOT=${0:A:h:h}
OUT=${TMPDIR:-/tmp}/isle-status-light-tests
mkdir -p $OUT
cp $ROOT/scripts/status-light-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -swift-version 5 -O \
  $ROOT/Isle/Notch/StatusLight.swift \
  $ROOT/Isle/Notch/IslandGlass.swift \
  $ROOT/Isle/Notch/IslandMotion.swift \
  $ROOT/Isle/Core/PanelBackground.swift \
  $OUT/main.swift \
  -o $OUT/run
$OUT/run
