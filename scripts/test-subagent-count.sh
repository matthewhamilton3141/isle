#!/bin/bash
#
# Tests for subagents, counted (Milestone 22): isle-cli's `subagent-start` and
# `subagent-stop` (SubagentStart / SubagentStop) keeping the running agents,
# a stop without a start changing nothing, and the turn's end, the next prompt
# and the session's end clearing them; one agent's approval waiting through
# another agent's tool calls, and let go by its own call's end, the turn's end
# or the next prompt (v16); the record's rewrites racing the session's end and
# newer writes (v16, with a fake `stat` / `ls`); then the app's side, built from
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

echo "An approval waited on, while other agents work"
# Isle is "running": the marker names a live pid (this script's). Subagents'
# hooks carry the parent's session id (2.1.319), so one agent's tool calls land
# on the record while another agent's approval waits in it.
mkdir -p "$H/.isle/run"
echo "$$" > "$H/.isle/run/answering"
RQ="$H/.isle/requests"
ASK_PID=""
# ask_bg <agent_id, or "" for the main agent> <command>: a PermissionRequest
# that blocks, in the background, until its request is in the record.
ask_bg() {
  local agent="" k=0
  [ -z "$1" ] || agent="\"agent_id\":\"$1\",\"agent_type\":\"general-purpose\","
  printf '{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/work","prompt_id":"p1","permission_mode":"default",%s"effort":{"level":"medium"},"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"%s","description":"Run it"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm:*"}],"behavior":"allow","destination":"localSettings"}]}' \
    "$agent" "$2" > "$SCRATCH/ask.in"
  HOME="$H" /bin/bash "$CLI" ask < "$SCRATCH/ask.in" > "$SCRATCH/ask.out" &
  ASK_PID=$!
  while [ "$k" -lt 100 ] && ! grep -qE '"request_id": "[^"]+"' "$SF" 2>/dev/null; do sleep 0.05; k=$((k + 1)); done
}
# tool_hook <event> <agent_id or ""> <tool> <tool_input JSON> [tool_use_id]
tool_hook() {
  local agent="" pre="" post=""
  [ -z "$2" ] || agent="\"agent_id\":\"$2\",\"agent_type\":\"general-purpose\","
  # The order 2.1.319 sends: a failure's error after its tool_use_id.
  case "$1" in
    PostToolUse) pre=',"tool_response":{"stdout":"","stderr":"","interrupted":false}'; post=',"duration_ms":36' ;;
    PostToolUseFailure) post=',"error":"Exit code 1\nls: x: No such file or directory","is_interrupt":false,"duration_ms":36' ;;
  esac
  printf '{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/work","prompt_id":"p1","permission_mode":"default",%s"effort":{"level":"medium"},"hook_event_name":"%s","tool_name":"%s","tool_input":%s%s,"tool_use_id":"%s"%s}' \
    "$agent" "$1" "$3" "$4" "$pre" "${5:-toolu_x}" "$post" | hook set-state working
}
# held <name>: a moment later the hook still waits and the record still holds
# its request. gone <name>: the hook let go within 2s and the record moved on.
held() {
  local id
  sleep 0.6
  id="$(field request_id)"
  if kill -0 "$ASK_PID" 2>/dev/null && [ "$(field state)" = needs_approval ] && [ -n "$id" ] && [ -e "$RQ/$id.json" ]; then
    ok "$1"
  else
    bad "$1" "state $(field state), request_id '$id', hook $(kill -0 "$ASK_PID" 2>/dev/null && echo waiting || echo gone)"
  fi
}
gone() {
  local k=0 want="$2"
  while [ "$k" -lt 20 ] && kill -0 "$ASK_PID" 2>/dev/null; do sleep 0.1; k=$((k + 1)); done
  if ! kill -0 "$ASK_PID" 2>/dev/null && [ -z "$(field request_id)" ] && [ "$(field state)" = "$want" ] \
     && [ -z "$(ls "$RQ" 2>/dev/null)" ] && [ ! -s "$SCRATCH/ask.out" ]; then
    ok "$1"
  else
    bad "$1" "state $(field state), request_id '$(field request_id)', hook $(kill -0 "$ASK_PID" 2>/dev/null && echo waiting || echo gone), out '$(cat "$SCRATCH/ask.out")'"
    kill "$ASK_PID" 2>/dev/null; wait "$ASK_PID" 2>/dev/null
  fi
}
RM='{"command":"rm -rf build","description":"Run it"}'
prompt; start a1 general-purpose; start a2 general-purpose
ask_bg a1 'rm -rf build'
tool_hook PreToolUse a2 Grep '{"pattern":"TODO","path":"/tmp/work"}' toolu_g1
held "another agent's PreToolUse leaves the approval waiting"
tool_hook PostToolUse a2 Grep '{"pattern":"TODO","path":"/tmp/work"}' toolu_g1
held "and its PostToolUse"
tool_hook PreToolUse "" Read '{"file_path":"/tmp/work/a.txt"}' toolu_r1
tool_hook PostToolUse "" Read '{"file_path":"/tmp/work/a.txt"}' toolu_r1
held "the main agent's parallel tools too"
tool_hook PostToolUse a1 Bash '{"command":"rm -rf dist","description":"Run it"}' toolu_b0
held "the same agent finishing another command"
printf '{"session_id":"s1","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}' | hook notify
printf '{"session_id":"s1","hook_event_name":"PreCompact","trigger":"auto"}' | hook set-state compacting
held "a notification, a compaction"
stop a2 general-purpose
held "a subagent stopping"
[ "$(agents)" = '["general-purpose"]' ] && ok "  (and is counted out)" || bad "  counted out" "$(agents)"
tool_hook PostToolUse a1 Bash "$RM" toolu_b1
gone "Yes in the terminal: the call's own PostToolUse lets the hook go" working
ask_bg a1 'rm -rf build'
tool_hook PostToolUseFailure a1 Bash "$RM" toolu_b2
gone "Yes in the terminal, and the command failed: its PostToolUseFailure" working
ask_bg "" 'rm -rf build'
tool_hook PostToolUse a1 Bash "$RM" toolu_b3
held "the same command from another agent is not this call"
tool_hook PostToolUse "" Bash "$RM" toolu_b3
gone "the main agent's own call, the same way" working
ask_bg a1 'rm -rf build'
prompt
gone "a new prompt (Esc, then typing) lets it go" working
ask_bg a1 'rm -rf build'
end_turn
gone "the turn's end lets it go" done
prompt
# A hook killed outright (its trap never ran): the request file is left, its
# pid is dead, and nothing is waiting behind the record any more.
/usr/bin/true & dead=$!; wait "$dead"
mkdir -p "$RQ"; cp "$SCRATCH/ask.in" "$RQ/s1-1794121762-$dead.json"
sed -i '' -e 's/^  "state": .*/  "state": "needs_approval",/' -e "s/^  \"request_id\": .*/  \"request_id\": \"s1-1794121762-$dead\",/" "$SF"
tool_hook PreToolUse a2 Grep '{"pattern":"x"}' toolu_g2
[ "$(field state)" = working ] && [ -z "$(field request_id)" ] && ok "a request whose hook is dead holds nothing" \
  || bad "a request whose hook is dead holds nothing" "state $(field state), request_id '$(field request_id)'"
rm -f "$RQ"/*.json
# The question (`ask-question`, a PreToolUse with its own tool_use_id).
QI='{"questions":[{"question":"Which?","header":"Pick","multiSelect":false,"options":[{"label":"A","description":"a"},{"label":"B","description":"b"}]}]}'
printf '{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/work","prompt_id":"p1","permission_mode":"default","agent_id":"a1","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":%s,"tool_use_id":"toolu_q1"}' "$QI" \
  | HOME="$H" /bin/bash "$CLI" ask-question > "$SCRATCH/ask.out" &
ASK_PID=$!
k=0; while [ "$k" -lt 100 ] && ! grep -qE '"request_id": "[^"]+"' "$SF" 2>/dev/null; do sleep 0.05; k=$((k + 1)); done
tool_hook PreToolUse a2 Grep '{"pattern":"TODO"}' toolu_g3
sleep 0.6
kill -0 "$ASK_PID" 2>/dev/null && [ "$(field state)" = needs_question ] && [ -n "$(field request_id)" ] \
  && ok "a question waited on: another agent's tool leaves it" || bad "a question waited on" "state $(field state), request_id '$(field request_id)'"
tool_hook PostToolUse a1 AskUserQuestion "$QI" toolu_q1
gone "its own PostToolUse lets it go" working
rm -f "$H/.isle/run/answering"
end_turn

echo "Rewrites racing the session's end"
# A fake `stat` / `ls` in front of the real one, counting its calls in the hook
# under test: before its call N it runs FAKE_DO_N, landing another hook
# mid-rewrite, and leaves FB/landed.N to say so.
FB="$SCRATCH/fakebin"; mkdir -p "$FB"
for tool in stat:/usr/bin/stat ls:/bin/ls; do
  cat > "$FB/${tool%%:*}" <<EOF
#!/bin/bash
c="$FB/count.\$(basename "\$0")"
n=\$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$c"
v="FAKE_DO_\$n"
if [ "\$(basename "\$0")" = "\${FAKE_TOOL:-}" ] && [ -n "\${!v:-}" ]; then
  ( d="\${!v}"; unset FAKE_TOOL; PATH=/usr/bin:/bin:/usr/sbin:/sbin; eval "\$d" )
  : > "$FB/landed.\$n"
fi
exec ${tool#*:} "\$@"
EOF
  chmod +x "$FB/${tool%%:*}"
done
# raced <tool> <what lands before its call 1, or ""> <before call 2, or ""> <hook…>
raced() {
  local tool="$1" one="$2" two="$3"; shift 3
  rm -f "$FB"/count.* "$FB"/landed.*
  FAKE_TOOL="$tool" FAKE_DO_1="$one" FAKE_DO_2="$two" PATH="$FB:$PATH" "$@"
}
END_S1="printf '{\"session_id\":\"s1\",\"hook_event_name\":\"SessionEnd\"}' | HOME='$H' /bin/bash '$CLI' end"
NEWER="printf '{\"session_id\":\"s1\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/tmp/newer.txt\"},\"tool_use_id\":\"t9\"}' | HOME='$H' /bin/bash '$CLI' set-state working"
# The review's case (v15): `stat` saw a new inode after the read, the pass went
# round again with nothing to read, and the first pass's temp file went back
# into place. A rewrite has no `stat` left for it to land in.
prompt; start r1 Explore
raced stat "" "$END_S1" start r2 Explore
if [ -e "$FB/landed.2" ] && [ -e "$SF" ]; then
  bad "SessionEnd after the inode check's read brought the record back" "state $(field state), subagents $(agents)"
else
  ok "SessionEnd after the read, seen as a new inode: stays ended"
fi
prompt; start r1 Explore
raced ls "$END_S1" "" start r2 Explore
[ -e "$FB/landed.1" ] && [ ! -e "$SF" ] && ok "SessionEnd between the read and the rename: stays ended" \
  || bad "SessionEnd between the read and the rename" "landed: $(ls "$FB" | grep landed), state $(field state)"
prompt; start r1 Explore
raced ls "$NEWER" "$END_S1" start r2 Explore
[ -e "$FB/landed.2" ] && [ ! -e "$SF" ] && ok "a newer write, then SessionEnd in the pass after it: stays ended" \
  || bad "a newer write, then SessionEnd" "landed: $(ls "$FB" | grep landed), state $(field state)"
prompt; start r1 Explore
raced ls "$NEWER" "" start r2 Explore
expect "a newer write mid-rewrite is kept, with the count" '["Explore", "Explore"]' state=working action=Read target=newer.txt
ls "$H/.isle/sessions" | grep -q tmp && bad "no temp file left behind" "$(ls "$H/.isle/sessions")" || ok "no temp file left behind"
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
