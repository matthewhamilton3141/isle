#!/bin/bash
#
# Tests for auto mode's blocks, shown (Milestone 23): isle-cli's `denied`
# (PermissionDenied) keeping the session's last blocked call — its tool,
# program, the command's first line up to 48 characters, auto mode's reason
# and how many since the last prompt — in every record as `blocked`, without
# changing the state; the call no longer reading as running; and the next
# prompt and the session's end clearing it, but not Stop; parallel blocks all
# counted, and the rewrite racing the session's end (v16). Then the app's side,
# built from scripts/auto-mode-blocks-tests.swift with every Isle source: the
# record parser on the files this run wrote, the reason read as a category or
# a refusal without a judgment, the face's line, the toast and its timing.
# Payloads are in the shape Claude Code 2.1.319 sent them (the first is a real
# block from a haiku run in auto mode, paths shortened). Run the way Claude
# Code runs the hooks — a payload on stdin — under a scratch HOME, so nothing
# touches ~/.isle.
#
# Usage: scripts/test-auto-mode-blocks.sh [path/to/isle-cli]
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${1:-$ROOT/integration/claude-code-hooks/isle-cli}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/isle-block-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
H="$SCRATCH/home"
mkdir -p "$H/.isle/sessions" "$SCRATCH/records"
SF="$H/.isle/sessions/s1.json"
BF="$H/.isle/blocked/s1.json"

passes=0
failures=0

ok() { passes=$((passes + 1)); echo "  ok    $1"; }
bad() { failures=$((failures + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

field() { sed -nE "s/^  \"$1\": \"?([^\",]*)\"?,?$/\\1/p" "${2:-$SF}"; }
blocked() { sed -nE 's/^  "blocked": (.*),$/\1/p' "${1:-$SF}"; }

# expect <name> <want blocked json> [field=value…]: the record's `blocked`
# exactly, each field as given, and the record valid JSON.
expect() {
  local name="$1" want="$2" kv f v got all=""
  shift 2
  got="$(blocked)"
  [ "$got" = "$want" ] || all="blocked: want '$want', got '$got';"
  for kv in "$@"; do
    f="${kv%%=*}"; v="${kv#*=}"; got="$(field "$f")"
    [ "$got" = "$v" ] || all="$all $f: want '$v', got '$got';"
  done
  plutil -convert json -o /dev/null "$SF" >/dev/null 2>&1 || all="$all not valid JSON;"
  if [ -z "$all" ]; then ok "$name"; else bad "$name" "$all"; fi
}

# The block's own fields, read from the block file: blk <key>.
blk() { sed -nE "s/.*\"$1\": \"?([^\",}]*)\"?[,}].*/\\1/p" "$BF"; }
# The block file's command, escapes and all.
blk_command() { sed -nE 's/.*"command": "(.*)", "cut".*/\1/p' "$BF"; }

hook() { HOME="$H" /bin/bash "$CLI" "$@"; }

base='"transcript_path":"/tmp/t.jsonl","cwd":"/tmp/proj","prompt_id":"f6464d7b","permission_mode":"auto","effort":{"level":"medium"}'

prompt() { printf '{"session_id":"%s",%s,"hook_event_name":"UserPromptSubmit","prompt":"Work through TODO.md."}' "${1:-s1}" "$base" | hook set-state working; }
pre() {  # pre <command, as JSON text> [session]
  printf '{"session_id":"%s",%s,"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s","description":"Run it"},"tool_use_id":"toolu_pre"}' \
    "${2:-s1}" "$base" "$1" | hook set-state working
}
# denied <tool_use_id> <command, as JSON text> <reason, as JSON text> [session] [tool]
denied() {
  local tool="${5:-Bash}" input
  input="{\"command\":\"$2\",\"description\":\"Run both TODO housekeeping steps\"}"
  [ "$tool" = Bash ] || [ "$tool" = Monitor ] || input="$2"
  printf '{"session_id":"%s",%s,"hook_event_name":"PermissionDenied","tool_name":"%s","tool_input":%s,"tool_use_id":"%s","reason":"%s"}' \
    "${4:-s1}" "$base" "$tool" "$input" "$1" "$3" | hook denied
}
end_turn() { printf '{"session_id":"%s",%s,"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"I skipped the /tmp sweep: auto mode blocked it.","background_tasks":[],"session_crons":[]}' "${1:-s1}" "$base" | hook set-state done; }

# The real one (2.1.319): a compound command, an escaped quote at character 44.
REAL_CMD='rm -rf ../victim && echo \"victim removed: $(test -e ../victim && echo no || echo yes)\"; find /tmp -name \"*.zz9-nothing-matches\" -delete; echo \"find exit: $?\"'

echo "PermissionDenied"
printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}' | hook set-state idle
expect "a fresh session has no block" "null" state=idle
prompt
pre "$REAL_CMD"
expect "the call's PreToolUse: running, as before" "null" state=working action=Bash target=rm tool_active=true
start_ms="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
denied toolu_012JgyzrLEk1tuqf9XYrQG4J "$REAL_CMD" '[Shared Scratch Sweep]'
end_ms="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
want='{"id": "toolu_012JgyzrLEk1tuqf9XYrQG4J", "tool": "Bash", "target": "rm", "command": "rm -rf ../victim && echo \"victim removed: $(test", "cut": true, "reason": "[Shared Scratch Sweep]", "count": 1, "at": "'"$(blk at)"'"}'
expect "the block, in the record: program, the command's first 48, the reason; the state kept" "$want" \
  state=working tool_active=false action= target=
[ "$(blk_command)" = 'rm -rf ../victim && echo \"victim removed: $(test' ] \
  && ok "the command cut on whole tokens (an escaped quote is one)" || bad "the command cut on whole tokens" "$(blk_command)"
cp "$SF" "$SCRATCH/records/real.json"
echo "        (denied took $((end_ms - start_ms)) ms)"

denied toolu_012JgyzrLEk1tuqf9XYrQG4J "$REAL_CMD" '[Shared Scratch Sweep]'
[ "$(blk count)" = 1 ] && ok "the same call reported twice counts once" || bad "the same call reported twice counts once" "$(cat "$BF")"

pre 'ls -la'
expect "carried by the next hook's write; the new call runs" "$want" state=working action=Bash target=ls tool_active=true
pre 'git push --force origin main'
denied toolu_2 'git push --force origin main' '[Git Destructive]'
expect "a second block: the latest, counted" \
  '{"id": "toolu_2", "tool": "Bash", "target": "git", "command": "git push --force origin main", "cut": false, "reason": "[Git Destructive]", "count": 2, "at": "'"$(blk at)"'"}' \
  state=working tool_active=false
cp "$SF" "$SCRATCH/records/two.json"
end_turn
[ "$(blk count)" = 2 ] && [ "$(field state)" = done ] && [ -n "$(field last_message)" ] \
  && ok "Stop keeps it, for the Done face" || bad "Stop keeps it" "$(blocked)"
cp "$SF" "$SCRATCH/records/done.json"
printf '{"session_id":"s1","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}' | hook notify
[ "$(blk count)" = 2 ] && [ "$(field state)" = waiting_input ] && ok "so does the idle nudge after it" || bad "the idle nudge keeps it" "$(blocked)"
prompt
expect "the next prompt clears it" "null" state=working
[ ! -e "$BF" ] && ok "and its file" || bad "and its file" "$(cat "$BF")"

echo "The reason and the command"
denied toolu_3 'terraform apply -auto-approve' 'Classifier unavailable'
[ "$(blk reason)" = "Classifier unavailable" ] && [ "$(blk cut)" = false ] && [ "$(blk target)" = terraform ] \
  && ok "a refusal without a judgment, kept in auto mode's words" || bad "a refusal without a judgment" "$(cat "$BF")"
cp "$SF" "$SCRATCH/records/unchecked.json"
prompt
printf '{"session_id":"s1",%s,"hook_event_name":"PermissionDenied","tool_name":"mcp__notes__file","tool_input":{"title":"x","reason":"[Not The Reason]"},"tool_use_id":"toolu_4","reason":"[External System Writes]"}' "$base" | hook denied
[ "$(blk reason)" = "[External System Writes]" ] && [ "$(blk command)" = "" ] && [ "$(blk tool)" = mcp__notes__file ] \
  && ok "a tool's input with a reason of its own: the hook's reason is the last" || bad "the hook's reason is the last" "$(cat "$BF")"
prompt
denied toolu_5 'echo \"a\"\nrm -rf build' '[Irreversible Local Destruction]'
[ "$(blk_command)" = 'echo \"a\"' ] && [ "$(blk cut)" = true ] \
  && ok "the first line only, and cut says there was more" || bad "the first line only" "$(cat "$BF")"
prompt
denied toolu_6 'cd /Users/matthew/Documents/isle-website/packages/site && git push --force' '[Git Destructive]'
[ "$(blk target)" = git ] && [ "$(blk cut)" = true ] \
  && ok "a long cd in front: the program is still git" || bad "a long cd in front" "$(cat "$BF")"
prompt
denied toolu_7 'rm -rf /tmp/build' '[A \"quoted\" \\ rule]\nsecond line'
plutil -convert json -o /dev/null "$SF" >/dev/null 2>&1 && plutil -convert json -o /dev/null "$BF" >/dev/null 2>&1 \
  && ok "a reason with quotes, a backslash and a newline: the record still reads" || bad "a hostile reason" "$(cat "$BF")"
cp "$SF" "$SCRATCH/records/hostile.json"
prompt
denied toolu_8 'printf \"café 日本\"' '[Data Exfiltration]'
plutil -convert json -o /dev/null "$SF" >/dev/null 2>&1 && [ "$(blk target)" = printf ] \
  && ok "non-ASCII in the command" || bad "non-ASCII in the command" "$(cat "$BF")"
prompt
printf '{"session_id":"s1",%s,"hook_event_name":"PermissionDenied","tool_name":"Write","tool_input":{"file_path":"/Users/matthew/.claude/settings.json","content":"{}"},"tool_use_id":"toolu_9","reason":"[Self-Modification]"}' "$base" | hook denied
[ "$(blk tool)" = Write ] && [ "$(blk target)" = settings.json ] && [ "$(blk command)" = "" ] \
  && ok "another tool: the file's name, no command" || bad "another tool" "$(cat "$BF")"
cp "$SF" "$SCRATCH/records/write.json"

echo "Records it didn't write first"
prompt
rm -f "$SF"
denied toolu_10 'rm -rf /tmp/build' '[Irreversible Local Destruction]'
expect "no record yet: a working one, with the block" \
  '{"id": "toolu_10", "tool": "Bash", "target": "rm", "command": "rm -rf /tmp/build", "cut": false, "reason": "[Irreversible Local Destruction]", "count": 1, "at": "'"$(blk at)"'"}' \
  state=working action= tool_active=false
prompt
cat > "$SF" <<'EOF'
{
  "state": "working",
  "project": "isle",
  "session_id": "s1",
  "action": "Bash",
  "target": "rm",
  "tool_active": true,
  "request_id": "",
  "last_message": "",
  "subagents": ["Explore"],
  "updated_at": "2026-11-08T00:00:00Z"
}
EOF
denied toolu_11 'rm -rf /tmp/build' '[Irreversible Local Destruction]'
[ -n "$(blocked)" ] && [ "$(blocked)" != null ] && [ "$(field updated_at)" != "2026-11-08T00:00:00Z" ] \
  && [ "$(sed -nE 's/^  "subagents": (.*),$/\1/p' "$SF")" = '["Explore"]' ] \
  && plutil -convert json -o /dev/null "$SF" >/dev/null 2>&1 \
  && ok "a record from an older helper gets the field, keeps the rest" || bad "an older helper's record" "$(cat "$SF")"
prompt
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
  "blocked": null,
  "subagents": [],
  "updated_at": "2026-11-08T00:00:00Z"
}
EOF
denied toolu_12 'rm -rf /tmp/build' '[Irreversible Local Destruction]'
expect "another tool in the record (a parallel call): left as it is" \
  '{"id": "toolu_12", "tool": "Bash", "target": "rm", "command": "rm -rf /tmp/build", "cut": false, "reason": "[Irreversible Local Destruction]", "count": 1, "at": "'"$(blk at)"'"}' \
  state=working action=Read target=notes.txt
cat > "$SF" <<'EOF'
{
  "state": "needs_approval",
  "project": "isle",
  "session_id": "s1",
  "action": "Bash",
  "target": "npm",
  "tool_active": false,
  "request_id": "s1-1794121762-4242",
  "request_kind": "approval",
  "last_message": "",
  "blocked": null,
  "subagents": [],
  "updated_at": "2026-11-08T00:00:00Z"
}
EOF
denied toolu_13 'rm -rf /tmp/build' '[Irreversible Local Destruction]' s1 Bash
[ "$(field state)" = needs_approval ] && [ "$(field request_id)" = s1-1794121762-4242 ] && [ "$(field target)" = npm ] \
  && ok "an approval being waited on keeps its state and request id" || bad "an approval being waited on" "$(cat "$SF")"

echo "Many at once, and racing the session's end"
prompt
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do denied "toolu_p$i" 'rm -rf /tmp/build' '[Irreversible Local Destruction]' & done
wait
[ "$(blk count)" = 12 ] && [ "$(sed -nE 's/.*"count": ([0-9]+).*/\1/p' <<< "$(blocked)")" = 12 ] \
  && ok "twelve blocked in parallel: twelve, in the file and the record" || bad "twelve blocked in parallel" "file $(blk count), record $(blocked)"
ls -a "$H/.isle/blocked" | grep -q lock && bad "no lock left behind" "$(ls -a "$H/.isle/blocked")" || ok "no lock left behind"
mkdir -p "$H/.isle/blocked/.s1.lock"
t0=$SECONDS
denied toolu_p13 'rm -rf /tmp/build' '[Irreversible Local Destruction]'
[ "$(blk count)" = 13 ] && [ $((SECONDS - t0)) -le 4 ] && [ ! -d "$H/.isle/blocked/.s1.lock" ] \
  && ok "a lock its holder never let go of is taken after a wait" || bad "a stale lock" "count $(blk count), $((SECONDS - t0))s, $(ls -a "$H/.isle/blocked")"
# A fake `stat` / `date` in front of the real one, counting its calls in the
# hook under test: before call FAKE_AT it runs FAKE_DO, landing SessionEnd
# mid-rewrite, and leaves FB/landed to say so.
FB="$SCRATCH/fakebin"; mkdir -p "$FB"
for tool in stat:/usr/bin/stat date:/bin/date; do
  cat > "$FB/${tool%%:*}" <<EOF
#!/bin/bash
c="$FB/count.\$(basename "\$0")"
n=\$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$c"
if [ "\$(basename "\$0")" = "\${FAKE_TOOL:-}" ] && [ "\$n" = "\${FAKE_AT:-}" ]; then
  ( unset FAKE_TOOL FAKE_AT; PATH=/usr/bin:/bin:/usr/sbin:/sbin; eval "\$FAKE_DO" )
  : > "$FB/landed"
fi
exec ${tool#*:} "\$@"
EOF
  chmod +x "$FB/${tool%%:*}"
done
END_S1="printf '{\"session_id\":\"s1\",\"hook_event_name\":\"SessionEnd\"}' | HOME='$H' /bin/bash '$CLI' end"
# The review's case (v15): `stat` saw a new inode after the read, the pass went
# round again with nothing to read, and the first pass's temp file went back
# into place. A rewrite has no `stat` left for it to land in.
prompt
pre 'rm -rf /tmp/build'
rm -f "$FB"/count.* "$FB/landed"
FAKE_TOOL=stat FAKE_AT=2 FAKE_DO="$END_S1" PATH="$FB:$PATH" denied toolu_r1 'rm -rf /tmp/build' '[Irreversible Local Destruction]'
if [ -e "$FB/landed" ] && [ -e "$SF" ]; then
  bad "SessionEnd after the inode check's read brought the record back" "state $(field state), blocked $(blocked)"
else
  ok "SessionEnd after the read, seen as a new inode: stays ended"
fi
# The rewrite's own window: its timestamp is taken between the read and the rename.
prompt
pre 'rm -rf /tmp/build'
rm -f "$FB"/count.* "$FB/landed"
FAKE_TOOL=date FAKE_AT=2 FAKE_DO="$END_S1" PATH="$FB:$PATH" denied toolu_r2 'rm -rf /tmp/build' '[Irreversible Local Destruction]'
[ -e "$FB/landed" ] && [ ! -e "$SF" ] && ok "SessionEnd between the read and the rename: stays ended" \
  || bad "SessionEnd between the read and the rename" "landed $([ -e "$FB/landed" ] && echo yes || echo no), state $(field state)"
ls "$H/.isle/sessions" | grep -q tmp && bad "no temp file left behind" "$(ls "$H/.isle/sessions")" || ok "no temp file left behind"

echo "Other sessions, and the session's end"
prompt s2
denied toolu_14 'rm -rf /tmp/other' '[Shared Scratch Sweep]' s2
[ -e "$H/.isle/blocked/s2.json" ] && [ "$(field state "$H/.isle/sessions/s2.json")" = working ] \
  && ok "a block is its own session's" || bad "a block is its own session's" "$(ls "$H/.isle/blocked")"
printf '{"session_id":"s2","hook_event_name":"SessionStart","source":"compact"}' | hook set-state idle
[ -e "$H/.isle/blocked/s2.json" ] && ok "a compaction keeps it" || bad "a compaction keeps it" "gone"
printf '{"session_id":"s2","hook_event_name":"SessionStart","source":"resume"}' | hook set-state idle
[ ! -e "$H/.isle/blocked/s2.json" ] && ok "a resumed session starts with none" || bad "a resumed session starts with none" "kept"
denied toolu_15 'rm -rf /tmp/other' '[Shared Scratch Sweep]' s2
printf '{"session_id":"s2","hook_event_name":"SessionEnd","reason":"exit"}' | hook end
[ ! -e "$H/.isle/blocked/s2.json" ] && [ ! -e "$H/.isle/sessions/s2.json" ] \
  && ok "SessionEnd removes the record and the block" || bad "SessionEnd removes the block" "$(ls "$H/.isle/blocked")"
printf '{"hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"rm -rf x"},"tool_use_id":"t","reason":"[X]"}' | hook denied
[ ! -e "$H/.isle/blocked/.json" ] && [ ! -e "$H/.isle/sessions/unknown.json" ] \
  && ok "no session id: nothing written" || bad "no session id: nothing written" "$(ls "$H/.isle/blocked" "$H/.isle/sessions")"
out="$(printf '{"session_id":"s1","hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"rm -rf x"},"tool_use_id":"t16","reason":"[X]"}' | hook denied)"
[ -z "$out" ] && ok "prints nothing (no retry)" || bad "prints nothing" "$out"
cp "$SF" "$SCRATCH/records/plain.json"
# A record whose block doesn't read: the app must still read the record.
sed 's/^  "blocked": .*/  "blocked": {"tool": 7, "count": "x"},/' "$SF" > "$SCRATCH/records/bad-block.json"

echo
echo "isle-cli: $passes passed, $failures failed"
echo

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done \
  < <(find "$ROOT/Isle" -name '*.swift' ! -name 'IsleApp.swift' -print0)
cp "$ROOT/scripts/auto-mode-blocks-tests.swift" "$SCRATCH/main.swift"
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 \
  -module-name Isle -o "$SCRATCH/run" "${SOURCES[@]}" "$SCRATCH/main.swift" 2>&1 \
  | grep -E "error" || true
[ -x "$SCRATCH/run" ] || { echo "build failed"; exit 1; }
"$SCRATCH/run" "$SCRATCH/records" || failures=$((failures + 1))

[ "$failures" = 0 ]
