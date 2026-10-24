import AppKit
import Darwin
@preconcurrency import IslandCore
import SwiftUI

struct AgentEntry: Identifiable, Equatable {
    var id: String
    var kind: AgentKind
    var state: AgentState
    var message: String?
    var cwd: String?
    var pid: pid_t?
    var since: Date
    var fromHook: Bool
    /// When the hook last wrote this session (nil for process-only entries).
    var reportedAt: Date? = nil

    /// What the user can see. `reportedAt` is bookkeeping and must not trigger a redraw by itself.
    static func == (a: AgentEntry, b: AgentEntry) -> Bool {
        a.id == b.id && a.kind == b.kind && a.state == b.state && a.message == b.message &&
            a.cwd == b.cwd && a.pid == b.pid && a.since == b.since && a.fromHook == b.fromHook
    }

    var folder: String? {
        guard let cwd, cwd != "/" else { return nil }
        return (cwd as NSString).lastPathComponent
    }
}

struct Flash: Equatable {
    var entry: AgentEntry
    var token = UUID()
}

struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool

    static func of(_ screen: NSScreen) -> NotchMetrics {
        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return NotchMetrics(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top, hasNotch: true)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchMetrics(width: 0, height: max(26, min(menuBar, 32)), hasNotch: false)
    }
}

@MainActor
final class IslandModel: ObservableObject {
    @Published private(set) var entries: [AgentEntry] = []
    @Published var expanded = false
    @Published var hovering = false
    @Published var hoveredRow: String?
    @Published private(set) var flash: Flash?
    /// Attention cards the user already clicked or closed, keyed by session + report time.
    @Published private var dismissed: Set<String> = []
    @Published var notch = NotchMetrics(width: 0, height: 30, hasNotch: false)
    /// Free menu-bar space beside the notch; nil = unknown (no Accessibility permission).
    @Published var free: MenuBarSpace.Free?
    /// Where the notch / menu bar is, set by the app delegate when it places the window.
    var screenGeometry: MenuBarSpace.Request?

    @Published var expandOnHover = UserDefaults.standard.bool(forKey: "expandOnHover") {
        didSet { UserDefaults.standard.set(expandOnHover, forKey: "expandOnHover") }
    }
    @Published var hideIdle = UserDefaults.standard.bool(forKey: "hideIdle") {
        didSet { UserDefaults.standard.set(hideIdle, forKey: "hideIdle") }
    }
    @Published var playSounds = UserDefaults.standard.object(forKey: "playSounds") as? Bool ?? true {
        didSet { UserDefaults.standard.set(playSounds, forKey: "playSounds") }
    }

    /// True when the island was opened by hovering, so leaving folds it again.
    var openedByHover = false

    private var engine: Engine?
    private let menuQueue = DispatchQueue(label: "agent-island.menus", qos: .userInteractive)
    private let statusQueue = DispatchQueue(label: "agent-island.status-items", qos: .utility)
    private var appMenuFrames: [CGRect] = []
    private var statusItems: [pid_t: [CGRect]] = [:]
    private var lastFullStatusSweep = Date.distantPast
    private var statusSweepRunning = false
    private var kinds = AgentCatalog.load()
    private var lastBusy: [String: Date] = [:]
    private var cpuAvg: [pid_t: Double] = [:]
    private var known: [String: (state: AgentState, since: Date)] = [:]
    private var lastReport: [String: Date] = [:]
    private var flashTask: Task<Void, Never>?
    private var statusTimer: Timer?

    static let cpuBusyThreshold = 3.0

    var visibleEntries: [AgentEntry] {
        hideIdle ? entries.filter { $0.state != .idle } : entries
    }

    static func attentionKey(_ e: AgentEntry) -> String { "\(e.id)|\(e.reportedAt?.timeIntervalSince1970 ?? 0)" }

    /// A session that needs you (permission prompt, error). Its card stays until you act on it or the
    /// agent moves on, unlike the short "finished" banner.
    var attention: AgentEntry? {
        entries.first { ($0.state == .waiting || $0.state == .error) && !dismissed.contains(Self.attentionKey($0)) }
    }

    /// How many other sessions are also waiting for you.
    var moreAttention: Int {
        entries.filter { ($0.state == .waiting || $0.state == .error) && !dismissed.contains(Self.attentionKey($0)) }.count - 1
    }

    /// What drops down under the notch while folded.
    var popup: Flash? { attention.map { Flash(entry: $0) } ?? flash }

    func dismissAttention(_ e: AgentEntry) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { _ = dismissed.insert(Self.attentionKey(e)) }
    }

    var activeCount: Int { entries.filter { $0.state == .working || $0.state == .waiting }.count }
    var leadEntry: AgentEntry? { entries.first }

    // MARK: Geometry (SwiftUI points; island hangs from the top centre of the screen)

    static let flare: CGFloat = 6
    static let rowHeight: CGFloat = 54
    static var maxRows = 6
    static let chinHeight: CGFloat = 22
    static let headerHeight: CGFloat = 34

    /// Room left between the island and the nearest menu item.
    static let menuGap: CGFloat = 8
    static let minWing: CGFloat = 24

    /// Side wings in the menu bar, each limited to the measured free space so no menu title or
    /// status icon is covered. (0, 0) means "stay inside the notch" and use the chin instead.
    var wings: (left: CGFloat, right: CGFloat) {
        guard let free else { return (0, 0) }
        let base: CGFloat = activeCount > 0 ? 44 : (entries.isEmpty ? 26 : 34)
        let want = base + (hovering && !expanded ? 6 : 0)
        func fit(_ want: CGFloat, _ room: CGFloat) -> CGFloat {
            room >= want ? want : (room >= Self.minWing ? room : 0)
        }
        let roomL = free.left - Self.menuGap, roomR = free.right - Self.menuGap
        var l = fit(want, roomL), r = fit(want, roomR)
        // Only one side has room: it carries both the indicator and the count.
        if l == 0, r > 0 { r = fit(want + 20, roomR) }
        if r == 0, l > 0 { l = fit(want + 20, roomL) }
        return (l, r)
    }

    var hasWings: Bool { wings.left > 0 || wings.right > 0 }

    /// Distance from the notch centre to each edge of the menu-bar part.
    var topExtent: (left: CGFloat, right: CGFloat) {
        let half = notch.hasNotch ? notch.width / 2 : 0
        let w = wings
        if !notch.hasNotch && w.left == 0 && w.right == 0 { return (60, 60) }
        return (half + w.left, half + w.right)
    }

    /// Small status strip under the notch, used when there's no room for wings.
    var showsChin: Bool { !hasWings && (activeCount > 0 || hovering) }

    /// Width of the part below the menu bar (centred on the notch).
    var bodyWidth: CGFloat {
        let t = topExtent
        let minimum = 2 * max(t.left, t.right)
        if expanded { return max(minimum, notch.width + 240, 460) }
        if popup != nil { return max(minimum, 400) }
        return notch.hasNotch ? notch.width : 2 * t.left
    }

    var islandSize: CGSize {
        let t = topExtent
        let topW = 2 * max(t.left, t.right) + 2 * Self.flare
        let bodyW = bodyWidth + 2 * Self.flare
        if expanded {
            let rows = visibleEntries.count
            let list = rows == 0 ? 70 : CGFloat(min(rows, Self.maxRows)) * Self.rowHeight
            return CGSize(width: bodyW, height: notch.height + Self.headerHeight + 1 + list + 10)
        }
        if popup != nil { return CGSize(width: bodyW, height: notch.height + 46) }
        if showsChin { return CGSize(width: max(topW, bodyW), height: notch.height + Self.chinHeight) }
        return CGSize(width: topW, height: notch.height)
    }

    /// The black areas, in island coordinates (origin top-left), used for click-through.
    var hitRects: [CGRect] {
        let s = islandSize, t = topExtent
        var rects = [CGRect(x: s.width / 2 - t.left, y: 0, width: t.left + t.right, height: notch.height)]
        if s.height > notch.height {
            rects.append(CGRect(x: (s.width - bodyWidth) / 2, y: notch.height, width: bodyWidth, height: s.height - notch.height))
        }
        return rects
    }

    // MARK: Lifecycle

    func start() {
        let e = Engine { [weak self] procs, hooks, logs in
            MainActor.assumeIsolated { self?.merge(procs: procs, hooks: hooks, logs: logs) }
        }
        engine = e
        e.start()
        remeasureMenus()
        refreshStatusItems(full: true)
        // Slow safety net for menu-bar icons (they also re-measure on app switches and menu-bar clicks).
        statusTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.remeasureMenus()
                self?.refreshStatusItems(full: false)
            }
        }
        statusTimer?.tolerance = 15
    }

    /// An app came to the front: its menus may be wider or narrower, and we may just have been allowed
    /// to read them.
    func appActivated(pid: pid_t?) {
        remeasureMenus(frontmost: pid)
        if statusItems.isEmpty { refreshStatusItems(full: true) }
    }

    func toggle() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            expanded.toggle()
            openedByHover = false
            if expanded { flash = nil }
        }
    }

    func setExpanded(_ value: Bool, byHover: Bool = false) {
        guard expanded != value else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            expanded = value
            openedByHover = value && byHover
            if value { flash = nil }
        }
    }

    func dismiss(_ entry: AgentEntry) {
        if entry.fromHook { SessionFiles.remove(id: entry.id) }
        entries.removeAll { $0.id == entry.id }
    }

    func reloadAgents() { kinds = AgentCatalog.load(); engine?.setKinds(kinds) }

    func navigate(to entry: AgentEntry) {
        Navigator.go(to: entry)
        dismissAttention(entry)
        flash = nil
        setExpanded(false)
    }

    func debugAttention(_ e: AgentEntry?) {
        entries = e.map { [$0] + entries.filter { $0.id != e?.id } } ?? entries.filter { $0.state != .waiting }
    }

    func debugFlash(_ entry: AgentEntry?) { flash = entry.map { Flash(entry: $0) } }

    // MARK: Menu-bar space
    //
    // Two speeds: the frontmost app's menus take ~4 ms and are re-read on every app switch on their
    // own high-priority queue; status icons take 1–2 s across all apps, so only those near the notch
    // are re-read each second and a full sweep runs in the background every 15 s.

    /// Re-read the frontmost app's menus now. Pass the pid from an activation notification when known.
    func remeasureMenus(frontmost pid: pid_t? = nil) {
        guard screenGeometry != nil, AXIsProcessTrusted() else {
            if free != nil { free = nil }
            return
        }
        guard let pid = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        menuQueue.async {
            let menus = MenuBarSpace.appMenuFrames(pid: pid)
            DispatchQueue.main.async {
                self.appMenuFrames = menus
                self.applyFree()
            }
        }
    }

    /// Re-read status icons: only apps near the notch, or every app when `full` (launch/quit, every 15 s).
    func refreshStatusItems(full: Bool) {
        guard let geo = screenGeometry, AXIsProcessTrusted(), !statusSweepRunning else { return }
        let isFull = full || lastFullStatusSweep == .distantPast
        let pids: [pid_t]
        if isFull {
            pids = MenuBarSpace.candidatePIDs()
            lastFullStatusSweep = Date()
        } else {
            pids = statusItems.filter { $0.value.contains(where: geo.isNearNotch) }.map(\.key)
            if pids.isEmpty { return }
        }
        statusSweepRunning = true
        statusQueue.async {
            let found = MenuBarSpace.statusItemFrames(pids: pids)
            DispatchQueue.main.async {
                if isFull {
                    self.statusItems = found
                } else {
                    for pid in pids { self.statusItems[pid] = found[pid] }
                }
                self.statusSweepRunning = false
                self.applyFree()
                if isFull { malloc_zone_pressure_relief(nil, 0) }
            }
        }
    }

    private func applyFree() {
        guard let geo = screenGeometry else { return }
        let f = MenuBarSpace.free(geo, frames: appMenuFrames + statusItems.values.flatMap { $0 })
        if f != free {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) { free = f }
        }
    }

    private func merge(procs: [AgentProcess], hooks: [HookSession], logs: [TranscriptSession]) {
        let now = Date()
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        // Smooth CPU: idle agents blip to a few % (timers, GC); real work is sustained.
        var avg: [pid_t: Double] = [:]
        for p in procs {
            let a = 0.5 * (cpuAvg[p.pid] ?? 0) + 0.5 * p.cpu
            avg[p.pid] = a
            if a > Self.cpuBusyThreshold { lastBusy["pid-\(p.pid)"] = now }
        }
        cpuAvg = avg
        func busy(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
            guard let t = lastBusy["pid-\(pid)"] else { return false }
            return now.timeIntervalSince(t) < seconds
        }

        var next: [AgentEntry] = []
        var claimed = Set<pid_t>()

        // Every session the island knows is identified as "<agent>-<session id>", whether it came from a
        // hook, from the agent's own log, or both. When both exist the newer report wins.
        let logByID = Dictionary(logs.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
        var hookIDs = Set<String>()

        func entry(from l: TranscriptSession, pid: pid_t?) -> AgentEntry {
            var state = l.state, message = l.message
            // A turn that went quiet for minutes was most likely cut off without a closing event.
            if state == .working, now.timeIntervalSince(l.updatedAt) > 300 { state = .idle; message = "No activity for 5 min" }
            let kind = AgentCatalog.kind(id: l.agent, in: kinds)
            return AgentEntry(id: l.id, kind: kind, state: state, message: message, cwd: l.cwd, pid: pid,
                              since: now, fromHook: false, reportedAt: l.updatedAt)
        }

        for h in hooks {
            let age = now.timeIntervalSince(h.updatedAt)
            if let pid = h.pid {
                if !Proc.isAlive(pid) { SessionFiles.remove(id: h.id); continue }
                claimed.insert(pid)
            } else if age > (h.state == .working || h.state == .waiting ? 7200 : 900) {
                SessionFiles.remove(id: h.id)
                continue
            }
            hookIDs.insert(h.id)
            if let l = logByID[h.id], l.updatedAt > h.updatedAt.addingTimeInterval(0.5) {
                next.append(entry(from: l, pid: h.pid))
                continue
            }
            var state = h.state
            var message = h.message
            if let pid = h.pid, byPid[pid] != nil {
                // Interrupted (Esc / Ctrl-C) turns never send Stop: decay a stale "working".
                if state == .working, age > 300, !busy(pid, within: 120) { state = .idle; message = "Interrupted?" }
            }
            let kind = AgentCatalog.kind(id: h.agent, in: kinds)
            next.append(AgentEntry(id: h.id, kind: kind, state: state, message: message,
                                   cwd: h.cwd ?? h.pid.flatMap { byPid[$0]?.cwd }, pid: h.pid, since: now, fromHook: true,
                                   reportedAt: h.updatedAt))
        }

        // Sessions seen only in logs (no hook): attach a live process with the same folder when there
        // is one, so "Go to session" works and its idle row isn't listed twice.
        for l in logs where !hookIDs.contains(l.id) {
            var pid: pid_t?
            if let cwd = l.cwd {
                let candidates = procs.filter { $0.kind.id == l.agent && !claimed.contains($0.pid) && $0.cwd == cwd }
                // Desktop chats are served by one shared helper process; CLIs have their own.
                let pick = candidates.first(where: { !$0.isHelper }) ?? (l.originator != nil ? procs.first { $0.kind.id == l.agent && $0.isHelper } : nil)
                if let pick { pid = pick.pid; if !pick.isHelper { claimed.insert(pick.pid) } }
            } else if l.originator != nil {
                pid = procs.first { $0.kind.id == l.agent && $0.isHelper }?.pid
            }
            next.append(entry(from: l, pid: pid))
        }

        for p in procs where !claimed.contains(p.pid) && !p.isHelper {
            let working = busy(p.pid, within: 7)
            next.append(AgentEntry(id: "pid-\(p.pid)", kind: p.kind, state: working ? .working : .idle,
                                   message: working ? "Working…" : nil,
                                   cwd: p.cwd, pid: p.pid, since: now, fromHook: false))
        }

        // Keep "since" stable per state, and alert only on fresh hook reports. CPU-derived changes
        // never alert: CPU flickers, and that used to replay "finished" over and over.
        var announce: AgentEntry?
        for i in next.indices {
            let e = next[i]
            let freshReport = e.reportedAt != nil && e.reportedAt != lastReport[e.id]
            if let r = e.reportedAt { lastReport[e.id] = r }
            guard let old = known[e.id] else {
                known[e.id] = (e.state, now) // first sighting (e.g. app just started): no alert
                continue
            }
            if old.state == e.state {
                next[i].since = old.since
                continue
            }
            if freshReport {
                let alert = e.state == .waiting || e.state == .error ||
                    (e.state == .done && (old.state == .working || old.state == .waiting))
                if alert, announce == nil || e.state == .waiting { announce = e }
            }
            known[e.id] = (e.state, now)
            next[i].since = now
        }
        let live = Set(next.map(\.id))
        known = known.filter { live.contains($0.key) }
        lastReport = lastReport.filter { live.contains($0.key) }
        lastBusy = lastBusy.filter { now.timeIntervalSince($0.value) < 600 }

        next.sort {
            ($0.state.priority, $1.since, $0.kind.name) < ($1.state.priority, $0.since, $1.kind.name)
        }
        if next != entries {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { entries = next }
        }
        if let announce { show(announce) }
    }

    private func show(_ entry: AgentEntry) {
        if playSounds {
            NSSound(named: entry.state == .waiting ? "Funk" : (entry.state == .error ? "Basso" : "Glass"))?.play()
        }
        // Permission prompts and errors get the sticky card (`attention`); only "finished" is timed.
        guard entry.state == .done, !expanded else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { flash = Flash(entry: entry) }
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { self?.flash = nil }
        }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0x9AA0A6
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
