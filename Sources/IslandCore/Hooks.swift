import Foundation

/// Turns a hook payload (Claude Code / Gemini CLI style on stdin, or a Codex `notify` JSON arg)
/// into a status update.
public enum HookMapper {
    public enum Outcome {
        case update(state: AgentState, message: String?)
        case remove
        case ignore
    }

    public static func outcome(for payload: [String: Any]) -> Outcome {
        let event = ((payload["hook_event_name"] ?? payload["type"]) as? String ?? "").lowercased()
        switch event {
        case "userpromptsubmit", "beforeagent":
            let prompt = (payload["prompt"] as? String).map { "“" + oneLine($0, 70) + "”" }
            return .update(state: .working, message: prompt ?? "Thinking…")
        case "pretooluse", "beforetool":
            return .update(state: .working, message: toolMessage(payload))
        case "posttooluse", "aftertool", "subagentstart", "subagentstop", "precompact", "beforemodel":
            return .update(state: .working, message: nil)
        case "notification":
            let msg = payload["message"] as? String
            let type = (payload["notification_type"] as? String ?? "").lowercased()
            // "waiting for your input" after a finished turn isn't an alert.
            if type == "idle_prompt" || (msg?.lowercased().contains("waiting for your input") ?? false) {
                return .update(state: .idle, message: msg)
            }
            return .update(state: .waiting, message: msg ?? "Needs your attention")
        case "permissionrequest":
            return .update(state: .waiting, message: "Permission: " + (payload["tool_name"] as? String ?? "tool"))
        case "stop", "afteragent", "agent-turn-complete":
            let last = (payload["last-assistant-message"] ?? payload["last_assistant_message"]) as? String
            if let last, isBackgroundSuggestion(last) { return .ignore }
            return .update(state: .done, message: last.map { oneLine($0, 90) } ?? "Finished")
        case "stopfailure":
            return .update(state: .error, message: (payload["error"] as? String).map { oneLine($0, 90) } ?? "Failed")
        case "sessionstart":
            return .update(state: .idle, message: "Session started")
        case "sessionend":
            return .remove
        default:
            return .ignore
        }
    }

    /// Codex runs hidden helper threads that write "next question" suggestions and report each as a
    /// finished turn. They are not chats and must not show up or alert.
    static func isBackgroundSuggestion(_ message: String) -> Bool {
        guard message.hasPrefix("{"), let data = message.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj.keys.contains("suggestion") && obj.count <= 2
    }

    public static func sessionID(_ payload: [String: Any]) -> String? {
        for key in ["session_id", "sessionId", "thread-id", "thread_id", "conversation_id"] {
            if let s = payload[key] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    static func toolMessage(_ payload: [String: Any]) -> String {
        let tool = payload["tool_name"] as? String ?? "tool"
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        if let cmd = input["command"] as? String { return "$ " + oneLine(cmd, 70) }
        for key in ["file_path", "path", "notebook_path"] {
            if let p = input[key] as? String { return "\(tool) \((p as NSString).lastPathComponent)" }
        }
        if let pattern = input["pattern"] as? String { return "\(tool) \(oneLine(pattern, 50))" }
        if let url = input["url"] as? String { return "\(tool) \(oneLine(url, 60))" }
        if let desc = input["description"] as? String { return "\(tool): \(oneLine(desc, 60))" }
        return tool
    }

    public static func oneLine(_ s: String, _ max: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}
