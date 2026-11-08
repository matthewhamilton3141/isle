//
//  GuardedCommandFixtures.swift
//
//  The approval face when Isle's own guard is why Claude is asking
//  (Milestone 17). Each request is the PermissionRequest Claude Code 2.1.319
//  sends after a hook's `ask` — no `permission_suggestions`, so no Always… —
//  marked guarded the way the watcher marks it from the guard's record.
//
//  Debug only; nothing here ships.
//

#if DEBUG
import Foundation

extension ClaudePanelFixture {
    /// A PermissionRequest after the guard's ask, decoded by the app's own
    /// decoder and marked with the pattern the record would name.
    static func guardedApproval(_ tool: String, command: String, mode: String = "auto",
                                pattern: String) -> ClaudeRequest {
        let input = try! JSONSerialization.data(withJSONObject: ["command": command, "description": "Run it"])
        let stdin = #"{"session_id":"preview-session","cwd":"/Users/matthew/Documents/isle","hook_event_name":"PermissionRequest","permission_mode":""#
            + mode + #"","tool_name":""# + tool + #"","tool_input":"# + String(decoding: input, as: UTF8.self) + "}"
        var request = approval(stdin: stdin)
        request.guarded(by: pattern)
        return request
    }

    static var guardedApprovals: [ClaudePanelFixture] {
        [
            .init(name: "guarded_git_push", state: .needsApproval, action: "Bash", target: "git",
                  request: guardedApproval("Bash", command: "git push origin main", pattern: "git push")),
            .init(name: "guarded_chain", state: .needsApproval, action: "Bash", target: "git",
                  request: guardedApproval("Bash",
                      command: "git add -A && git commit -m \"Guard the notch\" && git push --force-with-lease origin feature/guarded-commands",
                      pattern: "git push")),
            .init(name: "guarded_rm", state: .needsApproval, action: "Bash", target: "rm",
                  request: guardedApproval("Bash", command: "rm -rf ~/Library/Developer/Xcode/DerivedData/Isle-*",
                                           mode: "bypassPermissions", pattern: "rm -rf")),
            .init(name: "guarded_long_pattern", state: .needsApproval, action: "Bash", target: "gh",
                  request: guardedApproval("Bash", command: "gh pr merge 41 --squash --delete-branch",
                                           pattern: "gh pr merge --squash --delete-branch")),
            .init(name: "guarded_monitor", state: .needsApproval, action: "Monitor", target: "tail",
                  request: guardedApproval("Monitor", command: "npm publish --access public && tail -f npm-debug.log",
                                           pattern: "npm publish")),
            .init(name: "guarded_crowded", state: .needsApproval, action: "Bash", target: "git",
                  request: guardedApproval("Bash", command: "git push origin main", pattern: "git push"),
                  keepAwake: true, others: .init(working: 1, needYou: 1), host: terminalHost),
            .init(name: "both_guarded_git_push", mode: .both, state: .needsApproval, action: "Bash", target: "git",
                  request: guardedApproval("Bash", command: "git push origin main", pattern: "git push")),
        ]
    }
}
#endif
