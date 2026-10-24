import Foundation

/// Describes one kind of coding agent and how to recognise its process.
public struct AgentKind: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    /// Hex colour, e.g. "#D97757".
    public var color: String
    /// Executable basenames, e.g. "claude".
    public var binaries: [String]
    /// Substrings matched against the first arguments of node/python/bun processes,
    /// for agents installed as scripts (e.g. "@google/gemini-cli").
    public var argPatterns: [String]
    /// Executable paths containing any of these are app-embedded helpers (e.g. the Codex server inside
    /// ChatGPT.app), not sessions: they are never listed on their own, only used for CPU and as the
    /// owner of hook-reported sessions.
    public var helperPaths: [String]?

    public init(id: String, name: String, symbol: String, color: String, binaries: [String],
                argPatterns: [String] = [], helperPaths: [String]? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
        self.binaries = binaries
        self.argPatterns = argPatterns
        self.helperPaths = helperPaths
    }
}

public enum AgentCatalog {
    public static let builtIn: [AgentKind] = [
        AgentKind(id: "claude", name: "Claude Code", symbol: "asterisk", color: "#D97757",
                  binaries: ["claude"], argPatterns: ["@anthropic-ai/claude-code"]),
        AgentKind(id: "codex", name: "Codex", symbol: "terminal.fill", color: "#7FD8BE",
                  binaries: ["codex"], argPatterns: ["@openai/codex"], helperPaths: ["/ChatGPT.app/", "/Codex.app/"]),
        AgentKind(id: "gemini", name: "Gemini CLI", symbol: "sparkles", color: "#4C8DF6",
                  binaries: ["gemini"], argPatterns: ["@google/gemini-cli", "/bin/gemini"]),
        AgentKind(id: "copilot", name: "Copilot CLI", symbol: "airplane", color: "#A371F7",
                  binaries: ["copilot"], argPatterns: ["@github/copilot"]),
        AgentKind(id: "cursor", name: "Cursor Agent", symbol: "cursorarrow.rays", color: "#D0D0D0",
                  binaries: ["cursor-agent"], argPatterns: ["cursor-agent"]),
        AgentKind(id: "opencode", name: "OpenCode", symbol: "chevron.left.forwardslash.chevron.right", color: "#F5A623",
                  binaries: ["opencode"], argPatterns: ["opencode-ai"]),
        AgentKind(id: "aider", name: "Aider", symbol: "wand.and.stars", color: "#3DDC84",
                  binaries: ["aider"], argPatterns: ["/bin/aider", "aider-chat"]),
        AgentKind(id: "amp", name: "Amp", symbol: "bolt.fill", color: "#F34E3F",
                  binaries: ["amp"], argPatterns: ["@sourcegraph/amp"]),
        AgentKind(id: "qwen", name: "Qwen Code", symbol: "q.circle.fill", color: "#7B73F0",
                  binaries: ["qwen"], argPatterns: ["@qwen-code/qwen-code"]),
        AgentKind(id: "goose", name: "Goose", symbol: "bird.fill", color: "#FFD84D",
                  binaries: ["goose"]),
    ]

    /// Built-ins plus anything in ~/.agent-island/agents.json (same shape as AgentKind; same id overrides).
    public static func load() -> [AgentKind] {
        var kinds = builtIn
        if let data = try? Data(contentsOf: IslandPaths.agentsConfig),
           let custom = try? JSONDecoder().decode([AgentKind].self, from: data) {
            for k in custom {
                if let i = kinds.firstIndex(where: { $0.id == k.id }) { kinds[i] = k } else { kinds.append(k) }
            }
        }
        return kinds
    }

    /// Kind for an id reported by a hook; unknown ids get a generic look.
    public static func kind(id: String, in kinds: [AgentKind]) -> AgentKind {
        if let k = kinds.first(where: { $0.id == id }) { return k }
        return AgentKind(id: id, name: id.prefix(1).uppercased() + id.dropFirst(), symbol: "cpu", color: "#9AA0A6", binaries: [])
    }

    static let interpreters: Set<String> = ["node", "bun", "deno", "ruby", "python", "python3", "Python"]

    /// Which agent (if any) a process is.
    public static func match(path: String, pid: pid_t, kinds: [AgentKind]) -> AgentKind? {
        let name = (path as NSString).lastPathComponent
        if let k = kinds.first(where: { $0.binaries.contains(name) }) { return k }
        guard interpreters.contains(name) || name.hasPrefix("python") else { return nil }
        // Only look at the script / first couple of args so `node server.js --gemini` doesn't match.
        let args = Proc.arguments(pid).dropFirst().prefix(3).joined(separator: " ")
        guard !args.isEmpty else { return nil }
        return kinds.first { k in k.argPatterns.contains { args.contains($0) } }
    }
}
