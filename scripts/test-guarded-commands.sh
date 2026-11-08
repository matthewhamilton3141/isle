#!/bin/bash
#
# Tests for `isle-cli guard` (guarded commands, Milestone 17): the hook's
# matcher, run the way Claude Code runs it — a PreToolUse payload on stdin —
# under a scratch HOME, so nothing touches ~/.isle or ~/.claude. Nothing in
# here is ever executed: every command is only ever text in a JSON payload.
#
# Usage: scripts/test-guarded-commands.sh [path/to/isle-cli]
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${1:-$ROOT/integration/claude-code-hooks/isle-cli}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/isle-guard-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/.isle"

passes=0
failures=0

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

# The hook's stdout for the command $1, as a PreToolUse on Bash.
run_guard() {
  printf '{"session_id":"test-session","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s","description":"test"},"tool_use_id":"toolu_test"}' \
    "$(json_string "$1")" | HOME="$SCRATCH" /bin/bash "$CLI" guard
}

# check <expected pattern, or "-" for no ask> <command> [name]
check() {
  local want="$1" cmd="$2" name="${3:-$2}" out got
  out="$(run_guard "$cmd")"
  if [ -z "$out" ]; then
    got="-"
  else
    got="$(printf '%s' "$out" | sed -nE 's/.*matches `(.*)`, which always asks.*/\1/p')"
    [ -n "$got" ] || got="?? $out"
  fi
  if [ "$got" = "$want" ]; then
    passes=$((passes + 1)); printf '  ok    %-6s %s\n' "$([ "$want" = - ] && echo pass || echo ask)" "$name"
  else
    failures=$((failures + 1)); printf '  FAIL  %s\n        want %s, got %s\n' "$name" "$want" "$got"
  fi
}

list() { printf '%s\n' "$@" > "$SCRATCH/.isle/guarded-commands"; }

echo "Off, and empty"
rm -f "$SCRATCH/.isle/guarded-commands"
check - "git push" "no list file: silent"
: > "$SCRATCH/.isle/guarded-commands"
check - "git push" "empty list file: silent"

list "git push" "rm -rf" "npm publish" "gh pr merge" "terraform apply"

echo "The plain command"
check "git push" "git push"
check "git push" "git push origin main"
check "git push" "git push --force-with-lease origin feature/x"
check "git push" "git push --dry-run" "git push --dry-run (matches: the guard is the word, not the flags)"
check "npm publish" "npm publish --access public"
check "gh pr merge" "gh pr merge 12 --squash"
check "terraform apply" "terraform apply -auto-approve"
check "rm -rf" "rm -rf build"

echo "Compound commands"
check "git push" "cd repo && git push"
check "git push" "git add . && git commit -m wip && git push"
check "git push" "make test; git push"
check "git push" "make test || git push"
check "git push" "git status | cat; git push"
check "git push" "(cd repo; git push)"
check "git push" "{ git push; }"
check "git push" "git push &"
check "git push" "nohup git push > push.log 2>&1 &"
check "git push" $'echo one\ngit push' "on the next line"
check "git push" $'bash -c \'echo one\ngit push\'' "a two-line script for bash -c"
check "git push" "bash -c \"bash -c 'git push'\"" "a shell in a shell"
check "git push" "echo \$(echo \$(git push))" "\$(…) in \$(…)"
check "git push" $'git \\\npush' "a line continuation"
check "git push" "if git push; then echo ok; fi"
check "git push" "for r in a b; do git push; done"
check "git push" "! git push"
check "git push" "echo \$(git push)" "inside \$(…)"
check "git push" "echo \"pushed: \$(git push 2>&1)\"" "inside \$(…) inside quotes"
check "git push" "echo \`git push\`" "inside backticks"
check "git push" "diff <(git push) x" "inside <(…)"

echo "Quoting"
check "git push" "git \"push\""
check "git push" "\"git\" push"
check "git push" "'git' 'push'"
check "git push" "g\"i\"t pu'sh'"
check "git push" "\\git push"
check "git push" "git pu\\sh"
check "git push" "git \$'push'"

check "git push" "printf 'a\\nb\\n' && git push" "after an escaped backslash and n"
check "git push" $'echo x\\\\\ngit push' "after a literal backslash at a line's end"
check "git push" "echo \"a\\\\\" && git push" "after a quoted backslash"

echo "JSON unescaping (the helper itself)"
# The script's functions, without running it: everything before the dispatch,
# with HOME at the scratch folder so even its paths point there.
real_home="$HOME"; HOME="$SCRATCH"
eval "$(sed -n '1,/^CMD="\${1:-}"$/p' "$CLI" | sed '$d' | sed 's/^set -euo pipefail$//')"
HOME="$real_home"
set +eu
unesc() { # unesc <name> <raw JSON string body> <want, as printf %q>
  guard_unescape "$2"
  if [ "$(printf '%q' "$GUARD_TEXT")" = "$3" ]; then
    passes=$((passes + 1)); echo "  ok    $1"
  else
    failures=$((failures + 1)); printf '  FAIL  %s\n        want %s, got %q\n' "$1" "$3" "$GUARD_TEXT"
  fi
}
unesc "plain" 'git push' 'git\ push'
unesc "\\n and \\t" 'a\nb\tc' "\$'a\\nb\\tc'"
unesc "an escaped quote" 'echo \"hi\"' "echo\\ \\\"hi\\\""
unesc "an escaped backslash, then n" 'a\\nb' 'a\\nb'
unesc "two escaped backslashes" 'a\\\\b' 'a\\\\b'
unesc "an escaped backslash at the end" 'a\\' 'a\\'
unesc "\\/ is /" 'a\/b' 'a/b'
unesc "\\u is a space" 'a\u001bb' 'a\ b'
unesc "an escape first" '\nx' "\$'\\nx'"
GUARD_LIST=/dev/null
long="$(printf 'line %d: remember to git push the "quoted" text here\\n' $(seq 1 1500))"
t0=$SECONDS; guard_unescape "$long"; guard_flatten "$GUARD_TEXT"
if [ $((SECONDS - t0)) -le 2 ] && [ "${#GUARD_TEXT}" -gt 70000 ]; then
  passes=$((passes + 1)); echo "  ok    unescape and flatten of ${#long} bytes in under 2s"
else
  failures=$((failures + 1)); echo "  FAIL  unescape and flatten of ${#long} bytes took $((SECONDS - t0))s"
fi

echo "Prefixes and paths"
check "git push" "FOO=1 git push"
check "git push" "GIT_SSH_COMMAND='ssh -v' git push"
check "git push" "env FOO=1 git push"
check "git push" "env -i PATH=/usr/bin git push"
check "git push" "/usr/bin/git push"
check "git push" "./bin/git push" "a git found by path is still git"
check "git push" "git -C ../other push"
check "git push" "git -c user.name=x push"
check "git push" "git --no-pager push"
check "git push" "command git push"
check "git push" "exec git push"
check "git push" "time git push"
check "git push" "sudo git push"
check "git push" "timeout 30 git push"
check "git push" "xargs git push < remotes"
check "rm -rf" "find . -name build -exec rm -rf {} +"

echo "Shells and eval"
check "git push" "bash -c \"git push\""
check "git push" "sh -c 'cd x && git push'"
check "git push" "bash -lc 'git push'"
check "git push" "zsh -c \"git push origin main\""
check "git push" "eval \"git push\""
check "git push" "eval git push"
check "git push" "sudo -u me bash -c 'git push'"
check "git push" $'bash <<EOF\ngit push\nEOF' "a heredoc fed to bash"
check "git push" $'sh -s <<-\'EOF\'\n\tgit push\n\tEOF' "a <<- heredoc fed to sh"

echo "Flags"
check "rm -rf" "rm -fr build"
check "rm -rf" "rm -r -f build"
check "rm -rf" "rm -rfv build"
check - "rm -r build" "rm -r (no -f)"
check - "rm -Rf build" "rm -Rf (exactly as written: -R is not -r)"
check - "rm -- -rf" "rm -- -rf (after --, a file name)"

echo "Not guarded"
check - "git pushd" "git pushd"
check - "pushd repo && git status" "pushd, then git status"
check - "git stash push -m wip" "git stash push"
check - "git log --grep push" "git log --grep push"
check - "git commit -m push" "git commit -m push"
check - "echo \"git push\"" "echo \"git push\""
check - "echo git push" "echo git push"
check - "echo 'git push && rm -rf /'" "everything quoted"
check - "printf '%s\\n' \"\$(echo 'git push')\"" "\$(…) that only echoes it"
check - "grep -r 'git push' docs" "grep for it"
check - "# git push" "a comment"
check - "echo hi # git push" "a trailing comment"
check - "npm run publish" "npm run publish"
check - "terraform plan" "terraform plan"
check - "gh pr view 12" "gh pr view"
check - "gitk push" "gitk"
check - $'cat > notes.md <<\'EOF\'\nThen git push it.\ngit push\nEOF' "a heredoc that's only data"
check "git push" $'cat > notes.md <<\'EOF\'\nDon\'t forget\nEOF\ngit push' "after a heredoc with a stray quote"

echo "What it can't see (documented, not caught)"
check - "gp" "an alias defined elsewhere"
check - "\$GIT push" "a variable in command position"
check - "\"\$(echo git)\" push" "a command name built at run time"
check - "./push.sh" "a script file"

echo "Past 16 KB: not read, asked if it mentions the pattern"
pad="$(printf 'line %d: some notes here\n' $(seq 1 900))"
out="$(run_guard "cat > notes.md <<'EOF'"$'\n'"$pad"$'\n'"Then git push it."$'\n'"EOF")"
case "$out" in
  *"too long to read, and it mentions \`git push\`"*) passes=$((passes + 1)); echo "  ok    a long heredoc that mentions git push asks, saying why" ;;
  *) failures=$((failures + 1)); echo "  FAIL  long heredoc mentioning git push: $out" ;;
esac
out="$(run_guard "cat > notes.md <<'EOF'"$'\n'"$pad"$'\n'"EOF")"
if [ -z "$out" ]; then passes=$((passes + 1)); echo "  ok    a long heredoc that doesn't mention it stays silent"
else failures=$((failures + 1)); echo "  FAIL  long heredoc without it: $out"; fi

echo "Lists"
list "git push --force"
check "git push --force" "git push --force origin main"
check "git push --force" "git push origin main --force"
check - "git push origin main" "git push without --force"
check - "git push --force-with-lease" "--force-with-lease is not --force"
list "  git   push  " "" "terraform apply"
check "git push" "git push" "spaces in the list are only separators"
check "terraform apply" "terraform -chdir=infra apply"
list "deploy.sh"
check "deploy.sh" "./scripts/deploy.sh --prod" "a script by name"

echo "The record for the notch"
list "git push"
run_guard "cd repo && git push \"origin\"" > /dev/null
rec="$SCRATCH/.isle/guarded/test-session.json"
want='{"pattern": "git push", "command": "cd repo && git push \"origin\""}'
if [ "$(cat "$rec" 2>/dev/null)" = "$want" ]; then
  passes=$((passes + 1)); echo "  ok    record holds the pattern and the command as Claude Code escaped it"
else
  failures=$((failures + 1)); echo "  FAIL  record: $(cat "$rec" 2>/dev/null)"
fi
printf '{"session_id":"test-session","hook_event_name":"SessionEnd"}' | HOME="$SCRATCH" /bin/bash "$CLI" end
if [ ! -e "$rec" ]; then
  passes=$((passes + 1)); echo "  ok    the session's end takes its record with it"
else
  failures=$((failures + 1)); echo "  FAIL  record still there after end"
fi
out="$(run_guard "git push")"
want='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Guarded in Isle: matches `git push`, which always asks."}}'
if [ "$out" = "$want" ]; then
  passes=$((passes + 1)); echo "  ok    the ask payload, exactly"
else
  failures=$((failures + 1)); echo "  FAIL  payload: $out"
fi

echo "Always… never saves a rule for a guarded command (\`ask\`)"
# Isle is "running": the marker names a live pid (this script's). The notch's
# answer is written the way Isle writes it, by rename, once the request is up.
mkdir -p "$SCRATCH/.isle/run"
echo "$$" > "$SCRATCH/.isle/run/answering"
ALWAYS='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push:*"}],"behavior":"allow","destination":"localSettings"}]}}}'
ONCE='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
DENY='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"no"}}}'

# ask_with <tool> <command> <the notch's answer>: the hook's stdout.
ask_with() {
  local tool="$1" cmd="$2" answer="$3" req id out k=0
  rm -rf "$SCRATCH/.isle/requests" "$SCRATCH/ask.out"
  printf '{"session_id":"test-ask","hook_event_name":"PermissionRequest","permission_mode":"default","tool_name":"%s","tool_input":{"command":"%s","description":"test"}}' \
    "$tool" "$(json_string "$cmd")" > "$SCRATCH/ask.in"
  HOME="$SCRATCH" /bin/bash "$CLI" ask < "$SCRATCH/ask.in" > "$SCRATCH/ask.out" &
  local pid=$!
  while [ "$k" -lt 100 ]; do
    for req in "$SCRATCH"/.isle/requests/*.json; do
      case "$req" in *.response.json|*'*'*) continue ;; esac
      id="$(basename "$req" .json)"
      printf '%s' "$answer" > "$SCRATCH/.isle/requests/.r.tmp"
      mv -f "$SCRATCH/.isle/requests/.r.tmp" "$SCRATCH/.isle/requests/$id.response.json"
      k=100; break
    done
    [ "$k" -ge 100 ] || { sleep 0.05; k=$((k + 1)); }
  done
  wait "$pid"
  cat "$SCRATCH/ask.out"
}

# expect_ask <name> <want stdout> <tool> <command> <answer>
expect_ask() {
  local name="$1" want="$2" got
  got="$(ask_with "$3" "$4" "$5")"
  if [ "$got" = "$want" ]; then
    passes=$((passes + 1)); echo "  ok    $name"
  else
    failures=$((failures + 1)); printf '  FAIL  %s\n        want %s\n        got  %s\n' "$name" "$want" "$got"
  fi
}

list "git push" "rm -rf"
expect_ask "Always on a guarded Bash command is allowed once, no rule" "$ONCE" Bash "cd repo && git push origin main" "$ALWAYS"
expect_ask "Always on a guarded Monitor command is allowed once, no rule" "$ONCE" Monitor "git push --dry-run" "$ALWAYS"
expect_ask "Always on a guarded command hidden in bash -c, the same" "$ONCE" Bash "bash -c 'git push'" "$ALWAYS"
expect_ask "Allow once on a guarded command passes as it is" "$ONCE" Bash "git push" "$ONCE"
expect_ask "Deny on a guarded command passes as it is" "$DENY" Bash "git push" "$DENY"
expect_ask "Always on a command that isn't guarded passes as it is" "$ALWAYS" Bash "git status" "$ALWAYS"
expect_ask "Always on another tool passes as it is" "$ALWAYS" Write "git push" "$ALWAYS"
rm -f "$SCRATCH/.isle/guarded-commands"
expect_ask "With the guard off, Always on git push passes as it is" "$ALWAYS" Bash "git push" "$ALWAYS"
rm -f "$SCRATCH/.isle/run/answering"

echo
echo "$passes passed, $failures failed"
[ "$failures" = 0 ]
