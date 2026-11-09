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
# setting a variable to a path under the encoded project folder. Until v12 the
# hook cut it to its first 48 characters, which left one token, de-pathed to
# the cut folder name. Since v12 the hook names the program from the whole
# command (isle-cli's bash_program, the same rules as ClaudeActivity), and the
# target is that name alone.
hook "Running cat" 'R=/private/tmp/claude-501/-Users-matthew-Documents-isle/adf8176b-8654-4f0e-bb09-f9c545e90b60/scratchpad/m17/render; cat $R/build.sh' "the reported command"
hook "Running cat" 'cat ~/.claude/projects/-Users-matthew-Documents-isle/memory/MEMORY.md' "a path under the encoded folder as an argument"
hook "Running npm" 'FOO=1 npm test'
hook "Running swift" 'export PATH=/opt/homebrew/bin:$PATH; swift build'
hook "Running git" 'cd /Users/matthew/Documents/isle && git status'
hook "Running git" 'cd /Users/matthew/Documents/isle/.claude/worktrees/agent-a2a1d0bb9ce4fe989 && git status' "a cd longer than 48 characters"
hook "Running make" 'cd ~/proj; make -j8'
hook "Running swift" '(cd Isle && swift build)'
hook "Running git" 'env -i PATH=/usr/bin git status'
hook "Running launchctl" 'sudo -u root launchctl list'
hook "Running xcodebuild" 'time xcodebuild -scheme Isle build'
hook "Running python3" 'nohup python3 server.py > server.log 2>&1 &'
hook "Running git" 'command git status'
hook "Running node" "'/usr/local/bin/node' app.js" "a single-quoted path"
hook "Running node" '"/usr/local/bin/node" app.js' "a double-quoted path"
hook "Running npm" 'FOO="bar" npm test' "a double-quoted assignment"
hook "Running git" '/usr/bin/git log --oneline -5'
hook "Running test-guarded-commands.sh" './scripts/test-guarded-commands.sh'
hook "Running xcodebuild" 'xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug build' "a long command, cut in its arguments"
hook "Running xcodebuild" $'# Build it\nxcodebuild -scheme Isle' "a comment line first"
hook "Running xcodebuild" 'cd /private/tmp/claude-501/-Users-matthew-Documents-isle/adf8176b-8654-4f0e-bb09-f9c545e90b60/scratchpad/m19 && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Isle.xcodeproj -scheme Isle build' "a long cd and an assignment before the program"
hook "Running Isle" '"/Users/matthew/Library/Application Support/Isle Builds/Debug/Isle.app/Contents/MacOS/Isle" --version' "a double-quoted program path with spaces"
hook "Running swift" $'# Rebuild the harness\n# then run it\ncd /tmp/h && swift run' "two comment lines and a cd before the program"
hook "Running python3" $'cd /Users/matthew/Documents/isle/.claude/worktrees/agent-ab78effb488e2ffb5\npython3 - <<\'EOF\'\nprint("hi")\nEOF' "a cd on its own line, then a heredoc's program"
hook "Running git" 'cd "/Users/matthew/Documents/My \"Quoted\" Folder" && git log' "a cd into a path with escaped quotes"
hook "Running a command" '$EDITOR notes.txt' "a variable in command position"
hook "Running a command" 'command -v swiftc' "command -v only looks a name up (the app reads a lone \`command\` as a wrapper)"
hook "Running a command" 'cd /tmp; export X=1' "only setup, nothing run"
hook "Running rg" "rg -n pattern $(printf 'x%.0s' $(seq 1 6000))" "a command longer than the hook reads"
hook "Running a command" "cd $(printf 'd%.0s' $(seq 1 6000)) && make" "a cd longer than the hook reads"
hook "Running a command" $'  \n# only a comment' "no command at all"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cp "$ROOT/scripts/claude-activity-tests.swift" "$SCRATCH/main.swift"
xcrun swiftc -swift-version 5 -O "$ROOT/Isle/Claude/ClaudeActivity.swift" "$SCRATCH/main.swift" -o "$SCRATCH/run"
"$SCRATCH/run" "$CASES"
