#!/bin/bash
#
# Tests for the global keyboard shortcuts: builds scripts/shortcuts-tests.swift
# with every Isle source (the shortcuts read the real view model) and runs it.
# Covers key combos and their storage, the bindings and clashes, holding keys
# only while a request waits, what a press does (guarded commands, Always…,
# questions) and refusals.
#
# Takes no key from this session: every hot key goes to a recording fake,
# never to Carbon. Settings go to a scratch UserDefaults suite.
#
# Usage: scripts/test-shortcuts.sh
#

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/isle-shortcut-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done \
  < <(find "$ROOT/Isle" -name '*.swift' ! -name 'IsleApp.swift' -print0)
cp "$ROOT/scripts/shortcuts-tests.swift" "$SCRATCH/main.swift"
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 \
  -module-name Isle -o "$SCRATCH/run" "${SOURCES[@]}" "$SCRATCH/main.swift" 2>&1 \
  | grep -E "error" || true
[ -x "$SCRATCH/run" ] || { echo "build failed"; exit 1; }
"$SCRATCH/run"
