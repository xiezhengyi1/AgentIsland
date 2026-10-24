import Foundation

public enum AgentState: String, Codable, CaseIterable, Sendable {
    case working, waiting, done, idle, error

    /// Lower sorts first: things that need attention go to the top.
    public var priority: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .error: return 2
        case .done: return 3
        case .idle: return 4
        }
    }

    public var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .done: return "Done"
        case .idle: return "Idle"
        case .error: return "Error"
        }
    }
}

/// A status record written by a hook (or by `island set`) into ~/.agent-island/sessions.
public struct HookSession: Codable, Sendable {
    public var id: String
    public var agent: String
    public var state: AgentState
    public var message: String?
    public var cwd: String?
    public var pid: Int32?
    public var updatedAt: Date
    /// The agent only reports turn ends (e.g. Codex `notify`), never "started working".
    public var turnEndOnly: Bool?

    public init(id: String, agent: String, state: AgentState, message: String?, cwd: String?, pid: Int32?,
                updatedAt: Date = Date(), turnEndOnly: Bool? = nil) {
        self.id = id
        self.agent = agent
        self.state = state
        self.message = message
        self.cwd = cwd
        self.pid = pid
        self.updatedAt = updatedAt
        self.turnEndOnly = turnEndOnly
    }
}

public enum IslandPaths {
    public static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-island")
    public static let sessions = root.appendingPathComponent("sessions")
    public static let bin = root.appendingPathComponent("bin")
    public static let agentsConfig = root.appendingPathComponent("agents.json")
}

public enum SessionFiles {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func url(for id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }
        return IslandPaths.sessions.appendingPathComponent(String(safe) + ".json")
    }

    public static func write(_ session: HookSession) throws {
        try FileManager.default.createDirectory(at: IslandPaths.sessions, withIntermediateDirectories: true)
        try encoder.encode(session).write(to: url(for: session.id), options: .atomic)
    }

    public static func read(id: String) -> HookSession? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? decoder.decode(HookSession.self, from: data)
    }

    public static func remove(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    public static func read(url: URL) -> HookSession? {
        guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(HookSession.self, from: data)
    }

    public static func readAll() -> [HookSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: IslandPaths.sessions, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(HookSession.self, from: data)
        }
    }
}
