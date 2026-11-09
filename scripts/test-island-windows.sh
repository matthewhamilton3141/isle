#!/bin/zsh
# Builds and runs scripts/island-windows-tests.swift against every Isle source:
# the panel and the glass window under it, built as NotchWindowController
# builds them, kept at maximumFrame and in step through opens, closes,
# re-places, attempts to size them, and the key handoff. The windows are
# transparent, click-through and never activate or take keys; nothing is shown.
set -e
ROOT=${0:A:h:h}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/isle-island-windows.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
cp $ROOT/scripts/island-windows-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SRCS=("${(@f)$(find $ROOT/Isle -name '*.swift' ! -name 'IsleApp.swift')}")
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 -module-name Isle -suppress-warnings \
  $SRCS $OUT/main.swift -o $OUT/run
$OUT/run
