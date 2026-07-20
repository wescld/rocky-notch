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
}
