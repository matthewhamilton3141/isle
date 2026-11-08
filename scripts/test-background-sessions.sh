#!/bin/bash
#
# Tests for background sessions in the list (Milestone 21): builds
# scripts/background-sessions-tests.swift with every Isle source (the merge
# runs through the real view model) and runs it against the fixtures in
# scripts/fixtures — real `claude agents --json --all` output from 2.1.319.
# Runs no `claude` and touches nothing under ~/.claude; the CLI runner is
# checked on /bin/sh fakes (a grandchild holding stdout, a hang, a timeout).
#
# Usage: scripts/test-background-sessions.sh
#

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/isle-background-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done \
  < <(find "$ROOT/Isle" -name '*.swift' ! -name 'IsleApp.swift' -print0)
cp "$ROOT/scripts/background-sessions-tests.swift" "$SCRATCH/main.swift"
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 \
  -module-name Isle -o "$SCRATCH/run" "${SOURCES[@]}" "$SCRATCH/main.swift" 2>&1 \
  | grep -E "error" || true
[ -x "$SCRATCH/run" ] || { echo "build failed"; exit 1; }
"$SCRATCH/run" "$ROOT/scripts/fixtures"
