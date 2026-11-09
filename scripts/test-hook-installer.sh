#!/bin/bash
#
# Tests for how HookInstaller puts the isle-cli helper in place: builds
# scripts/hook-installer-tests.swift with every Isle source and runs it
# against a scratch directory. Never writes ~/.isle or ~/.claude — every
# write goes to an explicit path under the scratch dir.
#
# Usage: scripts/test-hook-installer.sh
#

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/isle-installer-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done \
  < <(find "$ROOT/Isle" -name '*.swift' ! -name 'IsleApp.swift' -print0)
cp "$ROOT/scripts/hook-installer-tests.swift" "$SCRATCH/main.swift"
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 \
  -module-name Isle -o "$SCRATCH/run" "${SOURCES[@]}" "$SCRATCH/main.swift" 2>&1 \
  | grep -E "error" || true
[ -x "$SCRATCH/run" ] || { echo "build failed"; exit 1; }
mkdir -p "$SCRATCH/home"
"$SCRATCH/run" "$SCRATCH/home"
