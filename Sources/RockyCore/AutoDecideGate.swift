import Foundation

/// Auto-deciding is a test facility, never an inherited release-build default.
public enum AutoDecideGate {
    private static let environmentKey = "ROCKY_AUTODECIDE"

    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public static func decision(
        environment: [String: String],
        arguments: [String],
        isDebugBuild: Bool = AutoDecideGate.isDebugBuild
    ) -> Decision? {
        guard let raw = environment[environmentKey], let decision = Decision(rawValue: raw),
              isDebugBuild || IntegrationTestLaunch.isActive(arguments: arguments)
        else { return nil }
        return decision
    }
}

public enum IntegrationTestLaunch {
    public static let flag = "--rocky-integration-test"

    public static func isActive(arguments: [String]) -> Bool {
        arguments.contains(flag)
    }
}
