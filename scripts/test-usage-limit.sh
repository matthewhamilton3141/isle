#!/bin/bash
#
# Tests for isle-cli's usage limit and notification routing (Milestone 19):
# `fail` (StopFailure) recovering a limit's reset, window and what comes next
# from the hook, the transcript or the words, and `notify` routing every
# notification type. Run the way Claude Code runs the hooks — a payload on
# stdin — under a scratch HOME, so nothing touches ~/.isle or ~/.claude.
# ISLE_CLI_NOW stands in for the clock.
#
# Usage: scripts/test-usage-limit.sh [path/to/isle-cli]
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${1:-$ROOT/integration/claude-code-hooks/isle-cli}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/isle-limit-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
H="$SCRATCH/home"
mkdir -p "$H/.isle/sessions"
SF="$H/.isle/sessions/s1.json"
T="$SCRATCH/transcript.jsonl"

passes=0
failures=0

ok() { passes=$((passes + 1)); echo "  ok    $1"; }
bad() { failures=$((failures + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

field() { sed -nE "s/^  \"$1\": \"?([^\",]*)\"?,?$/\\1/p" "$SF"; }

# expect <name> <field=value>…: every field of the status file as given.
expect() {
  local name="$1" kv f want got all=""
  shift
  for kv in "$@"; do
    f="${kv%%=*}"; want="${kv#*=}"; got="$(field "$f")"
    [ "$got" = "$want" ] || all="$all $f: want '$want', got '$got';"
  done
  if [ -z "$all" ]; then ok "$name"; else bad "$name" "$all"; fi
}

hook() {  # hook <verb…> — stdin is the payload
  HOME="$H" /bin/bash "$CLI" "$@"
}

# The status file as a given hook leaves it.
state() {  # state <state> [extra json fields for the payload]
  case "$1" in
    working) printf '{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | hook set-state working ;;
    tool) printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"xcodebuild build"}}' | hook set-state working ;;
    done) printf '{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"All set."}' | hook set-state done ;;
  esac
}

notify() {  # notify <type or ""> <message>
  if [ -n "$1" ]; then
    printf '{"session_id":"s1","transcript_path":"%s","hook_event_name":"Notification","message":"%s","notification_type":"%s"}' "$T" "$2" "$1" | hook notify
  else
    printf '{"session_id":"s1","transcript_path":"%s","hook_event_name":"Notification","message":"%s"}' "$T" "$2" | hook notify
  fi
}

fail() {  # fail <now> <last_assistant_message> [error] [error_details]
  local details=""
  [ -n "${4:-}" ] && details=",\"error_details\":\"$4\""
  printf '{"session_id":"s1","transcript_path":"%s","hook_event_name":"StopFailure","error":"%s"%s,"last_assistant_message":"%s"}' \
    "$T" "${3:-rate_limit}" "$details" "$2" | ISLE_CLI_NOW="$1" hook fail
}

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.143Z; }
# Epoch for a wall time in a zone: zepoch <zone> "Y-m-d H:M"
zepoch() { TZ="$1" date -j -f '%Y-%m-%d %H:%M:%S' "$2:00" +%s; }

# Transcript records in the shape Claude Code 2.1.317 wrote them (trimmed).
t_error() {  # t_error <epoch> <resetsAt> <rateLimitType> [quotaLimits|rate_limit_info]
  local q="\"quotaLimits\":{\"status\":\"rejected\",\"resetsAt\":$2,\"unifiedRateLimitFallbackAvailable\":false,\"rateLimitType\":\"$3\",\"overageStatus\":\"rejected\",\"upgradePaths\":[\"upgrade_plan\",\"overage\"],\"isUsingOverage\":false},"
  [ "${4:-}" = rate_limit_info ] && q=""
  printf '{"parentUuid":"p","isSidechain":false,"type":"assistant","uuid":"u","timestamp":"%s","requestId":"req","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"You'"'"'ve hit your limit"}]},"apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"%s"}},%s"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"version":"2.1.317"}\n' \
    "$(iso "$1")" "$2" "$3" "$q"
}
t_info() {  # t_info <epoch> <text>
  printf '{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"informational","content":"%s","isMeta":false,"timestamp":"%s","uuid":"i","level":"notice"}\n' "$2" "$(iso "$1")"
}
t_turn() {  # t_turn <epoch>
  printf '{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":6017403,"messageCount":649,"timestamp":"%s","uuid":"t","isMeta":false}\n' "$(iso "$1")"
}
t_user() {
  printf '{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"keep going"},"timestamp":"%s","uuid":"x"}\n' "$(iso "$1")"
}

FIVE="You've hit your 5-hour limit · resets 3:50am (America/Toronto)"
WEEK="You've hit your weekly limit · resets Nov 9 at 8pm (America/Toronto)"
# The real hits in Matthew's transcripts: a 5-hour limit at 05:31:38Z on
# 2026-11-05 (resetsAt 1793868600), and a weekly one at 00:13:01Z on
# 2026-11-07 (resetsAt 1794272400).
HIT5=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' 2026-11-05T05:31:38 +%s)
HITW=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' 2026-11-07T00:13:01 +%s)

echo "StopFailure: from the transcript"
: > "$T"
t_user $((HIT5 - 60)) >> "$T"
t_error "$HIT5" 1793868600 five_hour >> "$T"
t_info "$HIT5" "Usage limit reached · continuing automatically at 3:50am · esc to cancel" >> "$T"
t_turn "$HIT5" >> "$T"
state working
fail $((HIT5 + 1)) "$FIVE"
expect "5-hour limit, continuing automatically" state=error error_type=usage_limit reset_at=1793868600 limit_kind=five_hour limit_next=auto

: > "$T"
t_info "$HIT5" "Usage limit reached again · continuing automatically at 3:50am · esc to cancel" >> "$T"
t_error $((HIT5 + 0)) 1793868600 five_hour >> "$T"
t_turn "$HIT5" >> "$T"
state working
fail $((HIT5 + 1)) "$FIVE"
expect "the 'again' record, written just before the failed turn's" reset_at=1793868600 limit_next=auto

: > "$T"
t_error "$HITW" 1794272400 seven_day >> "$T"
t_turn "$HITW" >> "$T"
state working
start=$(date +%s)
fail $((HITW + 1)) "$WEEK"
took=$(( $(date +%s) - start ))
expect "weekly limit, no wait started (reset days out)" state=error error_type=usage_limit reset_at=1794272400 limit_kind=seven_day limit_next=
if [ "$took" -le 1 ]; then ok "a reset more than a day out settles at once (${took}s)"; else bad "a reset more than a day out settles at once" "took ${took}s"; fi

: > "$T"
t_error "$HIT5" 1793868600 five_hour >> "$T"
t_turn "$HIT5" >> "$T"
state working
start=$(date +%s)
fail $((HIT5 + 1)) "$FIVE"
took=$(( $(date +%s) - start ))
expect "5-hour limit with no wait record: no 'continues automatically'" reset_at=1793868600 limit_kind=five_hour limit_next=
if [ "$took" -le 1 ]; then ok "a closed turn settles at once (${took}s)"; else bad "a closed turn settles at once" "took ${took}s"; fi

: > "$T"
t_error "$HIT5" 1793868600 five_hour rate_limit_info >> "$T"
t_turn "$HIT5" >> "$T"
state working
fail $((HIT5 + 1)) "$FIVE"
expect "no quotaLimits: apiErrorParams.rate_limit_info instead" reset_at=1793868600 limit_kind=five_hour

: > "$T"
t_error $((HIT5 - 3 * 3600)) 1793857800 five_hour >> "$T"
t_info $((HIT5 - 3 * 3600)) "Usage limit reached · continuing automatically at 12:50am · esc to cancel" >> "$T"
t_turn $((HIT5 - 3 * 3600)) >> "$T"
state working
fail $((HIT5 + 1)) "$FIVE"
expect "an earlier hit's record is not this one: the words instead" reset_at=1793868600 limit_kind=five_hour limit_next=

: > "$T"
t_info $((HIT5 - 3600)) "Usage limit reached · continuing automatically at 3:50am · esc to cancel" >> "$T"
t_user $((HIT5 - 30)) >> "$T"
t_error "$HIT5" 1793868600 five_hour >> "$T"
t_turn "$HIT5" >> "$T"
state working
fail $((HIT5 + 1)) "$FIVE"
expect "an earlier wait's record doesn't say this one continues" reset_at=1793868600 limit_next=

: > "$T"
state working
( sleep 0.4; t_error "$HIT5" 1793868600 five_hour >> "$T"; t_info "$HIT5" "Usage limit reached · continuing automatically at 3:50am · esc to cancel" >> "$T" ) &
fail $((HIT5 + 1)) "$FIVE"
wait
expect "records landing after the hook starts are still found" reset_at=1793868600 limit_kind=five_hour limit_next=auto

: > "$T"
t_error "$HIT5" 1793868600 five_hour >> "$T"
state working
( sleep 0.5; printf '{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"try again"}' | hook set-state working ) &
fail $((HIT5 + 1)) "$FIVE"
wait
expect "a newer hook's write while the transcript settles wins" state=working error_type= reset_at=

echo "StopFailure: a reset in the hook's own fields"
: > "$T"
state working
fail $((HIT5 + 1)) "$FIVE" rate_limit "limit resets at 1793868600"
expect "an epoch in error_details is taken first" reset_at=1793868600 limit_kind=five_hour
state working
fail $((HIT5 + 1)) "Claude AI usage limit reached|1793868600000"
expect "the old message's epoch (ms)" state=error error_type=usage_limit reset_at=1793868600 limit_kind=

echo "StopFailure: from the words"
rm -f "$T"
state working
fail $((HIT5 + 1)) "$FIVE"
expect "no transcript: 'resets 3:50am (America/Toronto)'" state=error error_type=usage_limit reset_at=1793868600 limit_kind=five_hour limit_next=
state working
fail $((HITW + 1)) "$WEEK"
expect "'resets Nov 9 at 8pm (America/Toronto)'" reset_at=1794272400 limit_kind=seven_day

now=$(zepoch America/Toronto "2026-11-06 15:00")
state working
fail "$now" "You've hit your 5-hour limit · resets 6:50pm (America/Toronto)"
expect "6:50pm, later today" reset_at="$(zepoch America/Toronto "2026-11-06 18:50")"
now=$(zepoch America/Toronto "2026-11-06 23:30")
state working
fail "$now" "You've hit your 5-hour limit · resets 1:20am (America/Toronto)"
expect "across midnight: 1:20am is tomorrow" reset_at="$(zepoch America/Toronto "2026-11-07 01:20")"
now=$(zepoch America/Toronto "2026-11-07 00:10")
state working
fail "$now" "You've hit your 5-hour limit · resets 4am (America/Toronto)"
expect "just past midnight: 4am is today" reset_at="$(zepoch America/Toronto "2026-11-07 04:00")"
now=$(zepoch America/Toronto "2026-12-31 22:00")
state working
fail "$now" "You've hit your 5-hour limit · resets 2:15am (America/Toronto)"
expect "across New Year" reset_at="$(zepoch America/Toronto "2027-01-01 02:15")"
now=$(zepoch America/Toronto "2026-11-06 18:52")
state working
fail "$now" "You've hit your 5-hour limit · resets 6:50pm (America/Toronto)"
expect "two minutes past is now, not tomorrow" reset_at="$(zepoch America/Toronto "2026-11-06 18:50")"
now=$(zepoch America/Toronto "2026-11-06 11:00")
state working
fail "$now" "You've hit your 5-hour limit · resets 12pm (America/Toronto)"
expect "12pm is noon" reset_at="$(zepoch America/Toronto "2026-11-06 12:00")"
now=$(zepoch America/Toronto "2026-11-06 22:00")
state working
fail "$now" "You've hit your 5-hour limit · resets 12:30am (America/Toronto)"
expect "12:30am is just after midnight" reset_at="$(zepoch America/Toronto "2026-11-07 00:30")"
now=$(zepoch Asia/Tokyo "2026-11-06 20:00")
state working
fail "$now" "You've hit your 5-hour limit · resets 11pm (Asia/Tokyo)"
expect "the zone named, not this Mac's" reset_at="$(zepoch Asia/Tokyo "2026-11-06 23:00")"
now=$(zepoch America/Toronto "2026-03-07 23:00")
state working
fail "$now" "You've hit your 5-hour limit · resets 3:30am (America/Toronto)"
expect "across the spring-forward night" reset_at="$(zepoch America/Toronto "2026-03-08 03:30")"
now=$(zepoch America/Toronto "2026-12-29 10:00")
state working
fail "$now" "You've hit your weekly limit · resets Jan 2, 2027 at 9:30am (America/Toronto)"
expect "a date with its year" reset_at="$(zepoch America/Toronto "2027-01-02 09:30")" limit_kind=seven_day
now=$(zepoch America/Toronto "2026-11-06 10:00")
state working
fail "$now" "You've hit your weekly limit · resets Nov 9, 8pm (America/Toronto)"
expect "the older 'Nov 9, 8pm'" reset_at=1794272400
state working
fail "$now" "You've hit your Opus limit · resets Nov 10 at 9am (America/Toronto)"
expect "the Opus window" limit_kind=seven_day_opus reset_at="$(zepoch America/Toronto "2026-11-10 09:00")"
state working
fail "$now" "You've hit your session limit · resets 1pm (America/Toronto)"
expect "the 5-hour window's old name" limit_kind=five_hour
state working
fail "$now" "You've hit your 5-hour limit · resets 6:50pm (Mars/Olympus_Mons)"
expect "a zone that doesn't exist: no reset, never a guess" state=error error_type=usage_limit reset_at= limit_kind=five_hour
state working
fail "$now" "You've hit your 5-hour limit"
expect "no reset in the words: none" error_type=usage_limit reset_at= limit_kind=five_hour
state working
fail "$now" "You've hit your 5-hour limit · resets 25:70pm (America/Toronto)"
expect "a time that isn't one: none" reset_at=
state working
fail "$now" "API Error: Rate limit reached"
expect "a transient 429 is an error, not a limit" state=error error_type=rate_limit reset_at= limit_kind=
state working
fail "$now" "API Error: Repeated 529 Overloaded errors" overloaded
expect "an overload is untouched" state=error error_type=overloaded reset_at=

echo "Notification: routed by type"
notify_case() {  # notify_case <start state> <type> <message> <want state> [name]
  state "$1"
  notify "$2" "$3"
  expect "${5:-$1 + $2 → $4}" state="$4"
}
notify_case working permission_prompt "Claude needs your permission" needs_question
notify_case working elicitation_dialog "MCP server needs input" needs_question
notify_case working elicitation_url_dialog "MCP server wants you to open a URL" needs_question
notify_case done idle_prompt "Claude is waiting for your input" waiting_input
state done
notify idle_prompt "Claude is waiting for your input"
expect "the idle nudge keeps what Claude said" state=waiting_input last_message="All set."

for t in auth_success auth_storage_failure elicitation_complete elicitation_response agent_needs_input \
         agent_completed plugin_notification worker_permission_prompt push_notification \
         computer_use_enter computer_use_exit model_refusal_fallback some_type_from_the_future; do
  for s in working done tool; do
    state "$s"
    before="$(cat "$SF")"
    notify "$t" "Authentication successful"
    if [ "$(cat "$SF")" = "$before" ]; then ok "$s + $t leaves the state alone"
    else bad "$s + $t leaves the state alone" "now: $(field state)"; fi
  done
done

echo "Notification: from a Claude Code with no type"
notify_case working "" "Claude needs your permission" needs_question "no type, a permission message → question"
notify_case done "" "Claude is waiting for your input" waiting_input "no type, the waiting message → waiting"
state working
notify "" "Claude usage limit reached. Your limit will reset at 5pm"
expect "no type, a limit message → the limit" state=error error_type=usage_limit

echo "Notification: what came of the limit's wait"
: > "$T"
t_error "$HIT5" 1793868600 five_hour >> "$T"
t_info "$HIT5" "Usage limit reached · continuing automatically at 3:50am · esc to cancel" >> "$T"
t_turn "$HIT5" >> "$T"
limit() { state working; fail $((HIT5 + 1)) "$FIVE"; }

limit
notify quota_auto_resume_fired "Usage limit reset — Claude is continuing your task"
expect "fired: back to working, resumed, the window kept" state=working error_type= limit_next=resumed limit_kind=five_hour reset_at=
printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}' | hook set-state working
expect "the resumed turn's tool calls keep 'resumed'" state=working target=git limit_next=resumed limit_kind=five_hour
printf '{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"Done."}' | hook set-state done
expect "its Stop drops it" state=done limit_next= limit_kind=

limit
printf '{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"Your claude.ai usage limit has reset. Continue the task you were working on when the limit was reached; do not repeat work that is already complete."}' | hook set-state working
expect "the continuation prompt, before the notification: resumed" state=working limit_next=resumed limit_kind=five_hour
notify quota_auto_resume_fired "Usage limit reset — Claude is continuing your task"
expect "…and the notification after it agrees" state=working limit_next=resumed limit_kind=five_hour
limit
printf '{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"Your claude.ai usage is available again before the usage-limit reset. Continue the task you were working on when the limit was reached."}' | hook set-state working
expect "the early continuation prompt: resumed" limit_next=resumed
state working
expect "your own prompt is a turn of your own" state=working limit_next=

state tool
before="$(cat "$SF")"
notify quota_auto_resume_fired "Usage limit reset — Claude is continuing your task"
if [ "$(cat "$SF")" = "$before" ]; then ok "fired over a running tool leaves it"; else bad "fired over a running tool leaves it" "$(field state)"; fi

limit
notify quota_auto_resume_stale "Usage limit reset — press enter to continue"
expect "stale: the limit, waiting for Enter, window and reset kept" state=error error_type=usage_limit limit_next=enter limit_kind=five_hour reset_at=1793868600
printf '{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"Your claude.ai usage limit has reset. Continue the task you were working on when the limit was reached; do not repeat work that is already complete."}' | hook set-state working
expect "Enter pressed: the continuation is resumed" state=working limit_next=resumed limit_kind=five_hour

limit
notify quota_auto_resume_disabled "Automatic continue was turned off — the task will not resume on its own"
expect "disabled: the limit, won't continue" state=error error_type=usage_limit limit_next=stopped limit_kind=five_hour reset_at=1793868600

state working
notify quota_auto_resume_stale "Usage limit reset — press enter to continue"
expect "stale with no limit on record: Enter, nothing invented" state=error error_type=usage_limit limit_next=enter limit_kind= reset_at=
state done
notify quota_auto_resume_disabled "Automatic continue stopped after repeated usage-limit hits — the task will not resume on its own"
expect "disabled with no limit on record: nothing invented" state=error limit_next=stopped limit_kind= reset_at=

echo "Notification: nothing rewrites a request being answered"
# A request whose hook is still waiting: its file is there, and the pid that
# ends its id (this script's) is alive.
mkdir -p "$H/.isle/requests"
printf '{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
  > "$H/.isle/requests/s1-1-$$.json"
for t in permission_prompt idle_prompt quota_auto_resume_fired quota_auto_resume_stale auth_success; do
  cat > "$SF" <<EOF
{
  "state": "needs_approval",
  "project": "isle",
  "session_id": "s1",
  "request_id": "s1-1-$$",
  "updated_at": "2026-11-07T00:00:00Z"
}
EOF
  before="$(cat "$SF")"
  notify "$t" "Claude needs your permission"
  if [ "$(cat "$SF")" = "$before" ]; then ok "a blocked approval survives $t"; else bad "a blocked approval survives $t" "$(field state)"; fi
done
rm -f "$H/.isle/requests/s1-1-$$.json"
notify permission_prompt "Claude needs your permission"
expect "a request whose hook is gone holds nothing: the notification lands" state=needs_question
state working
printf '{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{}}' | hook ask
for t in permission_prompt idle_prompt elicitation_dialog; do
  notify "$t" "Claude is waiting for your input"
  expect "a question stays a question on $t" state=needs_question
done

echo
echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
