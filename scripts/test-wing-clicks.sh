#!/bin/zsh
# Builds and runs scripts/wing-clicks-tests.swift against every Isle source:
# clicks on the Claude face's wings, through the real window's hit-testing.
# The window is offscreen, transparent and never activates; nothing is shown.
set -e
ROOT=${0:A:h:h}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/isle-wing-clicks.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
cp $ROOT/scripts/wing-clicks-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SRCS=("${(@f)$(find $ROOT/Isle -name '*.swift' ! -name 'IsleApp.swift')}")
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 -module-name Isle -suppress-warnings \
  $SRCS $OUT/main.swift -o $OUT/run
$OUT/run
