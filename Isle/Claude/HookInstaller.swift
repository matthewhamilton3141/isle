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
    ]

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
    # isle-cli — the bridge script Claude Code's hooks call. Writes a small
    # JSON status file that Isle watches with DispatchSource. Installed by
    # Isle's HookInstaller; kept in sync with integration/claude-code-hooks.
    #
    # Usage:
    #   isle-cli set-state <disconnected|idle|working|done>
    #   isle-cli notify                                       # classify a Notification

    set -euo pipefail

    STATUS_DIR="$HOME/.isle"
    STATUS_FILE="$STATUS_DIR/claude-status.json"

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
        STATE=""
        ;;
      fail)
        STATE="error"
        ;;
      *)
        echo "Usage: isle-cli <set-state <state> | notify | fail>" >&2
        exit 1
        ;;
    esac

    PROJECT="$(basename "$PWD")"
    TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Pull fields from the hook's stdin JSON without jq. Each `|| true` swallows a
    # no-match exit so set -e/pipefail can't abort before the file is written.
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

    if [ "$CMD" = "notify" ]; then
      # Keep an active question: don't let the follow-up notification downgrade
      # it to a plain approval. It clears when Claude moves on (next tool / Stop).
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

    # Surface AskUserQuestion as a question only while it's being *asked*
    # (PreToolUse). Its PostToolUse fires when the question is answered; letting
    # that convert too would re-raise the question and the notch would never
    # close. Absent hook_event_name we keep converting, so a lone PreToolUse
    # still opens.
    if [ "$CMD" = "set-state" ] && [ "$STATE" = "working" ] \
       && [ "$ACTION" = "AskUserQuestion" ] && [ "$HOOK_EVENT" != "PostToolUse" ]; then
      STATE="needs_question"
    fi

    mkdir -p "$STATUS_DIR"

    cat > "$STATUS_FILE" <<EOF
    {
      "state": "$STATE",
      "project": "$PROJECT",
      "session_id": "$SESSION_ID",
      "action": "$ACTION",
      "target": "$TARGET",
      "error_type": "$ERROR_TYPE",
      "updated_at": "$TIMESTAMP"
    }
    EOF
    """#
}
