import Foundation

/// Status read straight from the session logs Claude Code and Codex write while they run
/// (`~/.claude/projects/*/<session>.jsonl`, `~/.codex/sessions/**/rollout-*.jsonl`).
/// Works for the CLIs and the desktop apps alike, with no hooks needed, and sees a turn *start*,
/// which Codex's `notify` hook never reports.
public struct TranscriptSession: Sendable, Equatable {
    public var id: String // "<agent>-<session id>", same scheme as hook sessions
    public var agent: String
    public var state: AgentState
    public var message: String?
    public var cwd: String?
    /// Time of the last meaningful event in the log.
    public var updatedAt: Date
    /// Where it runs, e.g. "Codex Desktop" (nil for the CLIs).
    public var originator: String?
}

/// Reads only the bytes appended since the last scan, so scanning stays cheap even though a single
/// Codex log line (tool output) can be several MB.
public final class TranscriptWatcher {
    private struct FileState {
        var offset: UInt64 = 0 // bytes consumed so far
        var session: TranscriptSession
        var lastText: String? // Claude: latest assistant text, used as the "done" message
        var mtime: Date
    }

    private var files: [String: FileState] = [:]
    private let window: TimeInterval
    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// `window`: only logs written to within this many seconds are tracked.
    public init(window: TimeInterval = 15 * 60) { self.window = window }

    /// Not thread-safe: use from one queue.

    /// Full pass: find new files, drop old ones. Cheap (a few dozen `stat`s), so it also serves as the
    /// safety net behind file-system events.
    public func sweep(now: Date = Date()) {
        var seen = Set<String>()
        for (path, mtime) in candidateFiles() where now.timeIntervalSince(mtime) < window {
            seen.insert(path)
            update(path: path, mtime: mtime)
        }
        files = files.filter { seen.contains($0.key) }
    }

    /// Fast path for file-system events: re-read just these files.
    /// Returns whether any session's visible state changed.
    @discardableResult
    public func apply(paths: [String], now: Date = Date()) -> Bool {
        var changed = false
        for path in paths where path.hasSuffix(".jsonl") && isLogPath(path) {
            let before = files[path]?.session
            if let m = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                if now.timeIntervalSince(m) < window { update(path: path, mtime: m) }
            } else {
                files[path] = nil // deleted
            }
            if files[path]?.session != before { changed = true }
        }
        return changed
    }

    public func snapshot(now: Date = Date()) -> [TranscriptSession] {
        files.values.map(\.session).filter { now.timeIntervalSince($0.updatedAt) < window }
    }

    private func isLogPath(_ path: String) -> Bool {
        if path.contains("/.codex/sessions/") { return (path as NSString).lastPathComponent.hasPrefix("rollout-") }
        // ~/.claude/projects/<project>/<session>.jsonl only (not sub-agent logs deeper down)
        guard let r = path.range(of: "/.claude/projects/") else { return false }
        return path[r.upperBound...].split(separator: "/").count == 2
    }

    // MARK: Discovery

    private func candidateFiles() -> [(String, Date)] {
        let fm = FileManager.default
        var out: [(String, Date)] = []
        func add(_ url: URL) {
            guard url.pathExtension == "jsonl",
                  let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return }
            out.append((url.path, m))
        }
        let claude = home.appendingPathComponent(".claude/projects")
        for dir in (try? fm.contentsOfDirectory(at: claude, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { add(f) }
        }
        let codex = home.appendingPathComponent(".codex/sessions")
        if let e = fm.enumerator(at: codex, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in e where url.lastPathComponent.hasPrefix("rollout-") { add(url) }
        }
        return out
    }

    // MARK: Incremental reading

    /// Read what was appended since last time. First sight reads a small tail and widens it only if no
    /// status event is in it, so a quiet chat costs ~256 KB instead of megabytes of tool output.
    private func update(path: String, mtime: Date) {
        let isCodex = path.contains("/.codex/")
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        if var state = files[path] {
            state.mtime = mtime
            if state.offset == size { files[path] = state; return }
            var start = size < state.offset ? 0 : state.offset
            var cut = false
            let cap: UInt64 = isCodex ? 12_000_000 : 3_000_000
            if size - start > cap { start = size - cap; cut = true }
            consume(handle, from: start, size: size, cut: cut, isCodex: isCodex, into: &state)
            files[path] = state
            return
        }

        var state = FileState(session: makeSession(path: path, isCodex: isCodex, handle: handle, mtime: mtime), mtime: mtime)
        var chunk: UInt64 = 256_000
        let cap: UInt64 = isCodex ? 12_000_000 : 3_000_000
        while true {
            let start = size > chunk ? size - chunk : 0
            var trial = state
            consume(handle, from: start, size: size, cut: start > 0, isCodex: isCodex, into: &trial)
            state = trial
            if state.session.updatedAt != .distantPast || start == 0 || chunk >= cap { break }
            chunk *= 4
        }
        files[path] = state
    }

    /// Parse bytes [start, size) of the file into `st`. `cut`: `start` may be mid-line.
    private func consume(_ handle: FileHandle, from start: UInt64, size: UInt64, cut: Bool, isCodex: Bool, into st: inout FileState) {
        guard (try? handle.seek(toOffset: start)) != nil, var region = try? handle.readToEnd(), !region.isEmpty else { return }
        var consumedTo = size
        if let lastNL = region.lastIndex(of: 0x0A) {
            consumedTo = start + UInt64(lastNL + 1)
            region = region.prefix(upTo: lastNL + 1)
        } else if size - start < 8_000_000 { // one unfinished line: wait for the rest
            if cut { st.offset = size }
            return
        }
        if cut, let nl = region.firstIndex(of: 0x0A) { region = region.suffix(from: nl + 1) } // started mid-line
        if isCodex { readCodex(region, into: &st) } else { readClaude(region, into: &st) }
        st.offset = consumedTo
    }

    private func makeSession(path: String, isCodex: Bool, handle: FileHandle, mtime: Date) -> TranscriptSession {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if !isCodex {
            return TranscriptSession(id: "claude-\(name)", agent: "claude", state: .idle, message: nil, cwd: nil,
                                     updatedAt: .distantPast, originator: nil)
        }
        // rollout-<timestamp>-<uuid>; the first line (session_meta) has the real id, cwd and originator.
        var id = String(name.suffix(36))
        var cwd: String?, originator: String?
        try? handle.seek(toOffset: 0)
        if let head = try? handle.read(upToCount: 600_000), let nl = head.firstIndex(of: 0x0A),
           let obj = (try? JSONSerialization.jsonObject(with: head.prefix(upTo: nl))) as? [String: Any],
           let p = obj["payload"] as? [String: Any] {
            id = (p["id"] as? String) ?? id
            cwd = p["cwd"] as? String
            originator = p["originator"] as? String
        }
        return TranscriptSession(id: "codex-\(id)", agent: "codex", state: .idle, message: nil, cwd: cwd,
                                 updatedAt: .distantPast, originator: originator)
    }

    // MARK: Codex

    private static let codexMarkers: [(String, AgentState)] = [
        (#""type":"task_started""#, .working),
        (#""type":"task_complete""#, .done),
        (#""type":"turn_aborted""#, .idle),
    ]

    /// Codex marks every turn with task_started / task_complete / turn_aborted. Search for those
    /// markers as bytes and parse only the one line that matters.
    private func readCodex(_ region: Data, into st: inout FileState) {
        var best: (pos: Int, state: AgentState)?
        for (needle, state) in Self.codexMarkers {
            if let r = region.range(of: Data(needle.utf8), options: .backwards), r.lowerBound > (best?.pos ?? -1) {
                best = (r.lowerBound, state)
            }
        }
        guard let best else { return }
        let line = Self.line(in: region, around: best.pos)
        let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let payload = obj?["payload"] as? [String: Any]
        let ts = (obj?["timestamp"] as? String).flatMap(Self.parseDate) ?? st.mtime

        st.session.state = best.state
        st.session.updatedAt = ts
        switch best.state {
        case .done:
            let last = (payload?["last_agent_message"] as? String).map { HookMapper.oneLine($0, 90) }
            st.session.message = last ?? "Finished"
        case .idle:
            st.session.message = "Interrupted"
        default:
            st.session.message = "Working…"
            // The agent's latest commentary in this turn makes a better status line.
            if let r = region.range(of: Data(#""type":"agent_message""#.utf8), options: .backwards), r.lowerBound > best.pos,
               let o = (try? JSONSerialization.jsonObject(with: Self.line(in: region, around: r.lowerBound))) as? [String: Any],
               let text = (o["payload"] as? [String: Any])?["message"] as? String {
                st.session.message = HookMapper.oneLine(text, 90)
            }
        }
    }

    private static func line(in data: Data, around pos: Int) -> Data {
        let s = data.startIndex
        var a = pos
        while a > s, data[a - 1] != 0x0A { a -= 1 }
        var b = pos
        while b < data.endIndex, data[b] != 0x0A { b += 1 }
        return data.subdata(in: a..<b)
    }

    // MARK: Claude Code

    private func readClaude(_ region: Data, into st: inout FileState) {
        for lineData in region.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if lineData.count > 1_000_000 {
                // A huge line is almost always a tool result: the turn is still going.
                if lineData.prefix(4_000).range(of: Data(#""type":"user""#.utf8)) != nil { st.session.state = .working }
                continue
            }
            guard let o = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  let type = o["type"] as? String else { continue }
            if let cwd = o["cwd"] as? String { st.session.cwd = cwd }
            if o["isSidechain"] as? Bool == true { continue }
            let ts = (o["timestamp"] as? String).flatMap(Self.parseDate)
            let msg = o["message"] as? [String: Any]
            let blocks = msg?["content"] as? [[String: Any]]

            switch type {
            case "assistant":
                var tool: String?
                for b in blocks ?? [] {
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String, !t.isEmpty { st.lastText = HookMapper.oneLine(t, 90) }
                    case "tool_use":
                        tool = HookMapper.toolMessage(["tool_name": b["name"] ?? "tool", "tool_input": b["input"] ?? [:]])
                    default: break
                    }
                }
                let stop = msg?["stop_reason"] as? String
                if stop == "end_turn" || stop == "stop_sequence" || stop == "max_tokens" {
                    st.session.state = .done
                    st.session.message = st.lastText ?? "Finished"
                } else {
                    st.session.state = .working
                    st.session.message = tool ?? st.session.message ?? "Thinking…"
                }
            case "user":
                if o["isMeta"] as? Bool == true { continue }
                if blocks?.contains(where: { $0["type"] as? String == "tool_result" }) == true {
                    st.session.state = .working
                } else {
                    var text = msg?["content"] as? String
                    if text == nil { text = blocks?.compactMap { $0["text"] as? String }.joined(separator: " ") }
                    let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.hasPrefix("<command-") || t.hasPrefix("<local-command") || t.hasPrefix("<system-reminder") ||
                        t.hasPrefix("Caveat:") || t.isEmpty { continue }
                    if t.hasPrefix("[Request interrupted") {
                        st.session.state = .idle
                        st.session.message = "Interrupted"
                    } else {
                        st.lastText = nil
                        st.session.state = .working
                        st.session.message = "“" + HookMapper.oneLine(t, 70) + "”"
                    }
                }
            case "system":
                guard o["subtype"] as? String == "stop_hook_summary" else { continue }
                st.session.state = .done // the turn is over; its text was captured above
                st.session.message = st.lastText ?? st.session.message ?? "Finished"
            default:
                continue
            }
            if let ts { st.session.updatedAt = ts }
        }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }
}
