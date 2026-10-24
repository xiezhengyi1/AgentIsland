import Foundation
import IslandCore

// `island` — reports agent status to Agent Island. Hooks call it; it must stay quiet on stdout
// (Claude Code adds UserPromptSubmit stdout to the prompt) and always exit 0.

let usage = """
usage:
  island hook <agent> [codex-json] [--then <cmd> [args...]]
        Read a hook payload (stdin, or a trailing JSON arg as Codex `notify` passes it) and update status.
        --then: also run another notify program afterwards with the same args (to chain an existing notify).
  island set <agent> <working|waiting|done|idle|error> [message] [--id ID] [--cwd DIR]
        Report status manually from any script or agent.
  island clear [id]       Remove one session, or all sessions.
  island list             Print current sessions.
  island install claude   Copy this binary to ~/.agent-island/bin and add hooks to ~/.claude/settings.json (backup kept).
"""

let kinds = AgentCatalog.load()

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func runHook(_ args: [String]) {
    guard let agent = args.first else { fail(usage) }
    var rest = Array(args.dropFirst())
    var chained: [String] = []
    if let i = rest.firstIndex(of: "--then") {
        chained = Array(rest[(i + 1)...])
        rest = Array(rest[..<i])
    }
    // Codex appends its JSON as the final argv element (after any --then args too).
    var jsonArg = rest.last(where: { $0.hasPrefix("{") })
    if jsonArg == nil, let last = chained.last, last.hasPrefix("{") { jsonArg = last }

    var payload: [String: Any] = [:]
    if let jsonArg, let data = jsonArg.data(using: .utf8) {
        payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    } else if isatty(STDIN_FILENO) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    let pid = ProcessScanner.agentAncestor(of: getppid(), agentID: agent, kinds: kinds)
    let sid = HookMapper.sessionID(payload) ?? pid.map(String.init) ?? "default"
    let id = "\(agent)-\(sid)"
    let cwd = (payload["cwd"] as? String) ?? pid.flatMap(Proc.cwd) ?? FileManager.default.currentDirectoryPath

    switch HookMapper.outcome(for: payload) {
    case .remove:
        SessionFiles.remove(id: id)
    case .ignore:
        break
    case let .update(state, message):
        // Tool events without their own message keep the last meaningful one.
        let msg = message ?? SessionFiles.read(id: id)?.message
        try? SessionFiles.write(HookSession(id: id, agent: agent, state: state, message: msg, cwd: cwd, pid: pid,
                                            turnEndOnly: jsonArg != nil ? true : nil))
    }

    if !chained.isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: chained[0])
        p.arguments = Array(chained.dropFirst())
        try? p.run()
        p.waitUntilExit()
    }
}

func runSet(_ args: [String]) {
    var positional: [String] = []
    var id: String?
    var cwd = FileManager.default.currentDirectoryPath
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--id": i += 1; id = i < args.count ? args[i] : nil
        case "--cwd": i += 1; if i < args.count { cwd = args[i] }
        default: positional.append(args[i])
        }
        i += 1
    }
    guard positional.count >= 2, let state = AgentState(rawValue: positional[1]) else { fail(usage) }
    let agent = positional[0]
    let pid = ProcessScanner.agentAncestor(of: getppid(), agentID: agent, kinds: kinds)
    let message = positional.count > 2 ? positional[2...].joined(separator: " ") : nil
    let session = HookSession(id: id ?? "\(agent)-\(pid.map(String.init) ?? "manual")", agent: agent, state: state,
                              message: message, cwd: cwd, pid: pid)
    do { try SessionFiles.write(session) } catch { fail("island: \(error.localizedDescription)") }
}

func installClaude() {
    let fm = FileManager.default
    let self_ = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let dest = IslandPaths.bin.appendingPathComponent("island")
    do {
        try fm.createDirectory(at: IslandPaths.bin, withIntermediateDirectories: true)
        if self_.path != dest.path {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: self_, to: dest)
        }
    } catch { fail("island: could not install binary: \(error.localizedDescription)") }

    let settingsURL = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: settingsURL) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("island: ~/.claude/settings.json is not valid JSON; not touching it")
        }
        settings = obj
        let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.agent-island-backup")
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: settingsURL, to: backup)
    }

    let command = "\"\(dest.path)\" hook claude"
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
                  "PermissionRequest", "Stop", "SessionEnd"]
    var added: [String] = []
    for event in events {
        var groups = hooks[event] as? [[String: Any]] ?? []
        let already = groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains(".agent-island/") }
        }
        if already { continue }
        var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
        if ["PreToolUse", "PostToolUse", "PermissionRequest"].contains(event) { group["matcher"] = "*" }
        groups.append(group)
        hooks[event] = groups
        added.append(event)
    }
    settings["hooks"] = hooks
    do {
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    } catch { fail("island: could not write settings: \(error.localizedDescription)") }

    print(added.isEmpty ? "Claude Code hooks were already installed." : "Added Claude Code hooks: \(added.joined(separator: ", "))")
    print("Binary: \(dest.path)")
    print("Backup: ~/.claude/settings.json.agent-island-backup")
    print("New Claude Code sessions will report precise status.")
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(0) }
args.removeFirst()

switch cmd {
case "hook":
    runHook(args)
case "set":
    runSet(args)
case "clear":
    if let id = args.first { SessionFiles.remove(id: id) } else {
        for s in SessionFiles.readAll() { SessionFiles.remove(id: s.id) }
    }
case "list":
    for s in SessionFiles.readAll().sorted(by: { $0.updatedAt > $1.updatedAt }) {
        print("\(s.id)\t\(s.state.rawValue)\t\(s.pid.map(String.init) ?? "-")\t\(s.cwd ?? "")\t\(s.message ?? "")")
    }
case "install":
    guard args.first == "claude" else { fail(usage) }
    installClaude()
default:
    print(usage)
}
exit(0)
