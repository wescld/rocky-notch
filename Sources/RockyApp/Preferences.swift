import Foundation

/// User preferences, persisted in UserDefaults.
enum Preferences {
    enum DisplayMode: String {
        case notch
        case menuBar
    }

    static var displayMode: DisplayMode {
        get {
            DisplayMode(
                rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? ""
            ) ?? .notch
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "displayMode")
        }
    }

    static var soundsEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "soundsEnabled") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "soundsEnabled")
        }
    }

    /// Whether Rocky gates Kimi Code tool calls (shows approval cards).
    ///
    /// Off by default: Kimi's PreToolUse hook is deny-only, so in Kimi's normal
    /// manual mode Rocky would just double up on Kimi's own prompt. Rocky only
    /// becomes the sole gate when Kimi runs in auto / yolo — which it cannot
    /// detect (the mode is a launch flag, absent from the hook payload). So the
    /// user opts in here when they run Kimi autonomously and want Rocky as the
    /// safety net; otherwise Rocky just observes Kimi sessions.
    static var kimiGateEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "kimiGateEnabled") as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "kimiGateEnabled")
        }
    }

    /// Auto-expand the notch briefly when a turn finishes (completion card).
    static var showCompletionCards: Bool {
        get {
            UserDefaults.standard.object(forKey: "showCompletionCards") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "showCompletionCards")
        }
    }

    /// Show Claude account rate-limit chip when a statusLine cache is present.
    static var showAccountUsage: Bool {
        get {
            UserDefaults.standard.object(forKey: "showAccountUsage") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "showAccountUsage")
        }
    }
}
