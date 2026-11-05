#!/bin/zsh
# Builds and runs the agenda parser tests (scripts/agenda-parser-tests.swift)
# against the two parser sources alone. Nothing touches a calendar.
set -e
ROOT=${0:A:h:h}
OUT=${TMPDIR:-/tmp}/isle-agenda-parser-tests
mkdir -p $OUT
# Top-level test code has to be the module's main.swift.
cp $ROOT/scripts/agenda-parser-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -swift-version 5 -O \
  $ROOT/Isle/Agenda/MeetingLink.swift \
  $ROOT/Isle/Agenda/QuickAddParser.swift \
  $OUT/main.swift \
  -o $OUT/run
$OUT/run
