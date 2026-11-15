#!/bin/zsh
# Builds scripts/constraint-pass-log-tests.swift against every Isle source
# (Debug) and checks ConstraintPassLog, the Debug log that names the window
# behind AppKit's "more Update Constraints in Window passes than there are
# views" exception, one case per run:
#   quiet  the log checks AppKit's counter, turns on, and a resize logs nothing
#   loop   a window asking for pass after pass is logged from pass 3, with
#          its context, events and the stack that asked
#   throw  asked forever, AppKit throws, and the log names the window first
#   off    a counter that doesn't read as expected turns the log off, quietly
#   notch  the real panel and glass window: on, and nothing logged for an
#          open, a close and a re-place
# The windows are transparent, click-through, at desktop level and never key.
set -e
ROOT=${0:A:h:h}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/isle-constraint-log.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
cp $ROOT/scripts/constraint-pass-log-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SRCS=("${(@f)$(find $ROOT/Isle -name '*.swift' ! -name 'IsleApp.swift')}")
xcrun swiftc -swift-version 5 -Onone -D DEBUG -parse-as-library -target arm64-apple-macos14.0 -module-name Isle -suppress-warnings \
  $SRCS $OUT/main.swift -o $OUT/run

pass=0; fail=0
check() {  # check <ok> <name> [detail]
  if [[ $1 == 1 ]]; then pass=$((pass+1)); print "  ok    $2"
  else fail=$((fail+1)); print "  FAIL  $2${3:+ — $3}"; fi
}
has() { grep -q -- "$2" "$1" && echo 1 || echo 0; }
lacks() { grep -q -- "$2" "$1" && echo 0 || echo 1; }

run_case() {  # run_case <case>: runs it, leaving $LOG and $STDOUT, and $CODE
  LOG=$OUT/$1.log; STDOUT=$OUT/$1.out
  set +e
  ISLE_CONSTRAINTS_LOG=$LOG $OUT/run $1 > $STDOUT 2>&1
  CODE=$?
  set -e
  [[ -f $LOG ]] || touch $LOG
}

print "quiet"
run_case quiet
check $(has $LOG "constraint pass log on") "the log checks AppKit's counter and turns on" "$(head -3 $LOG)"
check $(lacks $LOG "===") "a resize, at most two passes in its cycle, logs nothing"
check $([[ $CODE == 0 ]] && echo 1 || echo 0) "and exits cleanly" "exit $CODE"

print "loop"
run_case loop
check $(has $LOG "=== control window #[0-9]* asked for pass 3 in one display cycle (2 views; AppKit throws on the ask after pass 8)") "the ask for a third pass opens a record: window, view count, pass, where AppKit throws" "$(grep '===' $LOG | head -2)"
check $(has $LOG "window: ControlWindow #") "with the window's class and frame"
check $(has $LOG "showing: the control, re-asking") "what the window is showing"
check $(has $LOG "events, oldest first") "the recent events"
check $(has $LOG "ControlWindow.updateConstraintsIfNeeded") "and the stack that asked, demangled"
check $(has $LOG "+++ control window #[0-9]* asked for pass 4") "later passes in the same cycle get a line each"
check $(has $LOG "asked for pass 5") "up to the last one asked for"
check $(lacks $LOG "asked for pass 6") "and no further"
check $(lacks $LOG "THIS ASK THROWS") "none of them marked as the one that throws"
check $(has $STDOUT "survived: 0") "AppKit didn't throw" "$(cat $STDOUT)"

print "throw"
run_case throw
check $([[ $CODE == 3 ]] && echo 1 || echo 0) "asked forever, AppKit throws" "exit $CODE: $(tail -2 $STDOUT)"
check $(has $STDOUT "more Update Constraints in Window passes than there are views in the window") "the crash's own exception" "$(grep THROWN $STDOUT)"
last=$(grep -E '^[0-9-]+ [0-9:.]+ (===|\+\+\+)' $LOG | tail -1)
check $([[ $last == *"control window #"*"asked for pass 9  THIS ASK THROWS"* ]] && echo 1 || echo 0) "the log's last record, written before it, names the window and the ask that throws" "$last"
check $(has $LOG "=== control window") "with the full record at pass 3"

print "off"
run_case off
check $(has $LOG "constraint pass log off: AppKit's counter doesn't read as expected") "a counter that doesn't read right turns the log off, in one line" "$(cat $LOG | head -3)"
check $([[ $(grep -c . $LOG) == 2 ]] && echo 1 || echo 0) "and nothing more is written" "$(grep -c . $LOG) lines"
check $(has $STDOUT "survived: 0") "the app carries on as before" "$(cat $STDOUT)"

print "notch"
run_case notch
check $(has $LOG "constraint pass log on") "on, beside the real panel and glass window"
check $(lacks $LOG "===") "an open, a close and a re-place at another size log nothing" "$(grep '===' $LOG | head -3)"
check $(has $STDOUT "notch done") "and the run finishes" "$(tail -2 $STDOUT)"

# KEEP=<dir> keeps each case's log and output there.
[[ -n $KEEP ]] && cp $OUT/*.log $OUT/*.out $KEEP/
print "\n$pass passed, $fail failed"
[[ $fail == 0 ]]
