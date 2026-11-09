//
//  claude-activity-tests.swift
//
//  Tests for the "what it's doing" line (`ClaudeActivity.phrase`), the
//  finished calls under it (`pastPhrase`, `ClaudeTrail`), compiled against
//  Isle/Claude/ClaudeActivity.swift and ClaudeTrail.swift alone. Run with
//  scripts/test-claude-activity.sh, which also feeds it real hook targets:
//  each Bash command put through `isle-cli` the way Claude Code runs it, so
//  the app is tested on what the hook actually hands it — backslashes gone,
//  cut at the first escaped quote, then at 48 characters.
//

import Foundation

var failures = 0
var passes = 0

func check(_ got: String, _ want: String, _ name: String) {
    if got == want {
        passes += 1
        print("  ok    \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name)\n        want \(want)\n        got  \(got)")
    }
}

func bash(_ target: String?) -> String {
    ClaudeActivity(action: "Bash", target: target)!.phrase
}

func bashPast(_ target: String?) -> String {
    ClaudeActivity(action: "Bash", target: target)!.pastPhrase
}

/// How `displayTarget` read a command before: its first space-separated
/// token, de-pathed.
func legacy(_ target: String) -> String {
    let token = String(target.split(separator: " ").first ?? "")
    let name = (token as NSString).lastPathComponent
    return "Running " + (name.isEmpty ? token : name)
}

// MARK: - What the hook hands the app

/// Lines of `name<TAB>target<TAB>want` from the runner, one per command put
/// through isle-cli.
if CommandLine.arguments.count > 1 {
    print("Through isle-cli")
    let file = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    for line in file.split(separator: "\n", omittingEmptySubsequences: true) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3 else { failures += 1; print("  FAIL  bad line: \(line)"); continue }
        check(bash(fields[1].isEmpty ? nil : fields[1]), fields[2], fields[0])
    }
}

// MARK: - The reported line

print("The reported line")
// `R=<scratch dir>; …`, the shape this session's own commands take: the hook
// cuts it to these 48 characters, with no space left in them, and the first
// token's last path component was the encoded project folder, cut short.
let reported = "R=/private/tmp/claude-501/-Users-matthew-Documen"
check(legacy(reported), "Running -Users-matthew-Documen", "the old reading gave the reported text")
check(bash(reported), "Running a command", "now: an assignment and nothing after it")

// MARK: - Straight to the parser

print("Programs")
check(bash("npm test"), "Running npm", "npm test")
check(bash("git push origin main"), "Running git", "git push")
check(bash("xcodebuild"), "Running xcodebuild", "a bare program")
check(bash("/usr/bin/git log"), "Running git", "by path")
check(bash("./scripts/build.sh --release"), "Running build.sh", "a script by relative path")
check(bash("swift-format lint ."), "Running swift-format", "a hyphenated name")
check(bash("g++ main.cpp"), "Running g++", "g++")
check(bash("python3.12 -m pytest"), "Running python3.12", "a dotted name")

print("Assignments and setup")
check(bash("FOO=1 npm test"), "Running npm", "one assignment")
check(bash("A=1 B=2 make"), "Running make", "two assignments")
check(bash("VAR='a b' make"), "Running make", "an assignment with a quoted space")
check(bash("export X=1; swift build"), "Running swift", "export, then ;")
check(bash("export PATH=/opt/homebrew/bin:$PATH && swift test"), "Running swift", "export, then &&")
check(bash("cd /tmp && make"), "Running make", "cd &&")
check(bash("cd /tmp; make"), "Running make", "cd ;")
check(bash("cd a && cd b && make"), "Running make", "two cds")
check(bash("pushd x; npm i"), "Running npm", "pushd")
check(bash("set -e; make"), "Running make", "set -e")
check(bash("(cd Isle && swift build)"), "Running swift", "(cd x && y)")
check(bash("{ make; }"), "Running make", "a brace group")
check(bash("if git push; then echo ok; fi"), "Running git", "if")
check(bash("! grep -q x f"), "Running grep", "!")
check(bash("make 2>&1 | tail -5"), "Running make", "a pipe after the program")

print("Wrappers")
check(bash("env FOO=1 git status"), "Running git", "env with an assignment")
check(bash("env -i PATH=/usr/bin git status"), "Running git", "env -i")
check(bash("sudo launchctl list"), "Running launchctl", "sudo")
check(bash("sudo -u root launchctl list"), "Running launchctl", "sudo -u user")
check(bash("time xcodebuild build"), "Running xcodebuild", "time")
check(bash("time -p make"), "Running make", "time -p")
check(bash("nohup python3 server.py > log 2>&1 &"), "Running python3", "nohup")
check(bash("command git status"), "Running git", "command")
check(bash("exec swift run"), "Running swift", "exec")
check(bash("FOO=1 sudo env BAR=2 time make"), "Running make", "stacked")
check(bash("command -v brew"), "Running command", "command -v only looks a name up")

print("Quotes")
check(bash("'/usr/local/bin/node' app.js"), "Running node", "a single-quoted path")
check(bash("\"/usr/local/bin/node\" app.js"), "Running node", "a double-quoted path")
check(bash("g\"i\"t status"), "Running git", "quotes inside a word")

print("Nothing it can stand behind: \"Running a command\"")
check(bash(nil), "Running a command", "no target")
check(bash(""), "Running a command", "an empty target")
check(bash("   "), "Running a command", "only spaces")
check(bash("FOO=1"), "Running a command", "only an assignment")
check(bash("export X=1"), "Running a command", "only export")
check(bash("cd /tmp"), "Running a command", "only cd")
check(bash("sudo"), "Running a command", "only a wrapper")
check(bash("-Users-matthew-Documents-isle"), "Running a command", "a leading -")
check(bash("--version"), "Running a command", "an option")
check(bash("$HOME/bin/tool run"), "Running a command", "a variable")
check(bash("$(which git) status"), "Running a command", "a substitution")
check(bash("`which git` status"), "Running a command", "backticks")
check(bash("*.sh"), "Running a command", "a glob")
check(bash("2>&1"), "Running a command", "a redirection")
check(bash(".. x"), "Running a command", "..")
check(bash("# build it"), "Running a command", "only a comment")
check(bash("cd /tmp; ls -la | grep x"), "Running ls", "and back to a name after setup")

print("At the hook's 48-character cut")
let cutInCd = "cd /Users/matthew/Documents/isle/.claude/worktree"
check(bash(String(cutInCd.prefix(48))), "Running a command", "cut inside the cd")
let cutInProgram = "cd /Users/matthew/Documents/isle/Isle && xcodebui"
check(bash(String(cutInProgram.prefix(48))), "Running a command", "cut inside the program's name")
let cutAfterProgram = "cd /Users/matthew/Documents/isle && xcodebuild -p"
check(bash(String(cutAfterProgram.prefix(48))), "Running xcodebuild", "cut after the program's name")
check(bash("npm"), "Running npm", "short and ending in the name: whole")

print("Other tools are untouched")
check(ClaudeActivity(action: "Edit", target: "/a/b/App.swift")!.phrase, "Editing App.swift", "Edit")
check(ClaudeActivity(action: "Read", target: "README.md")!.phrase, "Reading README.md", "Read")
check(ClaudeActivity(action: "WebFetch", target: "https://www.apple.com/x")!.phrase, "Browsing apple.com", "WebFetch")
check(ClaudeActivity(action: "Grep", target: "activeRect")!.phrase, "Searching \u{201C}activeRect\u{201D}", "Grep")

print("The finished call, said in the past")
check(ClaudeActivity(action: "Edit", target: "/a/b/App.swift")!.pastPhrase, "Edited App.swift", "Edit")
check(ClaudeActivity(action: "Read", target: "README.md")!.pastPhrase, "Read README.md", "Read")
check(bashPast("xcodebuild -scheme Isle"), "Ran xcodebuild", "Bash")
check(bashPast("cd /tmp"), "Ran a command", "Bash with no program to name")
check(ClaudeActivity(action: "Grep", target: "activeRect")!.pastPhrase, "Searched \u{201C}activeRect\u{201D}", "Grep")
check(ClaudeActivity(action: "Task", target: nil)!.pastPhrase, "Delegated a task", "Task")
check(ClaudeActivity(action: "mcp__acme__deploy", target: nil)!.pastPhrase, "mcp__acme__deploy", "an unknown tool by its name")

print("The trail: only calls that ran, in order, cleared by a new turn")
func names(_ trail: ClaudeTrail, current: ClaudeActivity? = nil, limit: Int = 3) -> String {
    trail.shown(current: current, limit: limit).map(\.activity.pastPhrase).joined(separator: " | ")
}
var trail = ClaudeTrail()
trail.observe(phase: .working, action: nil, target: nil, toolActive: false)
check(names(trail), "", "a prompt alone is no step")
trail.observe(phase: .working, action: "Read", target: "a.swift", toolActive: true)
check(names(trail), "", "a call starting (PreToolUse) is no step yet")
trail.observe(phase: .working, action: "Read", target: "a.swift", toolActive: false)
check(names(trail), "Read a.swift", "its PostToolUse is")
trail.observe(phase: .working, action: "Read", target: "a.swift", toolActive: false)
check(names(trail), "Read a.swift", "the same record read again is one step")
trail.observe(phase: .waiting, action: "Bash", target: "rm", toolActive: false)
check(names(trail), "Read a.swift", "an approval waiting adds nothing")
trail.observe(phase: .working, action: "Bash", target: "rm", toolActive: true)
trail.observe(phase: .working, action: "Edit", target: "b.swift", toolActive: true)
check(names(trail), "Read a.swift", "a call denied in the terminal (no PostToolUse) is no step")
trail.observe(phase: .working, action: "Edit", target: "b.swift", toolActive: false)
trail.observe(phase: .working, action: "Bash", target: "make", toolActive: false)
check(names(trail), "Ran make | Edited b.swift | Read a.swift", "newest first")
let make = ClaudeActivity(action: "Bash", target: "make")
check(names(trail, current: make), "Edited b.swift | Read a.swift", "the call the headline names isn't repeated under it")
check(names(trail, limit: 2), "Ran make | Edited b.swift", "at most the slots there are")
for i in 0..<6 { trail.observe(phase: .working, action: "Read", target: "f\(i).swift", toolActive: false) }
check("\(trail.steps.count)", "\(ClaudeTrail.capacity)", "keeps no more than it can show")
check(names(trail, limit: 3), "Read f5.swift | Read f4.swift | Read f3.swift", "the newest kept")
trail.observe(phase: .ended, action: nil, target: nil, toolActive: false)
check(names(trail), "Read f5.swift | Read f4.swift | Read f3.swift", "the turn's end leaves the trail until the next")
trail.observe(phase: .working, action: nil, target: nil, toolActive: false)
check(names(trail), "", "the next turn starts it afresh")
let ids = { (t: ClaudeTrail) in Set(t.steps.map(\.id)).count == t.steps.count }
trail.observe(phase: .working, action: "Read", target: "x", toolActive: false)
trail.observe(phase: .working, action: "Read", target: "y", toolActive: false)
check("\(ids(trail))", "true", "every step its own id, across turns")

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
