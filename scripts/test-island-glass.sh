#!/bin/zsh
# Builds and runs the glass panel tests (scripts/island-glass-tests.swift):
# the stored background and the retired ones it still reads, Glass's tint,
# Prism (its shade, its lens's shape, the ribbon's profile, motion, status
# patterns and colours), the blend, the glow and the lifts, against
# Isle/Notch/IslandGlass.swift, Isle/Notch/IslandPrism.swift,
# Isle/Notch/IslandMotion.swift (the settled corner radii) and
# Isle/Core/PanelBackground.swift alone. No app, no window. Which of a
# cover's colours Prism is given is scripts/test-artwork-palette.sh.
set -e
ROOT=${0:A:h:h}
OUT=${TMPDIR:-/tmp}/isle-island-glass-tests
mkdir -p $OUT
# Top-level test code has to be the module's main.swift.
cp $ROOT/scripts/island-glass-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -swift-version 5 -O \
  $ROOT/Isle/Notch/IslandGlass.swift \
  $ROOT/Isle/Notch/IslandPrism.swift \
  $ROOT/Isle/Notch/IslandMotion.swift \
  $ROOT/Isle/Core/PanelBackground.swift \
  $OUT/main.swift \
  -o $OUT/run
$OUT/run
