#!/bin/bash
#
# Tests for "Done, unless it isn't" (Milestone 20): isle-cli keeping, at Stop,
# what the turn left running (`background_tasks`) and the wake-ups it
# scheduled (`session_crons`) at ~/.isle/left/<session>.json and in every
# record as `left`; a shell kept as its program and that program's words; a
# background agent moving from the subagent count to `left`, never in both;
# and the next prompt, a failed turn and the session's end clearing it, while
# the idle nudge and a compaction keep it. Then the app's side, built from
# scripts/done-leftovers-tests.swift with every Isle source: the record parser
# on the files this run wrote, the wake-ups in words, and the face's, the
# tile's and the row's lines. The first two Stops are real ones from Claude
# Code 2.1.319 (haiku, `claude -p`, a scratch project; paths shortened). Run
# the way Claude Code runs the hooks — a payload on stdin — under a scratch
# HOME, so nothing touches ~/.isle.
#
# Usage: scripts/test-done-leftovers.sh [path/to/isle-cli]
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${1:-$ROOT/integration/claude-code-hooks/isle-cli}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/isle-left-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
H="$SCRATCH/home"
mkdir -p "$H/.isle/sessions" "$SCRATCH/records"
SF="$H/.isle/sessions/s1.json"
LF="$H/.isle/left/s1.json"

passes=0
failures=0

ok() { passes=$((passes + 1)); echo "  ok    $1"; }
bad() { failures=$((failures + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

field() { sed -nE "s/^  \"$1\": \"?([^\",]*)\"?,?$/\\1/p" "${2:-$SF}"; }
left() { sed -nE 's/^  "left": (.*),$/\1/p' "${1:-$SF}"; }
agents() { sed -nE 's/^  "subagents": (.*),$/\1/p' "${1:-$SF}"; }
# The record's `left` without its `at`, which is the clock's.
left_shape() { left "$@" | sed -E 's/, "at": "[^"]*"//'; }

# expect <name> <want left json, `at` left out> [field=value…]
expect() {
  local name="$1" want="$2" kv f v got all=""
  shift 2
  got="$(left_shape)"
  [ "$got" = "$want" ] || all="left: want '$want', got '$got';"
  for kv in "$@"; do
    f="${kv%%=*}"; v="${kv#*=}"; got="$(field "$f")"
    [ "$got" = "$v" ] || all="$all $f: want '$v', got '$got';"
  done
  plutil -convert json -o /dev/null "$SF" >/dev/null 2>&1 || all="$all not valid JSON;"
  if [ -z "$all" ]; then ok "$name"; else bad "$name" "$all"; fi
}

hook() { HOME="$H" /bin/bash "$CLI" "$@"; }

prompt() { printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"start the dev server"}' "${1:-s1}" | hook set-state working; }
# stop <background_tasks json> [session_crons json] [last message]
stop() {
  printf '{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/work","prompt_id":"p1","permission_mode":"default","effort":{"level":"medium"},"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"%s","background_tasks":%s,"session_crons":%s}' \
    "${3:-ok}" "$1" "${2:-[]}" | hook set-state done
}
shell() {  # shell <command, JSON-escaped>
  stop "[{\"id\":\"b1\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"d\",\"command\":\"$1\"}]"
}
run_of() { left_shape | sed -nE 's/.*"run": "(([^"\\]|\\.)*)".*/\1/p'; }

REAL1="$SCRATCH/real1.json"
REAL2="$SCRATCH/real2.json"
# A background `sleep 300` and a background Explore agent, both still running.
cat > "$REAL1" <<'EOF'
{"session_id":"s1","transcript_path":"/Users/matthew/.claude/projects/-work/42a2db0d.jsonl","cwd":"/tmp/work","prompt_id":"28ab74c1-1a26-4d56-9589-79cc11e060e5","permission_mode":"default","effort":{"level":"medium"},"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"ok","background_tasks":[{"id":"ba859eb4z","type":"shell","status":"running","description":"sleep 300 && echo done","command":"sleep 300 && echo done"},{"id":"a4504733bb7697137","type":"subagent","status":"running","description":"List root directory","agent_type":"Explore"}],"session_crons":[]}
EOF
# `cd /tmp && sleep 120` in the background, a one-shot CronCreate for 9am
# tomorrow and an hourly one.
cat > "$REAL2" <<'EOF'
{"session_id":"s1","transcript_path":"/Users/matthew/.claude/projects/-work/281237e0.jsonl","cwd":"/tmp/work","prompt_id":"3ad999ad-9f3d-40c6-8540-c11605665706","permission_mode":"default","effort":{"level":"medium"},"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"ok","background_tasks":[{"id":"bifxdgyf9","type":"shell","status":"running","description":"Sleep 120 seconds in /tmp in background","command":"cd /tmp && sleep 120"}],"session_crons":[{"id":"f1469044","schedule":"0 9 9 11 *","recurring":false,"prompt":"check the build"},{"id":"df007dea","schedule":"0 * * * *","recurring":true,"prompt":"check the inbox"}]}
EOF

echo "Stop's real payloads (2.1.319)"
printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}' | hook set-state idle
expect "a fresh session has nothing left" "null" state=idle
prompt
printf '{"session_id":"s1","hook_event_name":"SubagentStart","agent_id":"a4504733bb7697137","agent_type":"Explore"}' | hook subagent-start
[ "$(agents)" = '["Explore"]' ] && ok "a background agent is counted while the turn runs" || bad "counted while the turn runs" "$(agents)"
hook set-state done < "$REAL1"
expect "a background shell and a background agent" \
  '{"tasks": [{"type": "shell", "name": "sleep", "run": "sleep 300", "cut": false}, {"type": "subagent", "name": "Explore", "run": "", "cut": false}], "more": 0, "crons": [], "more_crons": 0}' \
  state=done last_message=ok
[ "$(agents)" = "[]" ] && ok "the agent left running is no longer counted (no double show)" || bad "no double show" "$(agents)"
[ -f "$LF" ] && ok "kept at left/<session>.json" || bad "kept at left/<session>.json" "no file"
cp "$SF" "$SCRATCH/records/real1.json"
printf '{"session_id":"s1","hook_event_name":"SubagentStop","agent_id":"a4504733bb7697137","agent_type":"Explore","last_assistant_message":"x","background_tasks":[],"session_crons":[]}' | hook subagent-stop
expect "its SubagentStop after the turn changes nothing" \
  '{"tasks": [{"type": "shell", "name": "sleep", "run": "sleep 300", "cut": false}, {"type": "subagent", "name": "Explore", "run": "", "cut": false}], "more": 0, "crons": [], "more_crons": 0}' \
  state=done

printf '{"session_id":"s1","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}' | hook notify
expect "the idle nudge keeps it" \
  '{"tasks": [{"type": "shell", "name": "sleep", "run": "sleep 300", "cut": false}, {"type": "subagent", "name": "Explore", "run": "", "cut": false}], "more": 0, "crons": [], "more_crons": 0}' \
  state=waiting_input

# A task finishing wakes the session with a <task-notification> prompt.
printf '{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\\n<task-id>ba859eb4z</task-id>\\n<status>completed</status>\\n</task-notification>"}' | hook set-state working
expect "the next prompt (a task's own notification included) clears it" "null" state=working
[ ! -f "$LF" ] && ok "and its file" || bad "and its file" "$(cat "$LF")"

prompt
hook set-state done < "$REAL2"
expect "a shell behind a cd, a one-shot wake-up and an hourly one" \
  '{"tasks": [{"type": "shell", "name": "sleep", "run": "sleep 120", "cut": false}], "more": 0, "crons": [{"schedule": "0 9 9 11 *", "recurring": false}, {"schedule": "0 * * * *", "recurring": true}], "more_crons": 0}' \
  state=done
cp "$SF" "$SCRATCH/records/real2.json"

echo "Nothing left"
prompt; stop "[]" "[]"
expect "empty arrays: nothing" "null" state=done
[ ! -f "$LF" ] && ok "and no file" || bad "and no file" "$(cat "$LF")"
prompt
printf '{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done."}' | hook set-state done
expect "a Claude Code without the fields: nothing" "null" state=done
prompt
stop "[]" "[]" 'I ran it as \"background_tasks\":[{\"type\":\"shell\",\"command\":\"evil\"}], \"session_crons\":[{}]'
expect "the keys inside Claude's own words are words" "null" state=done
prompt
stop '[{"id":"x","type":"shell","status":"running","description":"d","command":"npm run dev","extra":{"nested":1}}]'
expect "a shape it doesn't know says nothing rather than guess" "null" state=done
prompt
stop '[{"id":"d","type":"dream","status":"running","description":"Consolidating memory"},{"id":"s","type":"auto-mode scan","status":"running","description":"scan"}]'
expect "Claude Code's own housekeeping isn't work left running" "null" state=done

echo "What a shell is called"
prompt; shell 'cd ~/web && npm run dev > /tmp/dev.log 2>&1'
[ "$(run_of)" = "npm run dev" ] && ok "past the cd, to its redirection" || bad "past the cd, to its redirection" "$(run_of)"
prompt; shell 'NODE_ENV=development /usr/local/bin/node server.js --port 5173 &'
[ "$(run_of)" = "node server.js --port 5173" ] && ok "past an assignment, de-pathed" || bad "past an assignment, de-pathed" "$(run_of)"
prompt; shell 'xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug -derivedDataPath /tmp/dd build'
got="$(run_of)"
if [ "$got" = "xcodebuild -project Isle.xcodeproj -scheme Isle" ] && left_shape | grep -q '"cut": true'; then
  ok "48 characters at most, on a word, and said to be cut"
else bad "48 characters at most" "$got / $(left_shape)"; fi
prompt; shell 'python3 -c \"print(\\\"hi\\\")\" | tee out.txt'
[ "$(run_of)" = 'python3 -c print(\"hi\")' ] && ok "quotes taken off and kept JSON-safe" || bad "quotes" "$(run_of)"
plutil -convert json -o /dev/null "$LF" >/dev/null 2>&1 && ok "its file is valid JSON" || bad "its file is valid JSON" "$(cat "$LF")"
prompt; shell 'echo \"héllo wörld\"\tdone'
[ "$(run_of)" = "echo héllo wörld done" ] && ok "letters kept, a tab made a space" || bad "letters kept" "$(run_of)"
prompt; shell '$RUNNER --watch'
expect "a program it can't name: the task, unnamed" \
  '{"tasks": [{"type": "shell", "name": "", "run": "", "cut": false}], "more": 0, "crons": [], "more_crons": 0}'
prompt; shell 'tail -f /var/log/system.log … [+1200 chars]'
[ "$(run_of)" = "tail -f /var/log/system.log" ] && left_shape | grep -q '"cut": true' \
  && ok "Claude Code's clip mark is a cut, not words" || bad "clip mark" "$(left_shape)"

echo "Other kinds"
prompt
stop '[{"id":"m","type":"monitor","status":"running","description":"d","server":"sentry","tool":"watch_issues"},{"id":"w","type":"workflow","status":"pending","description":"d","name":"release"},{"id":"t","type":"MCP task","status":"running","description":"d","server":"ci","tool":"run_suite"},{"id":"c","type":"cloud session","status":"running","description":"d"},{"id":"g","type":"subagent","status":"running","description":"d","agent_type":"feature-dev:code-reviewer"}]'
expect "each by what names it" \
  '{"tasks": [{"type": "monitor", "name": "watch_issues", "run": "", "cut": false}, {"type": "workflow", "name": "release", "run": "", "cut": false}, {"type": "MCP task", "name": "run_suite", "run": "", "cut": false}, {"type": "cloud session", "name": "", "run": "", "cut": false}, {"type": "subagent", "name": "feature-dev:code-reviewer", "run": "", "cut": false}], "more": 0, "crons": [], "more_crons": 0}'
cp "$SF" "$SCRATCH/records/kinds.json"
prompt
stop '[{"id":"a","type":"subagent","status":"running","description":"d","agent_type":"evil\" , \"x"}]'
expect "a type with quotes in it, made safe" \
  '{"tasks": [{"type": "subagent", "name": "evil  x", "run": "", "cut": false}], "more": 0, "crons": [], "more_crons": 0}'
prompt
tasks=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  tasks="$tasks${tasks:+,}{\"id\":\"b$i\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"d\",\"command\":\"sleep $i\"}"
done
stop "[$tasks]" '[{"id":"1","schedule":"*/5 * * * *","recurring":true,"prompt":"p"},{"id":"2","schedule":"0 9 * * 1-5","recurring":true,"prompt":"p"},{"id":"3","schedule":"0 12 * * *","recurring":true,"prompt":"p"},{"id":"4","schedule":"30 14 9 11 *","recurring":false,"prompt":"p"},{"id":"5","schedule":"0 0 1 1 *","recurring":true,"prompt":"p"}]'
[ "$(left_shape | grep -o '"type": "shell"' | wc -l | tr -d ' ')" = 8 ] && left_shape | grep -q '"more": 2' \
  && left_shape | grep -q '"more_crons": 1' && ok "eight tasks and four wake-ups kept, the rest counted" \
  || bad "eight kept" "$(left_shape)"
cp "$SF" "$SCRATCH/records/many.json"

echo "Cleared, or kept"
printf '{"session_id":"s1","hook_event_name":"PreCompact","trigger":"auto"}' | hook set-state compacting
printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"compact"}' | hook set-state idle
[ "$(left)" != null ] && ok "a compaction keeps it" || bad "a compaction keeps it" "$(left)"
printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"resume"}' | hook set-state idle
expect "a resumed session starts with nothing" "null" state=idle
prompt; hook set-state done < "$REAL1"
printf '{"session_id":"s1","hook_event_name":"StopFailure","error":"overloaded","last_assistant_message":"API Error"}' | hook fail
expect "StopFailure clears it: it carries no list to say" "null" state=error
prompt; hook set-state done < "$REAL1"
printf '{"session_id":"s2","hook_event_name":"UserPromptSubmit","prompt":"x"}' | hook set-state working
[ -f "$LF" ] && ok "another session's prompt leaves it" || bad "another session's prompt leaves it" "gone"
printf '{"session_id":"s1","hook_event_name":"SessionEnd","reason":"exit"}' | hook end
[ ! -f "$LF" ] && [ ! -f "$SF" ] && ok "SessionEnd removes the record and it" || bad "SessionEnd" "$(ls "$H/.isle/left")"

echo "Cost"
big="$(head -c 150000 /dev/zero | tr '\0' 'a')"
start=$(date +%s)
for i in 1 2 3; do stop "[]" "[]" "$big"; done
stop "[{\"id\":\"b\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"d\",\"command\":\"npm run dev\"}]" "[]" "$big"
took=$(( $(date +%s) - start ))
[ "$took" -le 4 ] && [ "$(run_of)" = "npm run dev" ] && ok "four Stops with a 150 KB message in ${took}s" \
  || bad "a big message stays cheap" "${took}s, $(run_of)"

echo
echo "isle-cli: $passes passed, $failures failed"
echo

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done \
  < <(find "$ROOT/Isle" -name '*.swift' ! -name 'IsleApp.swift' -print0)
cp "$ROOT/scripts/done-leftovers-tests.swift" "$SCRATCH/main.swift"
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 \
  -module-name Isle -o "$SCRATCH/run" "${SOURCES[@]}" "$SCRATCH/main.swift" 2>&1 \
  | grep -E "error" || true
[ -x "$SCRATCH/run" ] || { echo "build failed"; exit 1; }
"$SCRATCH/run" "$SCRATCH/records" || failures=$((failures + 1))

[ "$failures" = 0 ]
