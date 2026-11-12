#!/bin/zsh
# Builds and runs the cover colour tests (scripts/artwork-palette-tests.swift):
# which of a cover's colours make the palette — a small vivid subject, one
# colour and its shades, two colours and no third, covers with no colour,
# the same palette whatever order the pixels come in, and the lift off black
# that keeps a colour's hue — against Isle/Components/CoverColors.swift
# alone. No app, no image, no window.
set -e
ROOT=${0:A:h:h}
OUT=${TMPDIR:-/tmp}/isle-artwork-palette-tests
mkdir -p $OUT
# Top-level test code has to be the module's main.swift.
cp $ROOT/scripts/artwork-palette-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -swift-version 5 -O \
  $ROOT/Isle/Components/CoverColors.swift \
  $OUT/main.swift \
  -o $OUT/run
$OUT/run
