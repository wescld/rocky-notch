import Foundation

/// Idle describes activity; it is not evidence that a turn succeeded.
public enum TurnOutcome: String, Codable, Equatable, Sendable {
    case none, succeeded, failed, cancelled, timedOut

    public var failureLabel: String? {
        switch self {
        case .failed: return "failed · click to inspect"
        case .cancelled: return "cancelled · click to inspect"
        case .timedOut: return "timed out · click to inspect"
        default: return nil
        }
    }

    static func normalized(eventName: String, terminationReason: String?, fullyIdle: Bool?) -> Self {
        let compact = eventName.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "").lowercased()
        if compact == "stopfailure" { return .failed }
        let reason = terminationReason?.lowercased()
        if let reason {
            if reason.contains("timeout") || reason.contains("timed out") { return .timedOut }
            if reason.contains("cancel") || reason.contains("abort") || reason.contains("interrupt") {
                return .cancelled
            }
            if reason.contains("fail") || reason.contains("error") || reason.contains("exception") {
                return .failed
            }
        }
        // A busy turn cannot complete, but its failure must remain visible.
        if HookEvent.Kind.canonical(eventName) == "Stop", fullyIdle == false { return .none }
        if let reason, reason.contains("success") || reason.contains("complete") || reason.contains("finish") {
            return .succeeded
        }
        return HookEvent.Kind.canonical(eventName) == "Stop" ? .succeeded : .none
    }
}
