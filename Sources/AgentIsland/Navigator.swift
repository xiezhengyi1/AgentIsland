import AppKit
import IslandCore

/// Brings the window that hosts an agent session to the front.
///
/// Walks up from the agent's pid to the first GUI app (Terminal, iTerm2, VS Code, Claude, Codex …).
/// Terminals get the exact tab selected by tty; editors get the window for the session's folder.
@MainActor
enum Navigator {
    static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.vscodium",
    ]

    static func hostApp(for pid: pid_t) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<24 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            guard let bi = Proc.bsdInfo(p), bi.ppid > 1 else { return nil }
            p = bi.ppid
        }
        return nil
    }

    static func hint(for entry: AgentEntry) -> String {
        if let pid = entry.pid, let app = hostApp(for: pid) { return "Go to \(app.localizedName ?? "app")" }
        return entry.cwd != nil ? "Reveal folder in Finder" : ""
    }

    static func go(to entry: AgentEntry) {
        guard let pid = entry.pid, let app = hostApp(for: pid) else {
            // tmux/ssh/launchd-started agents have no GUI ancestor: fall back to the project folder.
            if let cwd = entry.cwd { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
            return
        }
        let bundle = app.bundleIdentifier ?? ""
        let tty = Proc.tty(pid)

        if bundle == "com.apple.Terminal", let tty {
            runAppleScript("""
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """, fallback: app)
        } else if bundle == "com.googlecode.iterm2", let tty {
            runAppleScript("""
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                tell t to select
                                tell s to select
                            end if
                        end repeat
                    end repeat
                end repeat
                activate
            end tell
            """, fallback: app)
        } else if editors.contains(bundle), let cwd = entry.cwd, let appURL = app.bundleURL {
            // Opening the folder with the editor focuses the window that already has it open.
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: appURL, configuration: cfg)
        } else {
            activate(app)
        }
    }

    static func activate(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateAllWindows])
    }

    /// Runs off the main thread; needs Automation permission the first time (macOS asks).
    static func runAppleScript(_ source: String, fallback app: NSRunningApplication) {
        activate(app)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
