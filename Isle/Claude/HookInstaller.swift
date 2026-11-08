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
        // Guarded commands (Milestone 17): a Bash or Monitor command on the
        // user's list gets `permissionDecision: "ask"`, which made Claude Code
        // 2.1.319 prompt in all six permission modes, bypass included, and
        // past an allow rule. Without the list file it exits before reading
        // stdin.
        HookEntry(event: "PreToolUse", args: "guard", matcher: "Bash|Monitor", timeout: 10),
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
    /// entries carry their own `timeout`. v10: a Stop writes `last_message`,
    /// the start of Claude's final message as Claude Code escaped it, for the
    /// Done face, and the idle "waiting for your input" nudge keeps it; and
    /// the project name is escaped, so a quote in a folder name can no longer
    /// make the whole record unreadable. v11: guarded commands — a third
    /// PreToolUse entry, matched to Bash and Monitor, runs `guard`, which asks
    /// for a command on the user's list and leaves the notch the reason; and
    /// `ask` drops `updatedPermissions` from an answer for a guarded command,
    /// so "Always…" can never save a rule that covers one.)
    private static let currentVersion = 11
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
        // per event, up front: PreToolUse has three entries, and filtering again
        // before the second would throw away the ones before it.
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
    #   isle-cli guard                                         # Bash → ask when it's a guarded command
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

    # Guarded commands (`guard`): the user's own short list of commands that always
    # ask — in auto mode, under acceptEdits, past an allow rule, with permissions
    # bypassed. Isle writes it, one pattern a line, by rename, and removes it when
    # the feature is off or the list is empty; so with nothing to guard, `guard`
    # is one test and an exit, and no session is slowed down.
    GUARD_LIST="$STATUS_DIR/guarded-commands"
    # The last guarded call of each session: the pattern it matched, and its
    # command as Claude Code escaped it. The PermissionRequest that follows carries
    # neither the reason nor the tool_use_id, so this is how the notch knows the
    # approval in front of it is a guarded one, and why.
    GUARD_DIR="$STATUS_DIR/guarded"

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
      "last_message": "$LAST_EXCERPT",
      "updated_at": "$ts"
    }
    EOF
      mv -f "$tmp" "$sf"
    }

    # A value made safe to sit between double quotes in the status file. Only
    # for text this script owns outright (the project's directory name): it can
    # hold anything a filename can, and one quote would make the whole record
    # unreadable. Backslash first, so the escapes added after it stay single.
    # Pure bash, then `tr` for the control characters JSON has no short form for.
    json_escape() {
      local s="$1"
      s="${s//\\/\\\\}"
      s="${s//\"/\\\"}"
      s="${s//$'\n'/\\n}"
      s="${s//$'\r'/\\r}"
      s="${s//$'\t'/\\t}"
      printf '%s' "$s" | LC_ALL=C tr -d '\000-\037'
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

    # ---- Guarded commands -------------------------------------------------------
    #
    # A speed bump for honest mistakes, not a sandbox. The command is read the way
    # a shell splits it: into words, with the quotes taken off, and into simple
    # commands at `;` `&&` `||` `|` `&`, newlines and parentheses — so
    # `cd x && git push` and `git "push"` are both caught, and `echo "git push"`
    # isn't. `$(…)` and backticks are commands of their own; a script handed to
    # `bash -c` / `sh -c` / `eval`, or a heredoc fed to a shell, is read as one
    # too; `env FOO=1`, `sudo`, `xargs`, `nohup`, `timeout` and the like are seen
    # through. What it can't see it doesn't pretend to: a variable or an alias in
    # command position, a script file, a string built at run time.
    #
    # A pattern is words: the program (by name, so /usr/bin/git is git), then the
    # subcommand words in order, then flags anywhere. Between the program and its
    # subcommand an option's value may stand (`git -C dir push`). A short-flag
    # cluster matches letters in any grouping (`rm -rf` is `rm -fr`, `rm -r -f`),
    # exactly as written: `-R` is not `-r`. Everything else is exact.
    #
    # Builtins only, and bash 3.2: a guarded hook runs on every Bash call.

    GUARD_US=$'\037'          # between the words of a simple command
    GUARD_RS=$'\036'          # between pending heredocs
    GUARD_UNKNOWN=$'\034'     # stands in for a $(…) or ${…}: never equal to a word
    GUARD_NL=$'\n'
    GUARD_TAB=$'\t'
    # Longer than this (in characters, once unescaped), a command isn't read
    # word by word: reading 16 KB takes about a second, and the hook has ten.
    GUARD_PARSE_MAX=16384
    # A run of characters with no meaning to the shell, outside and inside "…".
    GUARD_RE_PLAIN="^[^ $GUARD_TAB;&|()<>\`'\"\\\$#]+"
    GUARD_RE_DQ="^[^\"\\\$\`]+"
    GUARD_RE_ASSIGN='^[A-Za-z_][A-Za-z0-9_]*\+?='
    GUARD_RE_COMMAND='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
    GUARD_RE_SESSION='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'

    # $1 with its JSON escapes undone, into GUARD_TEXT. A `\u` escape is a control
    # character or half a surrogate pair (Claude Code writes everything else raw):
    # a space, which can't join two words into one that matters.
    #
    # Split at the backslashes in one go, so the cost grows with the length: a
    # loop of ${rest#*\\} rescans the rest for every escape, and a big heredoc
    # has thousands. Each piece after the first starts with the escaped
    # character; an empty piece is an escaped backslash, which also takes the
    # next piece whole. The trailing Z keeps a final empty piece from being lost.
    guard_unescape() {
      local p i=1 n k=1
      local -a parts out
      local IFS='\'
      set -f
      parts=($1Z)
      set +f
      n=${#parts[@]}
      # Pieces go into an array and are joined once: appending to one growing
      # string copies it every time.
      out[0]="${parts[0]}"
      while [ "$i" -lt "$n" ]; do
        p="${parts[i]}"; i=$((i + 1))
        if [ -z "$p" ]; then
          out[k]="\\"; k=$((k + 1))
          [ "$i" -lt "$n" ] && { out[k]="${parts[i]}"; k=$((k + 1)); i=$((i + 1)); }
          continue
        fi
        case "${p:0:1}" in
          n) out[k]="$GUARD_NL${p:1}" ;;
          t) out[k]="$GUARD_TAB${p:1}" ;;
          r|b|f) out[k]=" ${p:1}" ;;
          u) out[k]=" ${p:5}" ;;
          *) out[k]="$p" ;;
        esac
        k=$((k + 1))
      done
      IFS=""
      GUARD_TEXT="${out[*]}"
      GUARD_TEXT="${GUARD_TEXT%Z}"
    }

    # The text with every quote, backslash and newline taken out, into
    # GUARD_FLAT: each word of a command is still in it whole, however it was
    # quoted or continued, so a pattern with a word missing from it can't match.
    # By splitting, like the unescape: ${x//[\"\'\\]/} takes seconds on 10 KB.
    guard_flatten() {
      local -a parts
      local IFS=$'"\'\\\n'
      set -f
      parts=($1)
      set +f
      IFS=""
      GUARD_FLAT="${parts[*]}"
    }

    # The splitter's helpers share its locals (bash scopes dynamically).
    #
    # Ends the word being read: onto the command, or — straight after a
    # redirection — dropped as its target, or kept as a heredoc's delimiter.
    guard_word() {
      local r w e=0
      [ "$inword" = 1 ] || return 0
      if [ "$drop" = 2 ]; then
        # A heredoc is read as commands only when a shell is what reads it.
        r="$cur"
        while [ -n "$r" ]; do
          w="${r%%$GUARD_US*}"; r="${r#*$GUARD_US}"
          case "${w##*/}" in bash|sh|zsh|dash|ksh|fish|eval|source|.) e=1 ;; esac
        done
        hd="$hd$word$GUARD_US$strip$GUARD_US$e$GUARD_RS"
      elif [ "$drop" = 0 ]; then
        cur="$cur$word$GUARD_US"
      fi
      drop=0; word=""; inword=0
    }

    # Ends the simple command being read.
    guard_end() {
      guard_word
      if [ -n "$cur" ]; then GUARD_CMDS+=("$cur"); cur=""; fi
    }

    # Opens `$(`, a backtick, `<(` or a subshell: what's inside is commands of its
    # own, and the word around a substitution goes on after it as an unknown.
    # $1 = p (parentheses) or b (backtick); $2 = 1 inside a word.
    guard_open() {
      if [ "$2" = 1 ]; then
        word="$word$GUARD_UNKNOWN"; inword=1
      else
        guard_end
      fi
      scur[sp]="$cur"; sword[sp]="$word"; sinw[sp]="$inword"; sdrop[sp]="$drop"; sp=$((sp + 1))
      ctx="$ctx$1"; cur=""; word=""; inword=0; drop=0
    }

    guard_close() {
      guard_end
      sp=$((sp - 1))
      cur="${scur[sp]}"; word="${sword[sp]}"; inword="${sinw[sp]}"; drop="${sdrop[sp]}"
      ctx="${ctx%?}"
    }

    # Splits shell text into simple commands, appended to GUARD_CMDS as their
    # words joined by \037. Line by line, so a long heredoc or script costs time
    # in proportion to its length; quotes and substitutions carry across lines.
    guard_split() {
      local line i n c d top word="" inword=0 cur="" drop=0 op strip=0 ctx="" sp=0 hd=""
      local entry delim e t body cont
      local -a scur sword sinw sdrop
      while IFS= read -r line || [ -n "$line" ]; do
        # Bodies of heredocs opened on the line before: data, unless a shell reads them.
        if [ -n "$hd" ]; then
          entry="${hd%%$GUARD_RS*}"
          delim="${entry%%$GUARD_US*}"; e="${entry#*$GUARD_US}"; strip="${e%%$GUARD_US*}"; e="${e#*$GUARD_US}"
          t="$line"
          if [ "$strip" = 1 ]; then while [ "${t:0:1}" = "$GUARD_TAB" ]; do t="${t:1}"; done; fi
          if [ "$t" = "$delim" ]; then
            hd="${hd#*$GUARD_RS}"
            [ "$e" = 1 ] && [ -n "$body" ] && GUARD_SCRIPTS+=("$body")
            body=""
          else
            body="$body$line$GUARD_NL"
          fi
          continue
        fi
        body=""
        i=0; n=${#line}; cont=0
        while [ "$i" -lt "$n" ]; do
          c="${line:i:1}"
          top="${ctx:${#ctx}-1}"
          if [ "$top" = s ]; then
            # A single-quoted string carried over from a line above.
            t="${line:i}"
            case "$t" in
              *"'"*) d="${t%%\'*}"; word="$word$d"; i=$((i + ${#d} + 1)); ctx="${ctx%?}" ;;
              *) word="$word$t"; i=$n ;;
            esac
            continue
          fi
          if [ "$top" = d ]; then
            case "$c" in
              '"') ctx="${ctx%?}"; i=$((i + 1)) ;;
              '\')
                d="${line:i+1:1}"
                case "$d" in
                  '$'|'`'|'"'|'\') word="$word$d"; i=$((i + 2)) ;;
                  '') cont=1; i=$((i + 1)) ;;
                  *) word="$word\\"; i=$((i + 1)) ;;
                esac ;;
              '$')
                d="${line:i+1:1}"
                if [ "$d" = "(" ]; then guard_open p 1; i=$((i + 2))
                elif [ "$d" = "{" ]; then
                  word="$word$GUARD_UNKNOWN"; t="${line:i}"; t="${t%%\}*}"; i=$((i + ${#t} + 1))
                else word="$word\$"; i=$((i + 1)); fi ;;
              '`') guard_open b 1; i=$((i + 1)) ;;
              *)
                if [[ ${line:i} =~ $GUARD_RE_DQ ]]; then d="${BASH_REMATCH[0]}"; else d="$c"; fi
                word="$word$d"; i=$((i + ${#d})) ;;
            esac
            [ "$top" = d ] && inword=1
            continue
          fi
          case "$c" in
            ' '|"$GUARD_TAB") guard_word; i=$((i + 1)) ;;
            ';'|'&'|'|') guard_end; i=$((i + 1)) ;;
            '(') guard_open p 0; i=$((i + 1)) ;;
            ')')
              if [ "$top" = p ]; then guard_close; else guard_end; fi
              i=$((i + 1)) ;;
            '`')
              if [ "$top" = b ]; then guard_close; else guard_open b 1; fi
              i=$((i + 1)) ;;
            '<'|'>')
              # An fd number in front belongs to the redirection, and the word
              # after it is a file: neither is part of the command.
              case "$word" in
                ''|*[!0-9]*) guard_word ;;
                *) [ "$inword" = 1 ] && { word=""; inword=0; } ;;
              esac
              if [ "${line:i+1:1}" = "(" ]; then
                guard_open p 1; i=$((i + 2))
              else
                op="$c"; i=$((i + 1))
                while :; do
                  case "${line:i:1}" in '<'|'>'|'&'|'|') op="$op${line:i:1}"; i=$((i + 1)) ;; *) break ;; esac
                done
                if [ "$op" = "<<" ] && [ "${line:i:1}" = "-" ]; then op="<<-"; i=$((i + 1)); fi
                case "$op" in
                  '<<') drop=2; strip=0 ;;
                  '<<-') drop=2; strip=1 ;;
                  *) drop=1 ;;
                esac
              fi ;;
            '#')
              if [ "$inword" = 1 ]; then word="$word#"; i=$((i + 1)); else i=$n; fi ;;
            "'")
              t="${line:i+1}"
              case "$t" in
                *"'"*) d="${t%%\'*}"; word="$word$d"; i=$((i + ${#d} + 2)) ;;
                *) word="$word$t"; ctx="${ctx}s"; i=$n ;;
              esac
              inword=1 ;;
            '"') ctx="${ctx}d"; inword=1; i=$((i + 1)) ;;
            '\')
              d="${line:i+1:1}"
              if [ -z "$d" ]; then cont=1; i=$((i + 1))
              else word="$word$d"; inword=1; i=$((i + 2)); fi ;;
            '$')
              d="${line:i+1:1}"
              case "$d" in
                '(') guard_open p 1; i=$((i + 2)) ;;
                '"') ctx="${ctx}d"; inword=1; i=$((i + 2)) ;;
                "'")
                  # $'…': its escapes are taken as the character after the backslash.
                  t="${line:i+2}"; d=""
                  while [ -n "$t" ]; do
                    case "${t:0:1}" in
                      "'") t="${t:1}"; break ;;
                      '\') d="$d${t:1:1}"; t="${t:2}" ;;
                      *) d="$d${t:0:1}"; t="${t:1}" ;;
                    esac
                  done
                  word="$word$d"; inword=1; i=$((n - ${#t})) ;;
                '{')
                  word="$word$GUARD_UNKNOWN"; inword=1
                  t="${line:i}"; t="${t%%\}*}"; i=$((i + ${#t} + 1)) ;;
                *) word="$word\$"; inword=1; i=$((i + 1)) ;;
              esac ;;
            *)
              if [[ ${line:i} =~ $GUARD_RE_PLAIN ]]; then d="${BASH_REMATCH[0]}"; else d="$c"; fi
              word="$word$d"; inword=1; i=$((i + ${#d})) ;;
          esac
        done
        # The end of the line: inside quotes it's part of the word; after a
        # backslash it's nothing; otherwise it ends the command.
        if [ "$cont" = 1 ]; then continue; fi
        top="${ctx:${#ctx}-1}"
        case "$top" in
          d|s) word="$word$GUARD_NL" ;;
          *) guard_end ;;
        esac
      done <<< "$1"
      guard_end
      # A heredoc still open at the end: what there is of it.
      if [ -n "$hd" ] && [ -n "$body" ]; then
        case "$hd" in *"$GUARD_US"1"$GUARD_RS"*) GUARD_SCRIPTS+=("$body") ;; esac
      fi
    }

    # True when the pattern ($1, its words joined by \037) matches the simple
    # command in W whose program is at index $2.
    guard_pattern() {
      local r="$1" j="$2" head w a m pos="" flags="" prevopt=0 endopts=0 opts="$GUARD_US" letters="" f ch
      head="${r%%$GUARD_US*}"; r="${r#*$GUARD_US}"
      case "$head" in
        */*) [ "${W[j]}" = "$head" ] || return 1 ;;
        *) [ "${W[j]##*/}" = "$head" ] || return 1 ;;
      esac
      while [ -n "$r" ]; do
        w="${r%%$GUARD_US*}"; r="${r#*$GUARD_US}"
        case "$w" in -?*) flags="$flags$w$GUARD_US" ;; *) pos="$pos$w$GUARD_US" ;; esac
      done
      m=$((j + 1))
      while [ "$m" -lt "$n" ]; do
        a="${W[m]}"; m=$((m + 1))
        if [ "$endopts" = 0 ]; then
          case "$a" in
            --) endopts=1; prevopt=0; continue ;;
            -?*)
              opts="$opts$a$GUARD_US"
              case "$a" in --*|*=*) ;; *) letters="$letters${a#-}" ;; esac
              case "$a" in *=*) prevopt=0 ;; *) prevopt=1 ;; esac
              continue ;;
          esac
        fi
        [ -n "$pos" ] || continue
        if [ "$a" = "${pos%%$GUARD_US*}" ]; then
          pos="${pos#*$GUARD_US}"; prevopt=0
        elif [ "$prevopt" = 1 ]; then
          # Perhaps the value of the option before it (`git -C dir push`).
          prevopt=0
        else
          return 1
        fi
      done
      [ -z "$pos" ] || return 1
      while [ -n "$flags" ]; do
        w="${flags%%$GUARD_US*}"; flags="${flags#*$GUARD_US}"
        case "$opts" in *"$GUARD_US$w$GUARD_US"*|*"$GUARD_US$w="*) continue ;; esac
        f="${w#-}"
        case "$f" in -*|*[!A-Za-z0-9]*) return 1 ;; esac
        while [ -n "$f" ]; do
          ch="${f:0:1}"; f="${f:1}"
          case "$letters" in *"$ch"*) ;; *) return 1 ;; esac
        done
      done
      return 0
    }

    # The command at W[$1] against every pattern; then, for a shell with -c or an
    # eval, the script it runs.
    guard_at() {
      local j="$1" k=0 a sawc=0 joined=""
      while [ "$k" -lt "${#GUARD_PW[@]}" ]; do
        if guard_pattern "${GUARD_PW[k]}" "$j"; then GUARD_HIT="${GUARD_PN[k]}"; return 0; fi
        k=$((k + 1))
      done
      k=$((j + 1))
      case "${W[j]##*/}" in
        eval)
          while [ "$k" -lt "$n" ]; do joined="$joined ${W[k]}"; k=$((k + 1)); done
          guard_check "$joined" $((depth + 1)) && return 0 ;;
        bash|sh|zsh|dash|ksh|fish)
          while [ "$k" -lt "$n" ]; do
            a="${W[k]}"; k=$((k + 1))
            case "$a" in
              --*) ;;
              -*c*) sawc=1 ;;
              -*) ;;
              *) [ "$sawc" = 1 ] && guard_check "$a" $((depth + 1)) && return 0 ;;
            esac
          done ;;
      esac
      return 1
    }

    # One simple command ($1, words joined by \037): past any assignments and
    # reserved words to the program; past a wrapper (`env`, `sudo`, `xargs`…) to
    # whatever it runs, tried at every word after it.
    guard_command() {
      local r="$1" depth="$2" n=0 k=0
      local -a W
      while [ -n "$r" ]; do W[n]="${r%%$GUARD_US*}"; r="${r#*$GUARD_US}"; n=$((n + 1)); done
      while [ "$k" -lt "$n" ]; do
        case "${W[k]}" in
          if|then|else|elif|do|while|until|'!'|'{'|'}') k=$((k + 1)) ;;
          *) if [[ ${W[k]} =~ $GUARD_RE_ASSIGN ]]; then k=$((k + 1)); else break; fi ;;
        esac
      done
      [ "$k" -lt "$n" ] || return 1
      case "${W[k]##*/}" in
        env|command|builtin|exec|nohup|time|sudo|doas|nice|timeout|gtimeout|xargs|find|caffeinate|stdbuf|unbuffer)
          k=$((k + 1))
          while [ "$k" -lt "$n" ]; do guard_at "$k" && return 0; k=$((k + 1)); done
          return 1 ;;
      esac
      guard_at "$k"
    }

    # Every simple command in the shell text $1, and every script one of them hands
    # to a shell. $2 is how deep in such scripts this is; four levels is plenty
    # for an honest command.
    guard_check() {
      local depth="$2" k c0 c1 s0 s1
      [ "$depth" -le 3 ] || return 1
      c0=${#GUARD_CMDS[@]}; s0=${#GUARD_SCRIPTS[@]}
      guard_split "$1"
      c1=${#GUARD_CMDS[@]}; s1=${#GUARD_SCRIPTS[@]}
      k=$c0
      while [ "$k" -lt "$c1" ]; do
        guard_command "${GUARD_CMDS[k]}" "$depth" && return 0
        k=$((k + 1))
      done
      k=$s0
      while [ "$k" -lt "$s1" ]; do
        guard_check "${GUARD_SCRIPTS[k]}" $((depth + 1)) && return 0
        k=$((k + 1))
      done
      return 1
    }

    # True when the hook payload $1 carries a command on the list. The pattern it
    # matched is left in GUARD_HIT, and the command as Claude Code escaped it in
    # GUARD_RAW. Needs `set +eu` and LC_ALL=C, which its callers set.
    guard_matches() {
      local flat line w joined
      local -a words
      GUARD_HIT=""; GUARD_RAW=""; GUARD_LONG=0
      [ -s "$GUARD_LIST" ] || return 1
      [[ $1 =~ $GUARD_RE_COMMAND ]] || return 1
      GUARD_RAW="${BASH_REMATCH[1]}"
      guard_unescape "$GUARD_RAW"

      # Only the patterns whose every word is somewhere in the text, quotes and
      # backslashes aside, can match it: most calls end here.
      guard_flatten "$GUARD_TEXT"
      flat="$GUARD_FLAT"
      GUARD_PW=(); GUARD_PN=()
      set -f
      while IFS= read -r line || [ -n "$line" ]; do
        words=($line)
        [ "${#words[@]}" -gt 0 ] || continue
        joined=""
        for w in "${words[@]}"; do
          case "$w" in
            -*) ;;
            *) case "$flat" in *"${w##*/}"*) ;; *) continue 2 ;; esac ;;
          esac
          joined="$joined$w$GUARD_US"
        done
        GUARD_PW+=("$joined"); GUARD_PN+=("${words[*]}")
      done < "$GUARD_LIST"
      set +f
      [ "${#GUARD_PW[@]}" -gt 0 ] || return 1

      # Too long to read inside the hook's 10s, and it mentions every word of a
      # pattern: ask. A speed bump errs toward asking; a timeout would let the
      # call through unasked.
      if [ "${#GUARD_TEXT}" -gt "$GUARD_PARSE_MAX" ]; then
        GUARD_HIT="${GUARD_PN[0]}"; GUARD_LONG=1
        return 0
      fi
      GUARD_CMDS=(); GUARD_SCRIPTS=()
      guard_check "$GUARD_TEXT" 0
    }

    # `guard` (PreToolUse on Bash and Monitor): ask when the command is on the
    # list. Says nothing otherwise, and on anything it can't read: a guard that
    # fails must never break the call it was only meant to slow down.
    guard_main() {
      local sid safe esc rec reason
      set +eu
      export LC_ALL=C
      IFS= read -r -d '' GUARD_JSON
      guard_matches "$GUARD_JSON" || return 0

      # Asked: leave the notch the reason, then tell Claude Code to ask.
      sid=""
      [[ $GUARD_JSON =~ $GUARD_RE_SESSION ]] && sid="${BASH_REMATCH[1]}"
      safe="${sid//[!A-Za-z0-9_-]/}"
      esc="$(json_escape "$GUARD_HIT")"
      rec="$GUARD_DIR/${safe:-unknown}.json"
      [ -d "$GUARD_DIR" ] || mkdir -p "$GUARD_DIR"
      printf '{"pattern": "%s", "command": "%s"}\n' "$esc" "$GUARD_RAW" > "$rec.tmp.$$" \
        && mv -f "$rec.tmp.$$" "$rec"
      if [ "$GUARD_LONG" = 1 ]; then
        reason="Guarded in Isle: too long to read, and it mentions \`$esc\`, which always asks."
      else
        reason="Guarded in Isle: matches \`$esc\`, which always asks."
      fi
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
        "$reason"
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
      guard)
        # Before anything else is read or forked: off, or an empty list, and the
        # call goes on as if there were no hook at all.
        [ -s "$GUARD_LIST" ] || exit 0
        guard_main
        exit 0
        ;;
      end)
        STATE="disconnected"   # SessionEnd — clear the island (guarded below)
        ;;
      *)
        echo "Usage: isle-cli <set-state <state> | notify | fail | ask | ask-question | guard | end>" >&2
        exit 1
        ;;
    esac

    PROJECT="$(json_escape "$(basename "$PWD")")"
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
    # The start of what Claude said last, for the Done face (Stop only).
    LAST_EXCERPT=""
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

      # Stop: the first 300 characters of Claude's final message, so the Done
      # face can say what happened in Claude's own words. Kept exactly as Claude
      # Code escaped it — the text never leaves JSON form, so nothing here has to
      # escape it again — and cut on a whole token: an escape (\" \\ \n é),
      # or one character under a UTF-8 locale. So the cut can't land inside an
      # escape or a multi-byte character, and no bare quote or backslash can get
      # through. A \u escape for half a surrogate pair isn't a token, so the
      # excerpt simply ends before one. Two runs of 150 because 255 is the most
      # one repeat can count. A raw DEL (JSON allows one) is dropped; anything
      # that still isn't valid UTF-8 drops the excerpt, and the face says
      # "Finished responding" as before.
      if [ "$CMD" = "set-state" ] && [ "$HOOK_EVENT" = "Stop" ]; then
        tok='(\\u([0-9A-Ca-c][0-9A-Fa-f]{3}|[Dd][0-7][0-9A-Fa-f]{2}|[EFef][0-9A-Fa-f]{3})|\\["\\/bfnrt]|[^"\\])'
        LAST_EXCERPT="$(printf '%s' "$STDIN_JSON" \
          | LC_ALL=en_US.UTF-8 grep -oE "\"last_assistant_message\"[[:space:]]*:[[:space:]]*\"$tok{0,150}$tok{0,150}" \
          | head -1 \
          | LC_ALL=en_US.UTF-8 sed -E 's/^"last_assistant_message"[[:space:]]*:[[:space:]]*"//' \
          | LC_ALL=C tr -d '\000-\037\177' || true)"
        if ! printf '%s' "$LAST_EXCERPT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
          LAST_EXCERPT=""
        fi
      fi
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
              # "Always…" never covers a guarded command. The notch doesn't offer
              # it for one, and Claude Code sends no suggestions to save after a
              # hook's ask; this is the last word, in case either ever changes:
              # the call is allowed once, and no rule or mode is saved.
              case "$ACTION:$RESPONSE" in
                Bash:*'"updatedPermissions"'*|Monitor:*'"updatedPermissions"'*)
                  if ( set +eu; export LC_ALL=C; guard_matches "$STDIN_JSON" ); then
                    RESPONSE='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
                  fi ;;
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
      # The idle nudge comes a minute after a Stop, about the same finished turn:
      # keep what Claude said, copied from the record verbatim (it is already
      # escaped and checked), so the face doesn't lose it to the nudge. A new
      # prompt writes `working`, which drops it.
      if [ "$STATE" = "waiting_input" ] && [ -f "$sf" ]; then
        LAST_EXCERPT="$(LC_ALL=C grep -oE '"last_message": "([^"\\]|\\.)*"' "$sf" 2>/dev/null \
          | head -1 | LC_ALL=C sed -E 's/^"last_message": "//; s/"$//' || true)"
        if ! printf '%s' "$LAST_EXCERPT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
          LAST_EXCERPT=""
        fi
      fi
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
      rm -f "$SESSION_DIR/${SESSION_ID:-unknown}.json" \
        "$GUARD_DIR/$(printf '%s' "${SESSION_ID:-unknown}" | tr -cd 'A-Za-z0-9_-').json"
      exit 0
    fi

    write_status "$STATE" ""
    """#
}
