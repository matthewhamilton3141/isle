#!/bin/zsh
# Builds and runs the level meter watchdog tests
# (scripts/meter-watchdog-tests.swift) against Isle/Media/MeterWatchdog.swift
# alone. No app, no Core Audio, no tap.
set -e
ROOT=${0:A:h:h}
OUT=${TMPDIR:-/tmp}/isle-meter-watchdog-tests
mkdir -p $OUT
# Top-level test code has to be the module's main.swift.
cp $ROOT/scripts/meter-watchdog-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -swift-version 5 -O \
  $ROOT/Isle/Media/MeterWatchdog.swift \
  $OUT/main.swift \
  -o $OUT/run
$OUT/run
