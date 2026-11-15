#!/bin/zsh
# Builds and runs the notch-bleed tests (scripts/island-bleed-tests.swift):
# the black reaching from the camera housing for an island carried near it
# — the haze on the island, as a function
# of distance — against Isle/Notch/IslandBleed.swift and the SwiftUI-free
# sources it reads its numbers from. No app, no window.
set -e
ROOT=${0:A:h:h}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/isle-island-bleed.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
# Top-level test code has to be the module's main.swift.
cp $ROOT/scripts/island-bleed-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  $ROOT/Isle/Notch/IslandBleed.swift \
  $ROOT/Isle/Notch/IslandPrism.swift \
  $ROOT/Isle/Notch/IslandGlass.swift \
  $ROOT/Isle/Notch/IslandFloat.swift \
  $ROOT/Isle/Notch/IslandMotion.swift \
  $ROOT/Isle/Core/PanelBackground.swift \
  $OUT/main.swift \
  -o $OUT/run
$OUT/run
