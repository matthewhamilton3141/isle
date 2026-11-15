#!/bin/zsh
# Builds and runs scripts/waveform-click-tests.swift against every Isle
# source: a click on the Music face's waveform restarts the level meter, and
# lands nowhere else, through the real window's hit-testing. The window is
# offscreen, transparent and never activates; nothing is shown, no capture
# runs and no player is sent anything.
set -e
ROOT=${0:A:h:h}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/isle-waveform-click.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
cp $ROOT/scripts/waveform-click-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SRCS=("${(@f)$(find $ROOT/Isle -name '*.swift' ! -name 'IsleApp.swift')}")
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 -module-name Isle -suppress-warnings \
  $SRCS $OUT/main.swift -o $OUT/run
$OUT/run
