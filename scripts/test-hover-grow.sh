#!/bin/zsh
# Builds and runs the hover grow tests (scripts/hover-grow-tests.swift)
# against Isle/Notch/HoverGrow.swift alone. No app, no window, no pointer.
set -e
ROOT=${0:A:h:h}
OUT=${TMPDIR:-/tmp}/isle-hover-grow-tests
mkdir -p $OUT
# Top-level test code has to be the module's main.swift.
cp $ROOT/scripts/hover-grow-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -swift-version 5 -O \
  $ROOT/Isle/Notch/HoverGrow.swift \
  $OUT/main.swift \
  -o $OUT/run
$OUT/run
