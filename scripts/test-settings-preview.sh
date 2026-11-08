#!/bin/bash
#
# Tests for the island's live preview while Settings is configured: builds
# scripts/settings-preview-tests.swift with every Isle source and runs it.
# Covers which setting opens which face, when a change opens the island and
# when it doesn't, which AppSettings changes count, and when the hold ends.
#
# No window and no app: settings go to a scratch UserDefaults suite.
#
# Usage: scripts/test-settings-preview.sh
#

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/isle-settings-preview-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done \
  < <(find "$ROOT/Isle" -name '*.swift' ! -name 'IsleApp.swift' -print0)
cp "$ROOT/scripts/settings-preview-tests.swift" "$SCRATCH/main.swift"
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 \
  -module-name Isle -o "$SCRATCH/run" "${SOURCES[@]}" "$SCRATCH/main.swift" 2>&1 \
  | grep -E "error" || true
[ -x "$SCRATCH/run" ] || { echo "build failed"; exit 1; }
"$SCRATCH/run"
