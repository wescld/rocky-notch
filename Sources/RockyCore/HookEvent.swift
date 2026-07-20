import Foundation

/// A decoded hook event from an agent CLI (Claude Code schema).
/// Decoding is tolerant: unknown event names and missing optional fields
/// never fail — the app degrades to showing less detail, not crashing.
public struct HookEvent: Codable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case sessionStart
        case sessionEnd
        case stop
        case notification
        case permissionRequest
        case userPromptSubmit
        case unknown(String)

        public init(name: String) {
            switch name {
            case "SessionStart": self = .sessionStart
            case "SessionEnd": self = .sessionEnd
            case "Stop": self = .stop
            case "Notification": self = .notification
            case "PermissionRequest": self = .permissionRequest
            case "UserPromptSubmit": self = .userPromptSubmit
            default: self = .unknown(name)
            }
        }
    }

    public let sessionId: String
    public let hookEventName: String
    public let cwd: String?
    public let transcriptPath: String?
    public let permissionMode: String?
    /// PermissionRequest
    public let toolName: String?
    public let toolInput: JSONValue?
    /// Notification
    public let message: String?
    public let notificationType: String?
    /// SessionStart
    public let source: String?
    public let model: String?
    public let sessionTitle: String?
    /// Stop
    public let lastAssistantMessage: String?
    /// UserPromptSubmit
    public let prompt: String?
    /// Subagent events carry an agent id; we only track top-level sessions.
    public let agentId: String?

    public var kind: Kind { Kind(name: hookEventName) }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case transcriptPath = "transcript_path"
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case message
        case notificationType = "type"
        case source
        case model
        case sessionTitle = "session_title"
        case lastAssistantMessage = "last_assistant_message"
        case prompt
        case agentId = "agent_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        hookEventName = try c.decode(String.self, forKey: .hookEventName)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        toolInput = try c.decodeIfPresent(JSONValue.self, forKey: .toolInput)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        notificationType = try c.decodeIfPresent(String.self, forKey: .notificationType)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        sessionTitle = try c.decodeIfPresent(String.self, forKey: .sessionTitle)
        lastAssistantMessage = try c.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId)
    }

    public init(
        sessionId: String,
        hookEventName: String,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        permissionMode: String? = nil,
        toolName: String? = nil,
        toolInput: JSONValue? = nil,
        message: String? = nil,
        notificationType: String? = nil,
        source: String? = nil,
        model: String? = nil,
        sessionTitle: String? = nil,
        lastAssistantMessage: String? = nil,
        prompt: String? = nil,
        agentId: String? = nil
    ) {
        self.sessionId = sessionId
        self.hookEventName = hookEventName
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.permissionMode = permissionMode
        self.toolName = toolName
        self.toolInput = toolInput
        self.message = message
        self.notificationType = notificationType
        self.source = source
        self.model = model
        self.sessionTitle = sessionTitle
        self.lastAssistantMessage = lastAssistantMessage
        self.prompt = prompt
        self.agentId = agentId
    }

    /// One-line human summary of what is being requested (for the approval card).
    public var toolSummary: String? {
        guard let toolName else { return nil }
        switch toolName {
        case "Bash":
            return toolInput?["command"]?.stringValue ?? "shell command"
        case "Edit", "Write", "Read", "NotebookEdit":
            return toolInput?["file_path"]?.stringValue ?? toolName
        case "WebFetch":
            return toolInput?["url"]?.stringValue ?? toolName
        default:
            return toolName
        }
    }
}
