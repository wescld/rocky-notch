import Foundation

/// A decoded hook event from an agent CLI.
/// Accepts Claude Code / Codex snake_case payloads and Grok's camelCase
/// variant. Decoding is tolerant: unknown event names and missing optional
/// fields never fail — the app degrades to showing less detail, not crashing.
public struct HookEvent: Codable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case sessionStart
        case sessionEnd
        case stop
        case notification
        case permissionRequest
        case postToolUse
        case userPromptSubmit
        case unknown(String)

        public init(name: String) {
            switch Self.canonical(name) {
            case "SessionStart": self = .sessionStart
            case "SessionEnd": self = .sessionEnd
            case "Stop": self = .stop
            case "Notification": self = .notification
            // Grok/Cursor have no PermissionRequest; PreToolUse and Cursor's
            // beforeShellExecution / beforeMCPExecution map to the same
            // approval UI flow. beforeReadFile can also block, but Rocky
            // installs it as fire-and-forget (silent fail-open).
            case "PermissionRequest", "PreToolUse",
                 "BeforeShellExecution", "BeforeMCPExecution":
                self = .permissionRequest
            // The tool ran, so whatever gate it was waiting on is settled.
            // This is the only signal we get when the user approves at the
            // terminal: the agent moves on without telling the pending hook.
            case "PostToolUse": self = .postToolUse
            case "UserPromptSubmit", "BeforeSubmitPrompt":
                self = .userPromptSubmit
            default: self = .unknown(name)
            }
        }

        /// Normalizes PascalCase, camelCase, and snake_case event names to
        /// the PascalCase forms Rocky uses internally.
        public static func canonical(_ name: String) -> String {
            let compact = name
                .replacingOccurrences(of: "_", with: "")
                .lowercased()
            switch compact {
            case "sessionstart": return "SessionStart"
            case "sessionend": return "SessionEnd"
            case "stop", "stopfailure": return "Stop"
            case "notification": return "Notification"
            case "permissionrequest": return "PermissionRequest"
            case "pretooluse": return "PreToolUse"
            case "posttooluse": return "PostToolUse"
            case "userpromptsubmit": return "UserPromptSubmit"
            case "beforesubmitprompt": return "BeforeSubmitPrompt"
            case "beforeshellexecution": return "BeforeShellExecution"
            case "beforemcpexecution": return "BeforeMCPExecution"
            case "beforereadfile": return "BeforeReadFile"
            case "afterfileedit": return "AfterFileEdit"
            default: return name
            }
        }
    }

    public let sessionId: String
    /// Canonical PascalCase name when recognized; otherwise the raw value.
    public let hookEventName: String
    public let cwd: String?
    public let transcriptPath: String?
    public let permissionMode: String?
    /// PermissionRequest / PreToolUse
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
        case sessionIdCamel = "sessionId"
        case conversationId = "conversation_id"
        case conversationIdCamel = "conversationId"
        case hookEventName = "hook_event_name"
        case hookEventNameCamel = "hookEventName"
        case cwd
        case workspaceRoot
        case workspace_root
        case workspaceRoots = "workspace_roots"
        case workspaceRootsCamel = "workspaceRoots"
        case transcriptPath = "transcript_path"
        case transcriptPathCamel = "transcriptPath"
        case permissionMode = "permission_mode"
        case permissionModeCamel = "permissionMode"
        case toolName = "tool_name"
        case toolNameCamel = "toolName"
        case toolInput = "tool_input"
        case toolInputCamel = "toolInput"
        /// Cursor beforeShellExecution puts the shell line at the top level.
        case command
        case message
        case notificationType = "type"
        case notificationTypeAlt = "notification_type"
        case notificationTypeCamel = "notificationType"
        case source
        case model
        case sessionTitle = "session_title"
        case sessionTitleCamel = "sessionTitle"
        case lastAssistantMessage = "last_assistant_message"
        case lastAssistantMessageCamel = "lastAssistantMessage"
        case prompt
        case agentId = "agent_id"
        case agentIdCamel = "agentId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try Self.decodeRequiredString(
            c, .sessionId, .sessionIdCamel, .conversationId, .conversationIdCamel
        )
        let rawEventName = try Self.decodeRequiredString(c, .hookEventName, .hookEventNameCamel)
        hookEventName = Kind.canonical(rawEventName)
        var resolvedCwd = try Self.decodeOptionalString(c, .cwd)
            ?? Self.decodeOptionalString(c, .workspaceRoot)
            ?? Self.decodeOptionalString(c, .workspace_root)
        if resolvedCwd == nil {
            if let roots = try c.decodeIfPresent([String].self, forKey: .workspaceRoots)
                ?? c.decodeIfPresent([String].self, forKey: .workspaceRootsCamel),
               let first = roots.first, !first.isEmpty {
                resolvedCwd = first
            }
        }
        cwd = resolvedCwd
        transcriptPath = try Self.decodeOptionalString(c, .transcriptPath, .transcriptPathCamel)
        permissionMode = try Self.decodeOptionalString(c, .permissionMode, .permissionModeCamel)
        var resolvedToolName = try Self.decodeOptionalString(c, .toolName, .toolNameCamel)
        var resolvedToolInput = try c.decodeIfPresent(JSONValue.self, forKey: .toolInput)
            ?? c.decodeIfPresent(JSONValue.self, forKey: .toolInputCamel)
        // Cursor beforeShellExecution: { "command": "npm test", … } without tool_name.
        if let shellCommand = try Self.decodeOptionalString(c, .command), !shellCommand.isEmpty {
            if resolvedToolName == nil {
                // MCP payloads may also carry `command` (server launcher); only
                // invent Shell when the event is shell or the name is still empty.
                let isMCP = hookEventName == "BeforeMCPExecution"
                resolvedToolName = isMCP ? (resolvedToolName ?? "MCP") : "Shell"
            }
            if resolvedToolInput == nil {
                resolvedToolInput = .object(["command": .string(shellCommand)])
            }
        }
        // beforeMCPExecution often has tool_name already; prefix for policy.
        if hookEventName == "BeforeMCPExecution",
           let name = resolvedToolName,
           !name.hasPrefix("MCP:"),
           !name.hasPrefix("mcp:") {
            resolvedToolName = "MCP:\(name)"
        }
        toolName = resolvedToolName
        toolInput = resolvedToolInput
        message = try c.decodeIfPresent(String.self, forKey: .message)
        notificationType = try Self.decodeOptionalString(
            c, .notificationType, .notificationTypeAlt, .notificationTypeCamel
        )
        source = try c.decodeIfPresent(String.self, forKey: .source)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        sessionTitle = try Self.decodeOptionalString(c, .sessionTitle, .sessionTitleCamel)
        lastAssistantMessage = try Self.decodeOptionalString(
            c, .lastAssistantMessage, .lastAssistantMessageCamel
        )
        prompt = Self.decodeFlexiblePrompt(c, .prompt)
        agentId = try Self.decodeOptionalString(c, .agentId, .agentIdCamel)
    }

    public func encode(to encoder: Encoder) throws {
        // Encode the Claude Code snake_case shape (IPC between hook and app).
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(hookEventName, forKey: .hookEventName)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
        try c.encodeIfPresent(permissionMode, forKey: .permissionMode)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        try c.encodeIfPresent(toolInput, forKey: .toolInput)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(notificationType, forKey: .notificationType)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(sessionTitle, forKey: .sessionTitle)
        try c.encodeIfPresent(lastAssistantMessage, forKey: .lastAssistantMessage)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encodeIfPresent(agentId, forKey: .agentId)
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
        self.hookEventName = Kind.canonical(hookEventName)
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
        case "Bash", "Shell", "run_terminal_command", "PowerShell":
            return toolInput?["command"]?.stringValue ?? "shell command"
        case "Edit", "Write", "Read", "NotebookEdit", "Delete",
             "search_replace", "write", "read_file", "MultiEdit":
            return toolInput?["file_path"]?.stringValue
                ?? toolInput?["target_file"]?.stringValue
                ?? toolInput?["path"]?.stringValue
                ?? toolName
        case "WebFetch", "web_fetch", "open_page", "web_fetch_url":
            return toolInput?["url"]?.stringValue ?? toolName
        case "WebSearch", "web_search", "SemanticSearch":
            return toolInput?["query"]?.stringValue ?? toolName
        case "Task":
            return toolInput?["description"]?.stringValue
                ?? toolInput?["prompt"]?.stringValue
                ?? toolName
        default:
            return toolName
        }
    }

    // MARK: - Flexible key helpers

    private static func decodeRequiredString(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ keys: CodingKeys...
    ) throws -> String {
        for key in keys {
            if let value = try c.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        throw DecodingError.keyNotFound(
            keys[0],
            .init(codingPath: c.codingPath, debugDescription: "missing \(keys[0].stringValue)")
        )
    }

    private static func decodeOptionalString(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ keys: CodingKeys...
    ) throws -> String? {
        for key in keys {
            if let value = try c.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    /// A prompt part in Kimi's structured `UserPromptSubmit` payload.
    private struct PromptPart: Decodable {
        let text: String?
    }

    /// Claude / Grok send `prompt` as a plain string; Kimi sends it as
    /// `[{"type":"text","text":"…"}]`. Accept both — decoding as String only
    /// would throw on Kimi's array and drop the whole event, losing the
    /// "You: …" task chip. Non-text parts (e.g. images) are skipped.
    private static func decodeFlexiblePrompt(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> String? {
        if let string = try? c.decodeIfPresent(String.self, forKey: key) {
            return string
        }
        if let parts = try? c.decodeIfPresent([PromptPart].self, forKey: key) {
            let text = parts.compactMap(\.text).joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
