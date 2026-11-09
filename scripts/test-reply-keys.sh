#!/bin/zsh
# Builds and runs scripts/reply-keys-tests.swift against every Isle source:
# the reply's paste, and its field's keys through the real window.
# The window is offscreen, transparent and never activates; nothing is shown.
set -e
ROOT=${0:A:h:h}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/isle-reply-keys.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
cp $ROOT/scripts/reply-keys-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SRCS=("${(@f)$(find $ROOT/Isle -name '*.swift' ! -name 'IsleApp.swift')}")
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 -module-name Isle -suppress-warnings \
  $SRCS $OUT/main.swift -o $OUT/run
$OUT/run
