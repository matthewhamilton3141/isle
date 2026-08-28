//
//  HookInstaller.swift
//
//  Installs the Claude Code side of the bridge so the user doesn't have to
//  hand-edit ~/.claude/settings.json. It drops the `isle-cli` helper into
//  ~/.isle/bin and merges the five hook events into the user's Claude Code
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

    /// Hook event → the `isle-cli` arguments for it. `Notification` uses the
    /// `notify` subcommand, which classifies the message into approval /
    /// question / waiting; the rest set a fixed state.
    private static let hookEvents: [(event: String, args: String)] = [
        ("UserPromptSubmit", "set-state working"),
        ("PreToolUse", "set-state working"),
        // Fires only when a tool call actually needs a permission decision (not
        // on auto-allowed tools). `ask` opens the notch approval and blocks
        // until you click Approve/Deny — or times out and lets Claude fall back
        // to its own terminal prompt. This is the M7 "act from the notch" path.
        ("PermissionRequest", "ask"),
        // PostToolUse clears an attention state the moment a tool completes —
        // above all, it's what closes the notch when an AskUserQuestion is
        // answered. The `AskUserQuestion → needs_question` conversion is gated
        // to PreToolUse so this can't re-raise it.
        ("PostToolUse", "set-state working"),
        ("Notification", "notify"),
        ("Stop", "set-state done"),
        // Fires only when a turn ends on an API error (rate limit, overloaded,
        // server error, …); `Stop` never fires in that case. Surfaces the
        // failure in the notch instead of leaving it frozen on "working".
        ("StopFailure", "fail"),
        // Fires before Claude compacts the conversation context; shows the
        // compacting marker in the island. Cleared by the next event once
        // compaction finishes.
        ("PreCompact", "set-state compacting"),
        ("SessionStart", "set-state idle"),
        // Fires when a session ends (exit, Ctrl-D, terminal closed). Clears the
        // island back to disconnected — otherwise a session closed mid-work
        // leaves the last state (e.g. "working") frozen on the notch, since no
        // Stop fires on an abrupt close. Guarded in `end` so one session ending
        // can't wipe another's live status (single shared status file).
        ("SessionEnd", "end"),
    ]

    /// Bumped whenever the embedded script or the hook set changes, so an
    /// install from an older Isle refreshes itself on next launch instead of
    /// running a stale helper. See `refreshIfNeeded`. (v2: added the SessionEnd
    /// hook / `end` verb so a closed session clears the island.)
    private static let currentVersion = 2
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

        for (event, args) in hookEvents {
            // Drop any prior Isle entry for this event first, so re-installing
            // over an older config (e.g. the old fixed `set-state needs_approval`
            // for Notification) replaces it rather than stacking a duplicate.
            var groups = (hooks[event] as? [[String: Any]] ?? [])
                .filter { !refersToIsleCLI($0, command: command) }
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": "\(command) \(args)",
                ]]
            ])
            hooks[event] = groups
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
    #   isle-cli ask                                           # block for a notch Approve/Deny
    #   isle-cli end                                           # session ended — clear the island
    #
    # Kept in sync with Isle's embedded HookInstaller.scriptBody.

    set -euo pipefail

    STATUS_DIR="$HOME/.isle"
    STATUS_FILE="$STATUS_DIR/claude-status.json"

    # Timeout (in 0.1s ticks) the `ask` verb blocks for a notch decision before
    # giving up and letting Claude fall back to its own terminal prompt. 300 = 30s.
    ASK_TICKS=300

    # Writes the status file Isle watches. $1 = state, $2 = request id (empty for
    # every verb except `ask`). Computes its own timestamp so `ask`'s repeated
    # writes each carry a fresh "… ago".
    write_status() {
      local ts
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      mkdir -p "$STATUS_DIR"
      cat > "$STATUS_FILE" <<EOF
    {
      "state": "$1",
      "project": "$PROJECT",
      "session_id": "$SESSION_ID",
      "action": "$ACTION",
      "target": "$TARGET",
      "error_type": "$ERROR_TYPE",
      "request_id": "$2",
      "updated_at": "$ts"
    }
    EOF
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
      ask)
        STATE=""   # handled entirely in the `ask` block below
        ;;
      end)
        STATE="disconnected"   # SessionEnd — clear the island (guarded below)
        ;;
      *)
        echo "Usage: isle-cli <set-state <state> | notify | fail | ask | end>" >&2
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
    if [ ! -t 0 ]; then
      STDIN_JSON="$(cat)"
      HOOK_EVENT="$(printf '%s' "$STDIN_JSON" \
        | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
      ERROR_TYPE="$(printf '%s' "$STDIN_JSON" \
        | grep -oE '"error_type"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
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
    fi

    # `ask` (PermissionRequest hook): Claude needs a decision for this exact tool.
    # Open the notch approval, then block until the notch writes a matching decision
    # file or we time out — at which point we emit nothing so Claude falls back to
    # its own terminal prompt. PermissionRequest fires only when a decision is truly
    # needed, so this never blocks an auto-allowed tool.
    if [ "$CMD" = "ask" ]; then
      DECISION_FILE="$STATUS_DIR/claude-decision-$SESSION_ID.json"
      REQUEST_ID="$(date +%s)-$$-${RANDOM:-0}"
      mkdir -p "$STATUS_DIR"
      rm -f "$DECISION_FILE"                        # clear any stale decision
      write_status "needs_approval" "$REQUEST_ID"   # pop the notch prompt

      i=0
      while [ "$i" -lt "$ASK_TICKS" ]; do
        if [ -f "$DECISION_FILE" ]; then
          d_req="$(grep -oE '"request_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$DECISION_FILE" \
            | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
          d_dec="$(grep -oE '"decision"[[:space:]]*:[[:space:]]*"[^"]*"' "$DECISION_FILE" \
            | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
          # Only honour a decision minted for *this* request, so a stale click or
          # another session's file can never resolve this call.
          if [ "$d_req" = "$REQUEST_ID" ] && { [ "$d_dec" = "allow" ] || [ "$d_dec" = "deny" ]; }; then
            rm -f "$DECISION_FILE"
            write_status "working" ""   # clear the red glyph; the panel retracts
            if [ "$d_dec" = "allow" ]; then
              reason="Approved from the Isle notch"
            else
              reason="Denied from the Isle notch"
            fi
            printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"%s","permissionDecisionReason":"%s"}}\n' \
              "$d_dec" "$reason"
            exit 0
          fi
        fi
        sleep 0.1
        i=$((i + 1))
      done

      # Timed out (or Isle never answered). Drop the request id so the now-dead
      # buttons hide, and print nothing so Claude proceeds through its own prompt.
      # Never auto-allow.
      write_status "needs_approval" ""
      exit 0
    fi

    # Classify a Notification from its message: a permission prompt is an approval,
    # an idle "waiting for your input" nudge is calmer, everything else defaults to
    # approval (some attention is needed).
    if [ "$CMD" = "notify" ]; then
      # Keep an active question: a question (from the AskUserQuestion tool) is the
      # more specific signal, and the notification that follows it is just "waiting
      # on you" for the same prompt — don't let it downgrade to a plain approval.
      # The question clears on its own when Claude moves on (next tool use / Stop).
      if [ -f "$STATUS_FILE" ] && grep -q '"state": "needs_question"' "$STATUS_FILE" 2>/dev/null; then
        exit 0
      fi
      lower="$(printf '%s' "$MESSAGE" | tr '[:upper:]' '[:lower:]')"
      case "$lower" in
        *permission*|*approve*|*allow*) STATE="needs_approval" ;;
        *waiting*)                      STATE="waiting_input" ;;
        *)                              STATE="needs_approval" ;;
      esac
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
      lc_all="$(printf '%s %s' "$ERROR_TYPE" "$MESSAGE" | tr '[:upper:]' '[:lower:]')"
      case "$lc_all" in
        *usage*limit*|*limit*reached*|*quota*)
          STATE="error"; ERROR_TYPE="usage_limit" ;;
      esac
    fi

    # `end` (SessionEnd hook): only clear the island if the session that just
    # ended is the one the status file is currently showing. The status file is
    # shared by every session (last writer wins), so a background session closing
    # must not wipe a different session's live status. If the current file names
    # a *different* session, leave it untouched. A missing/unparseable file or a
    # matching id both fall through to the disconnected write below.
    if [ "$CMD" = "end" ] && [ -f "$STATUS_FILE" ] && [ -n "$SESSION_ID" ]; then
      CUR_SID="$(grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATUS_FILE" \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)"
      if [ -n "$CUR_SID" ] && [ "$CUR_SID" != "$SESSION_ID" ]; then
        exit 0   # a different session owns the island; leave it alone
      fi
    fi

    write_status "$STATE" ""
    """#
}
