import CoreServices
import Darwin
import Foundation
import IslandCore

/// Everything that reads the outside world, on one background queue, driven by events instead of polling:
///
/// * hook files (`~/.agent-island/sessions`) and the agents' own logs (`~/.claude/projects`,
///   `~/.codex/sessions`) are watched with FSEvents, so a change reaches the island in ~20 ms and
///   nothing runs while nothing happens;
/// * the process list (needed for idle sessions and "Go to session") is rescanned on a slow 5 s tick,
///   which also re-checks the log directory as a safety net.
final class Engine: @unchecked Sendable {
    typealias Update = ([AgentProcess], [HookSession], [TranscriptSession]) -> Void

    private let q = DispatchQueue(label: "agent-island.core", qos: .userInitiated)
    private let scanner = ProcessScanner()
    private let logs = TranscriptWatcher()
    private var hooks: [String: HookSession] = [:] // by file path
    private var procs: [AgentProcess] = []
    private var kinds = AgentCatalog.load()
    private var stream: FSEventStreamRef?
    private var ticker: DispatchSourceTimer?
    private var publishScheduled = false
    private let onUpdate: Update

    private static let tick: TimeInterval = 5
    /// Events that arrive within this window are folded into one update.
    private static let coalesce: TimeInterval = 0.002

    /// `onUpdate` is called on the main queue.
    init(onUpdate: @escaping Update) { self.onUpdate = onUpdate }

    func start() {
        q.async { [self] in
            try? FileManager.default.createDirectory(at: IslandPaths.sessions, withIntermediateDirectories: true)
            fullRefresh()
            startEvents()
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .seconds(1))
            t.setEventHandler { [weak self] in self?.fullRefresh() }
            t.resume()
            ticker = t
        }
    }

    func setKinds(_ k: [AgentKind]) { q.async { [self] in kinds = k; fullRefresh() } }

    // MARK: Updates

    private func fullRefresh() {
        procs = scanner.scan(kinds: kinds)
        logs.sweep()
        hooks = [:]
        for f in (try? FileManager.default.contentsOfDirectory(at: IslandPaths.sessions, includingPropertiesForKeys: nil)) ?? [] {
            if let h = SessionFiles.read(url: f) { hooks[f.path] = h }
        }
        publish()
        // Scanning allocates a burst of short-lived objects; give the freed pages back to the system.
        malloc_zone_pressure_relief(nil, 0)
    }

    private func handle(paths: [String]) {
        let sessionsDir = IslandPaths.sessions.path
        var changed = false
        for p in paths {
            if p.hasPrefix(sessionsDir) {
                guard p.hasSuffix(".json") else { continue }
                let new = SessionFiles.read(url: URL(fileURLWithPath: p))
                let old = hooks[p]
                if new?.updatedAt != old?.updatedAt || new?.state != old?.state || new?.message != old?.message { changed = true }
                hooks[p] = new
            } else if logs.apply(paths: [p]) {
                changed = true
            }
        }
        // Most events (log lines that don't change what the island shows) end here, costing nothing more.
        if changed { publishSoon() }
    }

    private func publishSoon() {
        guard !publishScheduled else { return }
        publishScheduled = true
        q.asyncAfter(deadline: .now() + Self.coalesce) { [self] in
            publishScheduled = false
            publish()
        }
    }

    private func publish() {
        let p = procs, h = Array(hooks.values), l = logs.snapshot()
        DispatchQueue.main.async { self.onUpdate(p, h, l) }
    }

    // MARK: File-system events

    private func startEvents() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [IslandPaths.sessions, home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".codex/sessions")]
            .map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let engine = Unmanaged<Engine>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            engine.handle(paths: Array(paths.prefix(count)))
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.001, flags) else { return }
        FSEventStreamSetDispatchQueue(s, q)
        FSEventStreamStart(s)
        stream = s
    }
}
