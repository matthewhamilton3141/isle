#!/bin/zsh
# Builds and runs scripts/session-priority-tests.swift against every Isle source:
# which session the island shows, through interleaved state streams.
# Pure: no window, no bridge.
set -e
ROOT=${0:A:h:h}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/isle-session-priority.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
cp $ROOT/scripts/session-priority-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SRCS=("${(@f)$(find $ROOT/Isle -name '*.swift' ! -name 'IsleApp.swift')}")
xcrun swiftc -swift-version 5 -Onone -D DEBUG -target arm64-apple-macos14.0 -module-name Isle -suppress-warnings \
  $SRCS $OUT/main.swift -o $OUT/run
$OUT/run
