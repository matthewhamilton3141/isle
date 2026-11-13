#!/bin/zsh
# Builds and runs scripts/alert-opens-tests.swift against every Isle source:
# an island off its notch opens the way its place calls for however it opens,
# an alert included, and an alert leaves alone an island on its notch, on
# another display, in the hand or gliding. Windows on fake displays far off
# any real one, alpha 0, never key; synthetic events, never posted.
set -e
ROOT=${0:A:h:h}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/isle-alert-opens.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
cp $ROOT/scripts/alert-opens-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SRCS=("${(@f)$(find $ROOT/Isle -name '*.swift' ! -name 'IsleApp.swift')}")
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 -module-name Isle -suppress-warnings \
  $SRCS $OUT/main.swift -o $OUT/run
$OUT/run
