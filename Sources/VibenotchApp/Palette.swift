import SwiftUI

/// vibenotch design tokens — "instrument panel" direction.
/// Surface is true black to fuse with the physical notch; color is spent
/// almost entirely on the LED/status language.
enum Palette {
    /// Primary — phosphor green, vivid without going acid.
    static let green = Color(red: 0.24, green: 0.89, blue: 0.51)      // #3DE383
    static let greenDeep = Color(red: 0.12, green: 0.64, blue: 0.36)  // #1FA35C
    /// Attention — warm amber, reads "LED", not "warning tape".
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.25)       // #FFB340
    static let red = Color(red: 1.0, green: 0.36, blue: 0.33)         // #FF5D55

    static let ink = Color.white.opacity(0.92)
    static let inkSecondary = Color.white.opacity(0.55)
    static let inkTertiary = Color.white.opacity(0.30)
    static let hairline = Color.white.opacity(0.08)

    static func status(_ status: VibenotchCore.AgentSession.Status) -> Color {
        switch status {
        case .running: green
        case .waitingPermission: amber
        case .waitingInput: amber
        case .idle: Color.white.opacity(0.35)
        }
    }
}

import VibenotchCore

/// Micro-label in "etched hardware" style: uppercase, tracked, tiny.
struct EtchedLabel: View {
    let text: String
    var color: Color = Palette.inkSecondary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(color)
    }
}
