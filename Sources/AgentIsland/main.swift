import AppKit

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { Snapshot.run(to: CommandLine.arguments[i + 1]) }
    app.setActivationPolicy(.prohibited)
    app.run()
}
// `--measure <file>`: write what the menu-bar measurement sees (run via `open` so the app's own
// Accessibility permission applies).
if let i = CommandLine.arguments.firstIndex(of: "--measure"), i + 1 < CommandLine.arguments.count {
    let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens[0]
    let req = MenuBarSpace.request(for: screen, notch: NotchMetrics.of(screen))
    let front = NSWorkspace.shared.frontmostApplication
    let names = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.localizedName ?? "?") },
                           uniquingKeysWith: { a, _ in a })
    let text = "frontmost: \(front?.localizedName ?? "-")\n" +
        MenuBarSpace.report(req, frontmostPID: front?.processIdentifier, names: names)
    try? text.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
    exit(0)
}
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
