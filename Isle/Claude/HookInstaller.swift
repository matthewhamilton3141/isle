//
//  HookInstaller.swift
//
//  Installs the Claude Code side of the bridge so the user doesn't have to
//  hand-edit ~/.claude/settings.json. It drops the `isle-cli` helper into
//  ~/.isle/bin and merges its hook events into the user's Claude Code
//  settings, referencing the helper by *absolute path* so it works regardless
//  of the user's PATH (Claude runs hooks in its own shell environment).
//
//  The merge is additive and reversible: existing hooks are preserved, and
//  uninstall removes only the entries that point at our helper.
//
//  This is the source of truth for the helper script. `integration/
//  claude-code-hooks/isle-cli` is a copy kept for manual installs — keep the
//  two in sync.
//

import Foundation

enum HookInstaller {
    enum InstallError: LocalizedError {
        case settingsUnreadable(String)
        var errorDescription: String? {
            switch self {
            case .settingsUnreadable(let detail):
                return "Couldn't read ~/.claude/settings.json: \(detail)"
            }
        }
    }

    /// One hook entry Isle owns: the event, the `isle-cli` arguments for it,
    /// and — for the two that block — a tool matcher and Claude Code's own
    /// `timeout` (seconds) for the command.
    private struct HookEntry {
        let event: String
        let args: String
        var matcher: String? = nil
        var timeout: Int? = nil
    }

    /// Hook event → the `isle-cli` arguments for it. `Notification` uses the
    /// `notify` subcommand, which classifies the message into question /
    /// waiting; the rest set a fixed state. An event may carry more than one
    /// entry (PreToolUse does).
    private static let hookEvents: [HookEntry] = [
        HookEntry(event: "UserPromptSubmit", args: "set-state working"),
        HookEntry(event: "PreToolUse", args: "set-state working"),
        // An AskUserQuestion, offered in the notch. Runs in parallel with the
        // generic entry above (which stands aside for this tool) and blocks
        // for up to 45s — the terminal shows only a spinner meanwhile, so the
        // wait is kept short. 60 puts Claude Code's cancel well after the
        // script's own deadline.
        HookEntry(event: "PreToolUse", args: "ask-question", matcher: "AskUserQuestion", timeout: 60),
        // Fires only when a tool call actually needs a permission decision (not
        // on auto-allowed tools). With Isle answering, `ask` blocks for a notch
        // Approve / Deny for up to 300s — which costs nothing, since Claude Code
        // shows its own dialog *while* the hook runs. 330 so Claude Code's
        // cancel lands after the script's deadline, never before it. Without
        // Isle answering it returns at once, as it always did.
        HookEntry(event: "PermissionRequest", args: "ask", timeout: 330),
        // PostToolUse clears an attention state the moment a tool completes —
        // above all, it's what closes the notch when an AskUserQuestion is
        // answered. The `AskUserQuestion → needs_question` conversion is gated
        // to PreToolUse so this can't re-raise it.
        HookEntry(event: "PostToolUse", args: "set-state working"),
        HookEntry(event: "Notification", args: "notify"),
        HookEntry(event: "Stop", args: "set-state done"),
        // Fires only when a turn ends on an API error (rate limit, overloaded,
        // server error, …); `Stop` never fires in that case. Surfaces the
        // failure in the notch instead of leaving it frozen on "working".
        HookEntry(event: "StopFailure", args: "fail"),
        // Fires before Claude compacts the conversation context; shows the
        // compacting marker in the island. A finished compaction clears it via
        // the SessionStart (source=compact) event below; a *cancelled* one fires
        // nothing, so the view model also eases it back to idle on a timeout.
        HookEntry(event: "PreCompact", args: "set-state compacting"),
        HookEntry(event: "SessionStart", args: "set-state idle"),
        // Fires when a session ends (exit, Ctrl-D, terminal closed). Clears the
        // island back to disconnected — otherwise a session closed mid-work
        // leaves the last state (e.g. "working") frozen on the notch, since no
        // Stop fires on an abrupt close. Guarded in `end` so one session ending
        // can't wipe another's live status (single shared status file).
        HookEntry(event: "SessionEnd", args: "end"),
    ]

    /// Bumped whenever the embedded script or the hook set changes, so an
    /// install from an older Isle refreshes itself on next launch instead of
    /// running a stale helper. See `refreshIfNeeded`. (v2: added the SessionEnd
    /// hook / `end` verb so a closed session clears the island. v3: emit
    /// `reset_at` for a usage limit so the island can count down to the reset.
    /// v4: dropped the Approve/Deny flow — `ask` and notifications surface a
    /// non-blocking question instead of an approval. v5: read the failure kind
    /// from StopFailure's `error` field — `error_type` is never sent, so every
    /// API failure used to arrive kind-less and no usage limit was ever
    /// recognised. v6: emit `tool_active` so the app can tell a tool that is
    /// genuinely running from a model that has gone quiet. v7: one status file
    /// per session under ~/.isle/sessions — the single shared file let any
    /// session's event overwrite every other session's state. v8: write the
    /// status file by rename instead of in place — Isle watches the directory,
    /// and an in-place rewrite changes no directory entry, so every state
    /// change after a session's first was invisible to the app. v9: answering
    /// from the notch — `ask` blocks for a notch decision, a second PreToolUse
    /// entry (matched to AskUserQuestion) runs `ask-question`, and both blocking
    /// entries carry their own `timeout`.)
    private static let currentVersion = 9
    private static let versionKey = "HookInstaller.installedVersion"

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }
    private static var scriptURL: URL {
        home.appendingPathComponent(".isle/bin/isle-cli")
    }
    private static var claudeSettingsURL: URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    /// True when the helper is present and referenced by at least one hook.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: scriptURL.path)
            && settingsReferenceIsleCLI()
    }

    // MARK: - Install

    static func install() throws {
        try writeScript()
        try mergeHooks()
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }

    /// Re-applies the hooks and helper when Isle is already installed but on an
    /// older version — e.g. an install predating the SessionEnd hook. The merge
    /// is idempotent (it replaces only its own entries) and the script is
    /// overwritten wholesale, so this refreshes Isle's side without touching the
    /// user's other hooks. No-op when not installed (the user opts in via
    /// Onboarding/Settings) or already current. Call once at launch.
    static func refreshIfNeeded() {
        guard isInstalled else { return }
        guard UserDefaults.standard.integer(forKey: versionKey) < currentVersion else { return }
        // Best effort: if the refresh fails, leave the working (older) hooks in
        // place — the user can still re-install from Settings.
        try? install()
    }

    private static func writeScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private static func mergeHooks() throws {
        var root = try readSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = scriptURL.path

        // Drop every prior Isle entry for each event first, so re-installing
        // over an older config (e.g. the old fixed `set-state needs_approval`
        // for Notification) replaces it rather than stacking a duplicate. Once
        // per event, up front: PreToolUse has two entries, and filtering again
        // before the second would throw away the first.
        for event in Set(hookEvents.map(\.event)) {
            hooks[event] = (hooks[event] as? [[String: Any]] ?? [])
                .filter { !refersToIsleCLI($0, command: command) }
        }

        for entry in hookEvents {
            var hook: [String: Any] = [
                "type": "command",
                "command": "\(command) \(entry.args)",
            ]
            if let timeout = entry.timeout { hook["timeout"] = timeout }
            var group: [String: Any] = ["hooks": [hook]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            var groups = hooks[entry.event] as? [[String: Any]] ?? []
            groups.append(group)
            hooks[entry.event] = groups
        }

        root["hooks"] = hooks
        try writeSettings(root)
    }

    // MARK: - Uninstall

    static func uninstall() throws {
        var root = try readSettings()
        if var hooks = root["hooks"] as? [String: Any] {
            let command = scriptURL.path
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let kept = groups.filter { !refersToIsleCLI($0, command: command) }
                if kept.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = kept
                }
            }
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }
            try writeSettings(root)
        }
        try? FileManager.default.removeItem(at: scriptURL)
    }

    // MARK: - Helpers

    /// Whether a matcher group contains a command pointing at our helper.
    private static func refersToIsleCLI(_ group: [String: Any], command: String) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String)?.hasPrefix(command) == true }
    }

    private static func settingsReferenceIsleCLI() -> Bool {
        guard let root = try? readSettings(),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let command = scriptURL.path
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains {
                refersToIsleCLI($0, command: command)
            } ?? false
        }
    }

    // MARK: - Settings file I/O

    private static func readSettings() throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: claudeSettingsURL.path) else { return [:] }
        let data = try Data(contentsOf: claudeSettingsURL)
        guard !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.settingsUnreadable("not a JSON object")
        }
        return obj
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: claudeSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: claudeSettingsURL, options: .atomic)
    }

    // MARK: - Embedded helper script

    // Dependency-free on purpose (no jq/python) so a missing tool can never be
    // the reason a hook fails. Writes the status file ClaudeStatusWatcher reads.
    private static let scriptBody = #"""
    #!/bin/bash
    #
    # isle-cli — the bridge script Claude Code's hooks call. Writes a small JSON
    # status file (~/.isle/claude-status.json) that Isle watches with DispatchSource.
    # Dependency-free (no jq/python) so a missing tool can never break a hook. Does
    # NOT require Isle.app to be running — it just writes a file (exit 0 either way).
    #
    # Usage:
    #   isle-cli set-state <disconnected|idle|working|done>   # state comes from the hook
    #   isle-cli notify                                        # classify a Notification
    #   isle-cli ask                                           # permission → block for the notch
    #   isle-cli ask-question                                  # AskUserQuestion → block for the notch
    #   isle-cli end                                           # session ended — clear the island
    #
    # Kept in sync with Isle's embedded HookInstaller.scriptBody.

    set -euo pipefail

    STATUS_DIR="$HOME/.isle"
    # One file per session. A single shared file meant any session's event
    # overwrote every other session's state — so a background session going
    # quiet (Stop, or the idle notification) would wipe the state of the
    # session you were actually watching. The app now reads the whole directory
    # and picks which session owns the island.
    SESSION_DIR="$STATUS_DIR/sessions"

    # The answering handshake (`ask` / `ask-question`). A blocked hook leaves its
    # raw stdin at requests/<id>.json for as long as it waits; Isle answers by
    # renaming the complete stdout payload into place at requests/<id>.response.json.
    # Isle owns run/answering, which holds its pid and exists only while it is
    # running with "Answer questions and approvals from the notch" on — no marker,
    # or a dead pid, and nothing blocks at all.
    REQUEST_DIR="$STATUS_DIR/requests"
    ANSWERING_MARKER="$STATUS_DIR/run/answering"

    # How long each blocking verb waits for the notch before falling through to
    # Claude's own prompt. An approval can wait long: Claude Code shows its
    # terminal dialog *while* the hook runs, so the block costs nothing. A question
    # can't: the terminal shows only a spinner until the hook returns. Both sit
    # inside the hook's own `timeout` in settings.json (330 / 60), so the script
    # always gives up before Claude Code has to kill it.
    ASK_APPROVAL_SECONDS=300
    ASK_QUESTION_SECONDS=45

    # Writes the status file Isle watches. $1 = state, $2 = request id (empty for
    # every write except a blocked `ask` / `ask-question`). Computes its own
    # timestamp so each write carries a fresh "… ago".
    write_status() {
      local ts sf tmp
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      mkdir -p "$SESSION_DIR"
      # Keyed by session id. Absent one (a hook payload without stdin), fall
      # back to a fixed name so the write still lands somewhere predictable
      # rather than creating an unbounded set of files.
      sf="$SESSION_DIR/${SESSION_ID:-unknown}.json"
      # Written to a temp file and renamed into place, never edited in place.
      # Isle watches the *directory*, and rewriting an existing file changes no
      # directory entry — so an in-place write fires no event and the app never
      # learns the state changed. A rename does. (It also makes the write atomic,
      # so Isle can never read a half-written record.) The temp name deliberately
      # does not end in .json, so a scan mid-write can't pick it up as a session.
      tmp="$sf.tmp.$$"
      cat > "$tmp" <<EOF
    {
      "state": "$1",
      "project": "$PROJECT",
      "session_id": "$SESSION_ID",
      "action": "$ACTION",
      "target": "$TARGET",
      "error_type": "$ERROR_TYPE",
      "tool_active": $TOOL_ACTIVE,
      "reset_at": "$RESET_AT",
      "request_id": "$2",
      "request_kind": "${3:-}",
      "updated_at": "$ts"
    }
    EOF
      mv -f "$tmp" "$sf"
    }

    # True when Isle is running and will answer from the notch: the marker exists
    # and the pid inside it is alive. A crash leaves the marker behind, and a dead
    # pid gates *off* — never on. Builtins only (`read`, `kill`), since `ask`
    # re-checks this on every tick of its wait.
    isle_answering() {
      local pid=""
      [ -f "$ANSWERING_MARKER" ] || return 1
      read -r pid < "$ANSWERING_MARKER" 2>/dev/null || true
      case "$pid" in
        ''|*[!0-9]*) return 1 ;;
      esac
      kill -0 "$pid" 2>/dev/null
    }

    CMD="${1:-}"
    case "$CMD" in
      set-state)
        STATE="${2:-}"
        if [ -z "$STATE" ]; then
          echo "Usage: isle-cli set-state <disconnected|idle|working|done>" >&2
          exit 1
        fi
        ;;
      notify)
        STATE=""   # decided from the notification message below
        ;;
      fail)
        STATE="error"   # the turn ended on an API error (StopFailure hook)
        ;;
      ask|ask-question)
        STATE=""   # handled entirely in the `ask` block below
        ;;
      end)
        STATE="disconnected"   # SessionEnd — clear the island (guarded below)
        ;;
      *)
        echo "Usage: isle-cli <set-state <state> | notify | fail | ask | ask-question | end>" >&2
        exit 1
        ;;
    esac

    PROJECT="$(basename "$PWD")"
    TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Pull fields out of the hook's stdin JSON without jq. Each `|| true` swallows a
    # no-match exit so set -e/pipefail can't abort before the file is written (a
    # matched value is already on stdout, so a real value is never clobbered).
    SESSION_ID=""
    ACTION=""
    TARGET=""
    MESSAGE=""
    HOOK_EVENT=""
    ERROR_TYPE=""
    LAST_MSG=""
    RESET_AT=""
    # True only between a PreToolUse and its PostToolUse — i.e. a tool is
    # actually executing right now. A long Bash or a slow MCP call goes minutes
    # with no hook write and no transcript growth, which is indistinguishable
    # from a stalled model unless the app knows a tool is running. Written as a
    # bare JSON boolean, so it is unquoted in the status file.
    TOOL_ACTIVE=false
    if [ ! -t 0 ]; then
      STDIN_JSON="$(cat)"
      HOOK_EVENT="$(printf '%s' "$STDIN_JSON" \
        | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
      if [ "$HOOK_EVENT" = "PreToolUse" ]; then TOOL_ACTIVE=true; fi
      ERROR_TYPE="$(printf '%s' "$STDIN_JSON" \
        | grep -oE '"error_type"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
      # StopFailure names the failure `error`, not `error_type` — one of
      # rate_limit / overloaded / server_error / invalid_request /
      # model_not_found / max_output_tokens / unknown. Without this fallback
      # every failure arrived kind-less and the island could only ever show the
      # generic error marker. Gated to `fail` so a tool payload that happens to
      # carry an "error" key can't stamp a kind onto a non-failure write.
      if [ -z "$ERROR_TYPE" ] && [ "$CMD" = "fail" ]; then
        ERROR_TYPE="$(printf '%s' "$STDIN_JSON" \
          | grep -oE '"error"[[:space:]]*:[[:space:]]*"[^"]*"' \
          | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
      fi
      SESSION_ID="$(printf '%s' "$STDIN_JSON" \
        | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
      ACTION="$(printf '%s' "$STDIN_JSON" \
        | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
      TARGET="$(printf '%s' "$STDIN_JSON" \
        | grep -oE '"(file_path|command|pattern|path|url)"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
      TARGET="$(printf '%s' "$TARGET" | tr -d '\\')"
      # Reduce a bare file path to its last component, so a long absolute path
      # still shows its filename instead of being clipped mid-name by the cap
      # below. URLs (host matters) and command lines (first token matters) are
      # left for the app to reduce, so they're skipped here.
      case "$TARGET" in
        *"://"*) : ;;
        *" "*)   : ;;
        */*)     TARGET="${TARGET##*/}" ;;
      esac
      TARGET="$(printf '%s' "$TARGET" | cut -c1-48)"
      MESSAGE="$(printf '%s' "$STDIN_JSON" \
        | grep -oE '"message"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
      # StopFailure carries no `message`: the text Claude actually showed
      # ("You've hit your weekly limit · resets …") rides in
      # `last_assistant_message`. The classification below reads both.
      LAST_MSG="$(printf '%s' "$STDIN_JSON" \
        | grep -oE '"last_assistant_message"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
    fi

    # `ask` (PermissionRequest hook) and `ask-question` (PreToolUse, matched to
    # AskUserQuestion): Claude is waiting on the user for this exact call. When
    # Isle is there to answer, leave the request where it can see it and block
    # until the notch decides, the prompt is answered somewhere else, or the
    # deadline passes. Every way out but an answer from the notch prints nothing,
    # and nothing is exactly what lets Claude fall back to its own prompt — so a
    # timeout, a quit, a crash or a missing marker can only ever mean "ask in the
    # terminal". Never allow on anyone's behalf.
    if [ "$CMD" = "ask" ] || [ "$CMD" = "ask-question" ]; then
      if [ "$CMD" = "ask" ]; then
        KIND="approval"; WAIT_STATE="needs_approval"; WAIT_SECONDS=$ASK_APPROVAL_SECONDS
      else
        KIND="question"; WAIT_STATE="needs_question"; WAIT_SECONDS=$ASK_QUESTION_SECONDS
      fi

      # Nobody to answer (Isle isn't running, or the toggle is off), or nothing to
      # hand over: behave exactly as before the handshake existed — surface a
      # question, print nothing, return at once.
      #
      # Also a PermissionRequest *for AskUserQuestion*. Claude Code raises one the
      # moment `ask-question` returns without an answer (its deadline, or "Answer
      # in terminal") — that is how the terminal's question UI comes up. It is the
      # same question, already handed to the terminal, and it is not a tool
      # approval: Approve / Deny would be the wrong buttons for it.
      if [ -z "${STDIN_JSON:-}" ] || ! isle_answering \
         || { [ "$CMD" = "ask" ] && [ "$ACTION" = "AskUserQuestion" ]; }; then
        write_status "needs_question" ""
        exit 0
      fi

      # Session-scoped, and unique per hook process. The trailing pid is the
      # hook's own, which Isle uses to tell a waiting hook from a SIGKILLed one.
      SAFE_SESSION="$(printf '%s' "${SESSION_ID:-}" | tr -cd 'A-Za-z0-9_-')"
      REQUEST_ID="${SAFE_SESSION:-unknown}-$(date +%s)-$$"
      REQUEST_FILE="$REQUEST_DIR/$REQUEST_ID.json"
      RESPONSE_FILE="$REQUEST_DIR/$REQUEST_ID.response.json"
      STATUS_FILE="$SESSION_DIR/${SESSION_ID:-unknown}.json"

      # The request lives exactly as long as this process. Whatever ends the wait
      # — an answer, the deadline, Claude Code's SIGTERM at the hook's timeout — it
      # goes, and with it Isle's buttons.
      trap 'rm -f "$REQUEST_FILE" "$RESPONSE_FILE" "$REQUEST_FILE.tmp.$$"' EXIT
      trap 'exit 0' TERM INT HUP

      # The raw stdin, verbatim: Isle reads the full tool_input (the exact command,
      # the questions) from it, not the status file's trimmed target. By rename,
      # like every other write here — and the temp name doesn't end in .json.
      mkdir -p "$REQUEST_DIR"
      printf '%s' "$STDIN_JSON" > "$REQUEST_FILE.tmp.$$"
      mv -f "$REQUEST_FILE.tmp.$$" "$REQUEST_FILE"
      write_status "$WAIT_STATE" "$REQUEST_ID" "$KIND"

      SECONDS=0
      while :; do
        if [ -f "$RESPONSE_FILE" ]; then
          RESPONSE="$(cat "$RESPONSE_FILE" 2>/dev/null || true)"
          case "$RESPONSE" in
            ''|'{}')
              # "Answer in terminal": no decision. Claude shows its own prompt the
              # moment this exits; drop the id so nothing offers buttons for it.
              write_status "$WAIT_STATE" ""
              ;;
            *)
              # Decided in the notch. Claude moves on either way — the tool runs,
              # or the model hears the denial and tries something else — so the
              # island stops asking now rather than at the next hook.
              case "$RESPONSE" in
                *'"behavior":"allow"'*|*'"permissionDecision":"allow"'*) TOOL_ACTIVE=true ;;
                *) TOOL_ACTIVE=false ;;
              esac
              write_status "working" ""
              printf '%s\n' "$RESPONSE"
              ;;
          esac
          exit 0
        fi

        # Another verb has written this session's status since — the tool ran
        # (PostToolUse), the turn ended, a new prompt arrived. That's how an answer
        # given in the terminal shows up: Claude Code doesn't stop a hook whose
        # prompt was answered elsewhere, and ignores what it prints afterwards. So
        # step aside without a word or a write; the status is already newer.
        if ! grep -qF "\"request_id\": \"$REQUEST_ID\"" "$STATUS_FILE" 2>/dev/null; then
          exit 0
        fi

        # Out of time, or Isle went away (quit, crash, toggle off): hand the prompt
        # back to Claude. The status keeps its state — the prompt is still up — but
        # loses the id, so no button outlives the wait.
        if [ "$SECONDS" -ge "$WAIT_SECONDS" ] || ! isle_answering; then
          write_status "$WAIT_STATE" ""
          exit 0
        fi

        sleep 0.2
      done
    fi

    # Classify a Notification from its message: an idle "waiting for your input"
    # nudge is calmer; everything else is a question (some attention is needed).
    if [ "$CMD" = "notify" ]; then
      # Keep an active question: a question (from the AskUserQuestion tool) is the
      # more specific signal, and the notification that follows it is just "waiting
      # on you" for the same prompt — don't let it downgrade.
      # The question clears on its own when Claude moves on (next tool use / Stop).
      # Likewise an approval that `ask` is blocked on: the permission_prompt
      # notification lands a few seconds into the wait, and rewriting the status
      # would drop the request id the hook is waiting under (which it reads as
      # "answered elsewhere" and gives up).
      sf="$SESSION_DIR/${SESSION_ID:-unknown}.json"
      if [ -f "$sf" ]; then
        if grep -q '"state": "needs_question"' "$sf" 2>/dev/null; then
          exit 0
        fi
        if grep -q '"state": "needs_approval"' "$sf" 2>/dev/null \
           && grep -qE '"request_id": "[^"]+"' "$sf" 2>/dev/null; then
          exit 0
        fi
      fi
      lower="$(printf '%s' "$MESSAGE" | tr '[:upper:]' '[:lower:]')"
      case "$lower" in
        *waiting*) STATE="waiting_input" ;;
        *)         STATE="needs_question" ;;
      esac
    fi

    # A PreToolUse for AskUserQuestion belongs to `ask-question`, which Claude Code
    # runs in parallel with this generic entry (it has its own matcher) and which
    # owns the request id. Writing here as well would race it, and a write landing
    # after its own would drop the id and end the wait it's in. So stand aside.
    if [ "$CMD" = "set-state" ] && [ "$ACTION" = "AskUserQuestion" ] \
       && [ "$HOOK_EVENT" = "PreToolUse" ]; then
      exit 0
    fi

    # A tool that asks the user a question surfaces as a question, not plain work —
    # but only while it's being *asked* (PreToolUse). The matching PostToolUse fires
    # when the question is answered; letting it convert too would re-raise the
    # question forever and the notch would never close. Absent hook_event_name we
    # keep the old behaviour (convert), so a lone PreToolUse still opens.
    if [ "$CMD" = "set-state" ] && [ "$STATE" = "working" ] \
       && [ "$ACTION" = "AskUserQuestion" ] && [ "$HOOK_EVENT" != "PostToolUse" ]; then
      STATE="needs_question"
    fi

    # The Claude usage/subscription limit is distinct from a transient API error:
    # it resets on a schedule rather than being worth an immediate retry. Detect it
    # from the error type or message (either the failure or a notification can carry
    # it) and surface it as a named failure the app labels "Usage limit reached".
    if [ "$CMD" = "fail" ] || [ "$CMD" = "notify" ]; then
      lc_all="$(printf '%s %s %s' "$ERROR_TYPE" "$MESSAGE" "$LAST_MSG" \
        | tr '[:upper:]' '[:lower:]')"
      # Claude sends `rate_limit` for both a transient 429 and the subscription
      # limit, so the wording is what separates them: the subscription limit
      # always reads "You've hit your <session|weekly|monthly spend> limit".
      case "$lc_all" in
        *usage*limit*|*limit*reached*|*quota*|*"hit your"*limit*)
          STATE="error"; ERROR_TYPE="usage_limit" ;;
      esac
    fi

    # When the failure is the usage/subscription limit, try to recover the moment
    # it resets so the island can count down to it. Claude's limit message carries
    # that moment as a Unix epoch (e.g. "...reached|1719849600"), so pull the first
    # 10–13 digit run out of the message. Absent one, RESET_AT stays empty and the
    # app just pins "Limit reached" with no timer.
    if [ "$ERROR_TYPE" = "usage_limit" ]; then
      RESET_AT="$(printf '%s %s' "$MESSAGE" "$LAST_MSG" \
        | grep -oE '[0-9]{10,13}' | head -1 || true)"
    fi

    # `end` (SessionEnd hook): drop this session's file and stop. With one file
    # per session there's nothing to guard against any more — removing your own
    # record can't affect anyone else's. (The old shared-file version had to
    # check whether it still owned the island before clearing it.)
    if [ "$CMD" = "end" ]; then
      rm -f "$SESSION_DIR/${SESSION_ID:-unknown}.json"
      exit 0
    fi

    write_status "$STATE" ""
    """#
}
