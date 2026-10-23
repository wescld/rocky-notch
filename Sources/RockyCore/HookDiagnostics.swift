import Foundation

/// Log categories only: decoder descriptions can quote secrets from the input.
public enum HookDiagnostics {
    public static func decodeFailure(_ error: Error, byteCount: Int) -> String {
        let category: String
        switch error {
        case DecodingError.dataCorrupted: category = "data-corrupted"
        case DecodingError.keyNotFound: category = "missing-key"
        case DecodingError.typeMismatch: category = "type-mismatch"
        case DecodingError.valueNotFound: category = "missing-value"
        default: category = "unknown"
        }
        return "decode category=\(category) bytes=\(byteCount)"
    }

    public static func eventSummary(_ event: HookEvent) -> String {
        let category: String
        switch event.kind {
        case .sessionStart: category = "session-start"
        case .sessionEnd: category = "session-end"
        case .stop: category = "stop"
        case .subagentStart: category = "subagent-start"
        case .subagentStop: category = "subagent-stop"
        case .notification: category = "notification"
        case .permissionRequest: category = "permission-request"
        case .postToolUse: category = "post-tool-use"
        case .userPromptSubmit: category = "user-prompt-submit"
        case .unknown: category = "unknown"
        }
        return "event=\(category) tool-present=\(event.toolName != nil) subagent=\(event.agentId != nil)"
    }
}
