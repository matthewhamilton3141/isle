#!/bin/bash
#
# Tests for the "what it's doing" line (ClaudeActivity.phrase): builds
# scripts/claude-activity-tests.swift against Isle/Claude/ClaudeActivity.swift
# alone, and first puts real Bash commands through `isle-cli set-state
# working` — a PreToolUse payload on stdin, under a scratch HOME, so nothing
# touches ~/.isle — to test the app on the target the hook actually writes.
# Nothing here is ever executed: every command is only text in a payload.
#
# Usage: scripts/test-claude-activity.sh [path/to/isle-cli]
#

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${1:-$ROOT/integration/claude-code-hooks/isle-cli}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/isle-activity-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/home"
CASES="$SCRATCH/hook-cases.tsv"
: > "$CASES"

# JSON string body for $1, the way Claude Code escapes a command.
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

# hook <want> <command> [name]: the target isle-cli writes for <command>,
# with what the face should say for it.
hook() {
  local want="$1" cmd="$2" name="${3:-$2}" sf target
  printf '{"session_id":"test-activity","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s","description":"test"},"tool_use_id":"toolu_test"}' \
    "$(json_string "$cmd")" | HOME="$SCRATCH/home" /bin/bash "$CLI" set-state working
  sf="$SCRATCH/home/.isle/sessions/test-activity.json"
  target="$(sed -nE 's/^  "target": "(.*)",$/\1/p' "$sf")"
  printf '%s  [target: %s]\t%s\t%s\n' "${name//$'\n'/↵}" "$target" "$target" "$want" >> "$CASES"
}

# What produced "Running -Users-matthew-Documen": a command that starts by
# setting a variable to a path under the encoded project folder. No space in
# its first 48 characters, so the cut left one token, de-pathed to the cut
# folder name.
hook "Running a command" 'R=/private/tmp/claude-501/-Users-matthew-Documents-isle/adf8176b-8654-4f0e-bb09-f9c545e90b60/scratchpad/m17/render; cat $R/build.sh' "the reported command"
hook "Running cat" 'cat ~/.claude/projects/-Users-matthew-Documents-isle/memory/MEMORY.md' "a path under the encoded folder as an argument"
hook "Running npm" 'FOO=1 npm test'
hook "Running swift" 'export PATH=/opt/homebrew/bin:$PATH; swift build'
hook "Running git" 'cd /Users/matthew/Documents/isle && git status'
hook "Running a command" 'cd /Users/matthew/Documents/isle/.claude/worktrees/agent-a2a1d0bb9ce4fe989 && git status' "a cd cut off by the hook's 48 characters"
hook "Running make" 'cd ~/proj; make -j8'
hook "Running swift" '(cd Isle && swift build)'
hook "Running git" 'env -i PATH=/usr/bin git status'
hook "Running launchctl" 'sudo -u root launchctl list'
hook "Running xcodebuild" 'time xcodebuild -scheme Isle build'
hook "Running python3" 'nohup python3 server.py > server.log 2>&1 &'
hook "Running git" 'command git status'
hook "Running node" "'/usr/local/bin/node' app.js" "a single-quoted path"
hook "Running a command" '"/usr/local/bin/node" app.js' "a double-quoted path (the hook stops at the escaped quote)"
hook "Running a command" 'FOO="bar" npm test' "a double-quoted assignment (likewise)"
hook "Running git" '/usr/bin/git log --oneline -5'
hook "Running test-guarded-commands.sh" './scripts/test-guarded-commands.sh'
hook "Running xcodebuild" 'xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug build' "a long command, cut in its arguments"
hook "Running a command" $'# Build it\nxcodebuild -scheme Isle' "a comment first (the hook turns \\n into n)"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cp "$ROOT/scripts/claude-activity-tests.swift" "$SCRATCH/main.swift"
xcrun swiftc -swift-version 5 -O "$ROOT/Isle/Claude/ClaudeActivity.swift" "$SCRATCH/main.swift" -o "$SCRATCH/run"
"$SCRATCH/run" "$CASES"
