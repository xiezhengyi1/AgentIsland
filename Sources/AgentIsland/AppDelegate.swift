import AppKit
import Combine
import IslandCore
import SwiftUI

final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above the menu bar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Allow the window to sit over the menu bar / notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A small window over the notch strip (menu-bar part of the island). The system tells it when the
/// pointer enters, leaves or clicks, so hovering needs no global mouse tracking at all.
final class HoverPanel: NSPanel {
    let hoverView = HoverView()
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        contentView = hoverView
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Fully transparent pixels let clicks fall through to the window below, so use a nearly invisible fill.
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.01).cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The window is only as big as it needs to be: its backing store is most of the app's memory.
    static let foldedCanvas = NSSize(width: 520, height: 110)
    static let unfoldedCanvas = NSSize(width: 640, height: 470)
    var canvas: NSSize { model.expanded ? Self.unfoldedCanvas : Self.foldedCanvas }

    let model = IslandModel()
    var panel: IslandPanel!
    var statusItem: NSStatusItem!
    var hoverPanel: HoverPanel!
    var moveMonitors: [Any] = []   // pointer tracking, only while the popup or list is open
    var mouseMonitors: [Any] = []  // rare events: clicks
    var shrinkTask: Task<Void, Never>?
    var statusRefreshTask: Task<Void, Never>?
    var hoverOpenTask: Task<Void, Never>?
    var clickMonitor: Any?
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.foldedCanvas))
        let host = FirstClickHostingView(rootView: IslandRootView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.foldedCanvas)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        place()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place(); self?.syncHoverPanel() }
        }

        // Hovering the notch strip is reported by its own small window. Full pointer tracking (needed to
        // keep clicks passing through the transparent parts of the big window) only runs while the
        // popup or list is showing.
        hoverPanel = HoverPanel()
        hoverPanel.hoverView.onEnter = { [weak self] in MainActor.assumeIsolated { self?.hoverChanged(true) } }
        hoverPanel.hoverView.onExit = { [weak self] in MainActor.assumeIsolated { self?.hoverChanged(false) } }
        hoverPanel.hoverView.onClick = { [weak self] in MainActor.assumeIsolated { self?.model.toggle() } }
        syncHoverPanel()
        hoverPanel.orderFrontRegardless()
        if let c = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.expanded, !self.isOnIsland(NSEvent.mouseLocation) else { return }
                self.model.setExpanded(false)
            }
        }) { mouseMonitors.append(c) }
        // A click in the menu bar can reveal or move status icons: re-measure just after.
        if let u = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.menuBarClicked() }
        }) { mouseMonitors.append(u) }

        // Re-measure free menu-bar space as soon as another app (with other menus) comes forward.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.model.appActivated(pid: pid) }
        }
        // A new or quitting app can add or remove status icons.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refreshStatusItems(full: true) }
            }
        }
        askForAccessibilityOnce()

        setupStatusItem()
        model.$entries.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusTitle() }.store(in: &bag)
        model.$expanded.dropFirst().removeDuplicates().sink { [weak self] open in
            MainActor.assumeIsolated { self?.resizeForExpanded(open) }
        }.store(in: &bag)
        model.objectWillChange.debounce(for: .milliseconds(30), scheduler: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncHoverPanel()
                self?.updateMouseTracking()
            }
        }.store(in: &bag)
        model.start()
    }

    /// The screen with a notch if there is one, otherwise the one with the menu bar.
    var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    func place() {
        guard let screen = targetScreen else { return }
        let notch = NotchMetrics.of(screen)
        model.notch = notch
        let f = screen.frame
        model.screenGeometry = MenuBarSpace.request(for: screen, notch: notch)
        let c = canvas
        panel.setFrame(NSRect(x: f.midX - c.width / 2, y: f.maxY - c.height, width: c.width, height: c.height), display: true)
    }

    /// Grow the window before the list opens; shrink it once the fold animation has finished.
    func resizeForExpanded(_ open: Bool) {
        shrinkTask?.cancel()
        if open {
            place()
        } else {
            shrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let self, !Task.isCancelled, !self.model.expanded else { return }
                self.place()
            }
        }
    }

    func menuBarClicked() {
        guard let screen = targetScreen, NSEvent.mouseLocation.y > screen.frame.maxY - 40 else { return }
        statusRefreshTask?.cancel()
        statusRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.model.refreshStatusItems(full: false)
        }
    }

    /// Whether a screen point is on the black part of the island (not the transparent corners
    /// beside the notch, so menu bar items there stay clickable).
    func isOnIsland(_ point: NSPoint, slop: CGFloat = 0) -> Bool {
        let size = model.islandSize
        let f = panel.frame
        let originX = f.midX - size.width / 2
        return model.hitRects.contains { r in
            NSRect(x: originX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
                .insetBy(dx: -slop, dy: -slop)
                .contains(point)
        }
    }

    /// Pointer moved while the popup/list is open: decide whether it is over the island (then the big
    /// window takes clicks) or over something else (then clicks pass through).
    func trackMouse() {
        let mouse = NSEvent.mouseLocation
        if !model.hovering, mouse.y < panel.frame.maxY - model.islandSize.height - 4 {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }
        let inside = isOnIsland(mouse, slop: 1)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        setHover(inside)
    }

    func updateMouseTracking() {
        let need = model.expanded || model.popup != nil
        if need && moveMonitors.isEmpty {
            let move: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.trackMouse() } }
            if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: move) { moveMonitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { e in move(e); return e }) { moveMonitors.append(l) }
        } else if !need && !moveMonitors.isEmpty {
            moveMonitors.forEach(NSEvent.removeMonitor)
            moveMonitors = []
            panel.ignoresMouseEvents = true
        }
        if need { trackMouse() }
    }

    /// The hover window reports enter/exit. While full tracking is on, `trackMouse` is the authority.
    func hoverChanged(_ inside: Bool) {
        guard moveMonitors.isEmpty else { return }
        setHover(inside)
    }

    func setHover(_ inside: Bool) {
        guard model.hovering != inside else { return }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) { model.hovering = inside }
        hoverOpenTask?.cancel()
        if inside, model.expandOnHover, !model.expanded {
            hoverOpenTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled, self.model.hovering else { return }
                self.model.setExpanded(true, byHover: true)
            }
        } else if !inside, model.expanded, model.openedByHover {
            hoverOpenTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let self, !Task.isCancelled, !self.model.hovering else { return }
                self.model.setExpanded(false)
            }
        }
    }

    /// Keep the hover window exactly over the island's menu-bar strip.
    func syncHoverPanel() {
        guard let screen = targetScreen, let hoverPanel else { return }
        let t = model.topExtent
        let h = model.notch.height
        let f = NSRect(x: screen.frame.midX - t.left, y: screen.frame.maxY - h, width: t.left + t.right, height: h)
        if hoverPanel.frame != f { hoverPanel.setFrame(f, display: false) }
    }

    // MARK: Menu bar item

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.portrait.fill", accessibilityDescription: "Agent Island")
            .map { img in
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                return img.withSymbolConfiguration(cfg) ?? img
            }
        statusItem.button?.imagePosition = .imageLeading
        rebuildMenu()
    }

    func updateStatusTitle() {
        let n = model.activeCount
        statusItem.button?.title = n > 0 ? " \(n)" : ""
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(item(model.expanded ? "Fold Island" : "Unfold Island", #selector(toggleIsland), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Unfold on Hover", #selector(toggleHover), on: model.expandOnHover))
        menu.addItem(item("Hide Idle Agents", #selector(toggleHideIdle), on: model.hideIdle))
        menu.addItem(item("Sounds", #selector(toggleSounds), on: model.playSounds))
        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            menu.addItem(item("Allow Wings Beside the Notch…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(item("Install Claude Code Hooks…", #selector(installClaudeHooks)))
        menu.addItem(item("Open Agent Island Folder", #selector(openFolder)))
        menu.addItem(item("Reload Agent List", #selector(reloadAgents)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Agent Island", #selector(quit), key: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", on: Bool? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let on { i.state = on ? .on : .off }
        return i
    }

    @objc func toggleIsland() { model.toggle() }
    @objc func toggleHover() { model.expandOnHover.toggle() }
    @objc func toggleHideIdle() { model.hideIdle.toggle() }
    @objc func toggleSounds() { model.playSounds.toggle() }
    @objc func reloadAgents() { model.reloadAgents() }
    @objc func quit() { NSApp.terminate(nil) }

    /// Wings beside the notch need to know where menus and status icons are, which only the
    /// Accessibility API can tell. Ask once; without it the island stays inside the notch.
    func askForAccessibilityOnce() {
        guard !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: "askedAccessibility") else { return }
        UserDefaults.standard.set(true, forKey: "askedAccessibility")
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @objc func openAccessibilitySettings() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openFolder() {
        try? FileManager.default.createDirectory(at: IslandPaths.sessions, withIntermediateDirectories: true)
        NSWorkspace.shared.open(IslandPaths.root)
    }

    @objc func installClaudeHooks() {
        let alert = NSAlert()
        alert.messageText = "Install Claude Code hooks?"
        alert.informativeText = "Adds hooks to ~/.claude/settings.json (a backup is saved next to it) so Claude Code reports exact status: thinking, running tools, waiting for permission, finished."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/island")
        let p = Process()
        p.executableURL = cli
        p.arguments = ["install", "claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let result: String
        do {
            try p.run()
            p.waitUntilExit()
            result = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        } catch {
            result = "Could not run \(cli.path): \(error.localizedDescription)"
        }
        let done = NSAlert()
        done.messageText = p.terminationStatus == 0 ? "Hooks installed" : "Install failed"
        done.informativeText = result
        done.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            let hasAXItem = menu.items.contains { $0.action == #selector(openAccessibilitySettings) }
            if hasAXItem && AXIsProcessTrusted() {
                menu.items.filter { $0.action == #selector(openAccessibilitySettings) }.forEach(menu.removeItem)
            }
            rebuildMenuItems(menu)
        }
    }

    private func rebuildMenuItems(_ menu: NSMenu) {
        menu.items.first?.title = model.expanded ? "Fold Island" : "Unfold Island"
        for i in menu.items {
            switch i.action {
            case #selector(toggleHover): i.state = model.expandOnHover ? .on : .off
            case #selector(toggleHideIdle): i.state = model.hideIdle ? .on : .off
            case #selector(toggleSounds): i.state = model.playSounds ? .on : .off
            default: break
            }
        }
    }
}
