#!/bin/bash
#
# Tests for subagents, counted (Milestone 22): isle-cli's `subagent-start` and
# `subagent-stop` (SubagentStart / SubagentStop) keeping the running agents,
# a stop without a start changing nothing, and the turn's end, the next prompt
# and the session's end clearing them; then the app's side, built from
# scripts/subagent-count-tests.swift with every Isle source: the record
# parser on the files this run wrote, and the line the face shows. Payloads
# are in the shape Claude Code 2.1.319 sent them (agent ids and types from a
# real run; paths shortened). Run the way Claude Code runs the hooks — a
# payload on stdin — under a scratch HOME, so nothing touches ~/.isle.
#
# Usage: scripts/test-subagent-count.sh [path/to/isle-cli]
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${1:-$ROOT/integration/claude-code-hooks/isle-cli}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/isle-subagent-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
H="$SCRATCH/home"
mkdir -p "$H/.isle/sessions" "$SCRATCH/records"
SF="$H/.isle/sessions/s1.json"
AD="$H/.isle/subagents/s1"

passes=0
failures=0

ok() { passes=$((passes + 1)); echo "  ok    $1"; }
bad() { failures=$((failures + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

field() { sed -nE "s/^  \"$1\": \"?([^\",]*)\"?,?$/\\1/p" "${2:-$SF}"; }
agents() { sed -nE 's/^  "subagents": (.*),$/\1/p' "${1:-$SF}"; }

# expect <name> <want subagents json> [field=value…]
expect() {
  local name="$1" want="$2" kv f v got all=""
  shift 2
  got="$(agents)"
  [ "$got" = "$want" ] || all="subagents: want '$want', got '$got';"
  for kv in "$@"; do
    f="${kv%%=*}"; v="${kv#*=}"; got="$(field "$f")"
    [ "$got" = "$v" ] || all="$all $f: want '$v', got '$got';"
  done
  plutil -convert json -o /dev/null "$SF" >/dev/null 2>&1 || all="$all not valid JSON;"
  if [ -z "$all" ]; then ok "$name"; else bad "$name" "$all"; fi
}

hook() { HOME="$H" /bin/bash "$CLI" "$@"; }

# The real payloads' shape (2.1.319), trimmed of paths.
start() {  # start <agent_id> <agent_type> [session]
  printf '{"session_id":"%s","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/work","prompt_id":"p1","agent_id":"%s","agent_type":"%s","hook_event_name":"SubagentStart"}' \
    "${3:-s1}" "$1" "$2" | hook subagent-start
}
stop() {  # stop <agent_id> <agent_type> [session]
  printf '{"session_id":"%s","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/work","prompt_id":"p1","permission_mode":"default","agent_id":"%s","agent_type":"%s","effort":{"level":"medium"},"hook_event_name":"SubagentStop","stop_hook_active":false,"agent_transcript_path":"/tmp/t/subagents/agent-%s.jsonl","last_assistant_message":"The directory contains one file: `a.txt`.\\n\\nI made no changes.","background_tasks":[],"session_crons":[]}' \
    "${3:-s1}" "$1" "$2" "$1" | hook subagent-stop
}
prompt() { printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"look around"}' "${1:-s1}" | hook set-state working; }
agent_tool() {
  printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"List files","prompt":"List the files.","subagent_type":"Explore","run_in_background":false},"tool_use_id":"toolu_1"}' \
    | hook set-state working
}
sub_tool() {  # a tool call inside a subagent: the parent's session id, the agent's id
  printf '{"session_id":"s1","hook_event_name":"PreToolUse","agent_id":"%s","agent_type":"Explore","tool_name":"Bash","tool_input":{"command":"ls -la /tmp/work","description":"List"},"tool_use_id":"toolu_2"}' "$1" \
    | hook set-state working
}
end_turn() { printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done.","background_tasks":[],"session_crons":[]}' "${1:-s1}" | hook set-state done; }

echo "SubagentStart / SubagentStop"
printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}' | hook set-state idle
expect "a fresh session has none" "[]" state=idle
prompt
agent_tool
start a70394980b44198b6 Explore
expect "one start: counted, the record otherwise as the last hook left it" '["Explore"]' \
  state=working action=Agent tool_active=true
cp "$SF" "$SCRATCH/records/one.json"
start a4e45b92f8fd0dd6c Explore
start a1b2c3d4e5f600001 Plan
expect "parallel starts, in the order they started" '["Explore", "Explore", "Plan"]' state=working
cp "$SF" "$SCRATCH/records/three.json"
start a4e45b92f8fd0dd6c Explore
expect "a start seen twice counts once" '["Explore", "Explore", "Plan"]'
sub_tool a70394980b44198b6
expect "a subagent's own tool call keeps the count" '["Explore", "Explore", "Plan"]' state=working target=ls
stop a4e45b92f8fd0dd6c Explore
expect "a stop counts its agent out" '["Explore", "Plan"]' state=working target=ls
[ ! -e "$AD/a4e45b92f8fd0dd6c" ] && ok "its file is gone" || bad "its file is gone" "$(ls "$AD")"

before="$(stat -f %i "$SF") $(cat "$SF")"
stop a0000000000internal general-purpose
after="$(stat -f %i "$SF") $(cat "$SF")"
if [ "$before" = "$after" ]; then ok "a stop without a start changes nothing, not even the file"; else bad "a stop without a start changes nothing" "$(agents)"; fi
printf '{"session_id":"s1","hook_event_name":"SubagentStop","last_assistant_message":"x"}' | hook subagent-stop
after="$(stat -f %i "$SF") $(cat "$SF")"
[ "$before" = "$after" ] && ok "a stop with no agent_id changes nothing" || bad "a stop with no agent_id changes nothing" "$(agents)"

stop a70394980b44198b6 Explore
stop a1b2c3d4e5f600001 Plan
expect "every agent stopped: none" "[]" state=working
[ ! -d "$AD" ] && ok "the session's directory goes with its last agent" || bad "the session's directory goes with its last agent" "$(ls -la "$AD")"

echo "Cleared when the turn, or the session, ends"
start x1 Explore; start x2 Plan
end_turn
expect "Stop clears them" "[]" state=done last_message=Done.
[ ! -d "$AD" ] && ok "and their files" || bad "and their files" "$(ls "$AD")"
stop x1 Explore
expect "a stop after the turn's end counts nothing out (or back)" "[]" state=done

prompt; start y1 Explore
printf '{"session_id":"s1","hook_event_name":"StopFailure","error":"overloaded","last_assistant_message":"API Error"}' | hook fail
expect "StopFailure clears them" "[]" state=error

prompt; start z1 Explore
prompt
expect "a new prompt clears a turn's leftovers (an interrupt fires no Stop)" "[]" state=working

start c1 Explore
printf '{"session_id":"s1","hook_event_name":"PreCompact","trigger":"auto"}' | hook set-state compacting
printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"compact"}' | hook set-state idle
expect "a compaction mid-turn keeps them" '["Explore"]' state=idle
printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"resume"}' | hook set-state idle
expect "a resumed session starts with none" "[]" state=idle

prompt; start e1 Explore
start o1 Plan s2
printf '{"session_id":"s1","hook_event_name":"SessionEnd","reason":"exit"}' | hook end
[ ! -e "$SF" ] && [ ! -d "$AD" ] && ok "SessionEnd removes the record and the agents" || bad "SessionEnd removes the record and the agents" "$(ls "$H/.isle/subagents")"
[ "$(agents "$H/.isle/sessions/s2.json")" = '["Plan"]' ] && ok "another session's agents are its own" \
  || bad "another session's agents are its own" "$(agents "$H/.isle/sessions/s2.json")"
printf '{"hook_event_name":"Stop"}' | hook set-state done
[ -e "$H/.isle/subagents/s2/o1" ] && ok "a Stop with no session id clears no one's" || bad "a Stop with no session id clears no one's" "s2 lost o1"

echo "Records it didn't write first"
rm -f "$SF"
start n1 Explore
expect "no record yet (installed mid-session): a working one" '["Explore"]' state=working
cat > "$SF" <<'EOF'
{
  "state": "working",
  "project": "isle",
  "session_id": "s1",
  "action": "Read",
  "target": "notes.txt",
  "tool_active": true,
  "request_id": "",
  "last_message": "",
  "updated_at": "2026-11-08T00:00:00Z"
}
EOF
start n2 Plan
expect "a record from an older helper gets the field" '["Explore", "Plan"]' state=working target=notes.txt
[ "$(field updated_at)" != "2026-11-08T00:00:00Z" ] && ok "and a fresh updated_at" || bad "and a fresh updated_at" "$(field updated_at)"
cat > "$SF" <<'EOF'
{
  "state": "needs_approval",
  "project": "isle",
  "session_id": "s1",
  "action": "Bash",
  "target": "rm",
  "tool_active": false,
  "request_id": "s1-1794121762-4242",
  "request_kind": "approval",
  "last_message": "",
  "subagents": ["Explore", "Plan"],
  "updated_at": "2026-11-08T00:00:00Z"
}
EOF
start n3 general-purpose
expect "an approval being waited on keeps its request id" '["Explore", "Plan", "general-purpose"]' \
  state=needs_approval request_id=s1-1794121762-4242 request_kind=approval

echo "Types made safe"
end_turn
start h1 'feature-dev:code-reviewer'
start h2 'evil\" , \"x'
start h3 ''
expect "a plugin's type kept whole, cut at an escaped quote, a missing one empty" \
  '["feature-dev:code-reviewer", "evil", ""]'
cp "$SF" "$SCRATCH/records/odd.json"
end_turn

echo "Many at once"
prompt
for i in 01 02 03 04 05 06 07 08 09 10; do start "p$i" Explore & done
wait
sub_tool p01
n="$(agents | grep -o Explore | wc -l | tr -d ' ')"
[ "$n" = 10 ] && ok "ten started in parallel: ten" || bad "ten started in parallel: ten" "$(agents)"
for i in 01 02 03 04 05 06 07 08 09 10; do stop "p$i" Explore & done
wait
expect "ten stopped in parallel: none" "[]" state=working

echo
echo "isle-cli: $passes passed, $failures failed"
echo

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done \
  < <(find "$ROOT/Isle" -name '*.swift' ! -name 'IsleApp.swift' -print0)
cp "$ROOT/scripts/subagent-count-tests.swift" "$SCRATCH/main.swift"
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 \
  -module-name Isle -o "$SCRATCH/run" "${SOURCES[@]}" "$SCRATCH/main.swift" 2>&1 \
  | grep -E "error" || true
[ -x "$SCRATCH/run" ] || { echo "build failed"; exit 1; }
"$SCRATCH/run" "$SCRATCH/records" || failures=$((failures + 1))

[ "$failures" = 0 ]
