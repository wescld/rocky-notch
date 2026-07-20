import SwiftUI
import VibenotchCore

/// Pixel-art game HUD fused with the notch. Rocky stars in it: he sleeps
/// when nothing runs, vibes while agents work, and jumps alert when
/// something needs the user. Staircase corners, hard shadows, pixel font.
struct NotchView: View {
    @ObservedObject var hub: AgentHub
    @ObservedObject var state: NotchUIState

    static let expandedWidth: CGFloat = 420
    static let rowHeight: CGFloat = 48
    static let cardHeight: CGFloat = 112
    static let wingWidth: CGFloat = 78

    static func size(
        expanded: Bool,
        sessionCount: Int,
        hasPending: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat
    ) -> CGSize {
        if !expanded {
            return CGSize(width: notchWidth + wingWidth * 2, height: notchHeight)
        }
        let rows = sessionCount == 0
            ? rowHeight + 72
            : CGFloat(sessionCount) * rowHeight
        let card: CGFloat = hasPending ? cardHeight : 0
        let height = notchHeight + rows + card + 22
        return CGSize(
            width: max(expandedWidth, notchWidth + wingWidth * 2),
            height: min(height, 500)
        )
    }

    private var hasPending: Bool {
        hub.sessions.contains { $0.pending != nil }
    }

    private var anyRunning: Bool {
        hub.sessions.contains { $0.status == .running }
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.expanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                collapsedContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(surface)
        .animation(.spring(duration: 0.3, bounce: 0.1), value: state.expanded)
        .animation(.spring(duration: 0.3, bounce: 0.1), value: hub.sessions.map(\.id))
        .onHover { hovering in
            // Expansion/collapse authority lives in NotchWindowController;
            // the view only reports raw hover.
            if state.hovering != hovering { state.hovering = hovering }
        }
    }

    /// True black plate with staircase pixel corners; amber pixel frame
    /// pulses while something needs the user.
    private var surface: some View {
        ZStack {
            PixelPanel().fill(.black)
            if state.expanded {
                PixelPanel().stroke(Palette.hairline, lineWidth: 2)
            }
            // Border only when open: collapsed must fuse seamlessly with the
            // physical notch (pure black, no outline).
            if hasPending, state.expanded {
                PixelPanel()
                    .stroke(Palette.amber.opacity(0.6), lineWidth: 2)
                    .breathing(period: 0.9)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(state.expanded ? 0.55 : 0), radius: 0, x: 4, y: 4)
    }

    // MARK: - Collapsed

    /// Rocky lives on the left wing, mirroring the fleet's mood.
    private var collapsedContent: some View {
        HStack {
            HStack(spacing: 5) {
                RockySprite(
                    state: hasPending
                        ? "rocky-alert"
                        : anyRunning ? "south" : "rocky-sleeping",
                    fallback: "south",
                    size: 20
                )
                if anyRunning {
                    EqualizerBars(tint: Palette.green)
                        .frame(width: 14, height: 10)
                }
            }
            .padding(.leading, 12)
            .frame(width: Self.wingWidth, alignment: .leading)

            Spacer()

            // Right wing: one square pixel LED per session.
            HStack(spacing: 5) {
                if hub.sessions.isEmpty {
                    PixelLED(color: Palette.inkTertiary, lit: false)
                } else {
                    ForEach(hub.sessions.prefix(6)) { session in
                        PixelLED(
                            color: Palette.status(session.status),
                            lit: session.status != .idle,
                            urgent: session.pending != nil
                        )
                    }
                }
            }
            .padding(.trailing, 16)
            .frame(width: Self.wingWidth, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 12)
            if hub.sessions.isEmpty {
                VStack(spacing: 8) {
                    RockySprite(state: "rocky-sleeping", fallback: "south", size: 76)
                    PixelText("zzz... rocky de plantao", size: 7, color: Palette.inkTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight + 44)
            } else {
                ForEach(Array(hub.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        PixelDivider()
                    }
                    SessionRow(session: session, hub: hub)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Color.clear.frame(height: 10)
        }
        .padding(.top, 30)
        .padding(.horizontal, 16)
        .colorScheme(.dark)
    }
}

// MARK: - Pixel primitives

/// Panel with square top and staircase (8-bit) bottom corners.
struct PixelPanel: Shape {
    var steps: Int = 3
    var stepSize: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let s = stepSize
        let n = CGFloat(steps)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - n * s))
        for i in 0..<steps {
            let fi = CGFloat(i)
            p.addLine(to: CGPoint(x: rect.maxX - (fi + 1) * s, y: rect.maxY - (n - fi) * s))
            p.addLine(to: CGPoint(x: rect.maxX - (fi + 1) * s, y: rect.maxY - (n - fi - 1) * s))
        }
        p.addLine(to: CGPoint(x: rect.minX + n * s, y: rect.maxY))
        for i in 0..<steps {
            let fi = CGFloat(i)
            p.addLine(to: CGPoint(x: rect.minX + (n - fi) * s, y: rect.maxY - fi * s))
            p.addLine(to: CGPoint(x: rect.minX + (n - fi - 1) * s, y: rect.maxY - (fi + 1) * s))
        }
        p.closeSubpath()
        return p
    }
}

/// Press Start 2P text; ALL CAPS reads best at these sizes.
struct PixelText: View {
    let text: String
    let size: CGFloat
    let color: Color

    init(_ text: String, size: CGFloat, color: Color) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.custom("Press Start 2P", size: size))
            .foregroundStyle(color)
    }
}

struct PixelDivider: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<40, id: \.self) { _ in
                Rectangle().fill(Palette.hairline).frame(width: 4, height: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

/// Square game LED with hot-pixel core.
struct PixelLED: View {
    let color: Color
    var lit: Bool = true
    var urgent: Bool = false

    var body: some View {
        Rectangle()
            .fill(lit ? color : Color.white.opacity(0.12))
            .frame(width: 6, height: 6)
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(lit ? 0.6 : 0))
                    .frame(width: 2, height: 2)
                    .offset(x: -1, y: -1)
            )
            .shadow(color: lit ? color.opacity(0.9) : .clear, radius: urgent ? 4 : 2)
            .breathing(period: urgent ? 0.8 : 3.2)
    }
}

/// Gentle infinite pulse (opacity) for "needs attention" accents.
private struct BreathingModifier: ViewModifier {
    let period: Double
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: period).repeatForever()) {
                    dimmed = true
                }
            }
    }
}

extension View {
    func breathing(period: Double = 1.2) -> some View {
        modifier(BreathingModifier(period: period))
    }
}

/// Rocky sprite from the bundled pixel art, rendered crisp (no smoothing).
/// Tries the named state first, then the fallback rotation frame.
struct RockySprite: View {
    let state: String
    let fallback: String
    let size: CGFloat

    private var image: NSImage? {
        for name in [state, fallback] {
            if let url = Bundle.main.url(
                forResource: name, withExtension: "png", subdirectory: "Art"
            ), let img = NSImage(contentsOf: url) {
                return img
            }
        }
        return nil
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}

/// Squared-off audio meter, Rocky's voice made visible.
struct EqualizerBars: View {
    var tint: Color
    var barCount: Int = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 16.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = t * 2.6 + Double(index) * 1.618 * 2
                    let level = 0.30 + 0.70 * abs(sin(phase))
                    // Quantized to 2px steps: pixel bars, not smooth bars.
                    let height = (10.0 * level / 2).rounded() * 2
                    Rectangle()
                        .fill(tint)
                        .frame(width: 3, height: max(2, height))
                }
            }
            .shadow(color: tint.opacity(0.6), radius: 2)
        }
    }
}

struct SessionRow: View {
    let session: AgentSession
    @ObservedObject var hub: AgentHub
    @State private var hoveringTerminal = false

    private var statusLabel: String {
        switch session.status {
        case .running: "rodando"
        case .waitingPermission: "permissao!"
        case .waitingInput: "sua vez"
        case .idle: "zzz"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                // Rocky mini-me carries the row's mood.
                RockySprite(
                    state: session.pending != nil || session.status == .waitingInput
                        ? "rocky-alert"
                        : session.status == .idle ? "rocky-sleeping" : "south",
                    fallback: "south",
                    size: 30
                )

                PixelText(session.projectName, size: 8, color: Palette.ink)
                    .lineLimit(1)

                if session.agent != "claude-code" {
                    PixelText(session.agent, size: 6, color: Palette.inkTertiary)
                }

                if session.status == .running {
                    EqualizerBars(tint: Palette.green)
                        .frame(width: 16, height: 10)
                }

                if session.status == .running, let action = session.lastAction {
                    ActionTicker(action: action)
                } else {
                    PixelText(
                        statusLabel,
                        size: 7,
                        color: session.status == .waitingInput || session.pending != nil
                            ? Palette.amber
                            : Palette.inkTertiary
                    )
                }

                Spacer(minLength: 8)

                Button {
                    TerminalFocus.focus(session: session)
                } label: {
                    PixelText(">_", size: 8, color: hoveringTerminal ? Palette.green : Palette.inkTertiary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.spring(duration: 0.15)) { hoveringTerminal = hovering }
                }
                .help("ir para o terminal")
            }
            .frame(height: NotchView.rowHeight - 16)

            if let pending = session.pending {
                PermissionCard(pending: pending, hub: hub)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.1), value: session.pending)
        .animation(.easeInOut(duration: 0.25), value: session.lastAction)
    }
}

/// Live "what the agent is doing" readout. First token bright (the tool),
/// remainder dim — SF Mono here on purpose: readability beats theme.
struct ActionTicker: View {
    let action: String

    var body: some View {
        let parts = action.split(separator: " ", maxSplits: 1)
        return (
            Text(String(parts.first ?? ""))
                .foregroundColor(Palette.green.opacity(0.85))
            + Text(parts.count > 1 ? " " + parts[1] : "")
                .foregroundColor(Palette.inkSecondary)
        )
        .font(.system(size: 10, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        .id(action)
        .transition(.opacity)
    }
}

struct PermissionCard: View {
    let pending: PendingPermission
    @ObservedObject var hub: AgentHub

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                RockySprite(state: "rocky-alert", fallback: "south", size: 34)
                PixelText(pending.toolName, size: 8, color: Palette.amber)
                Spacer()
                TimeoutBar(since: pending.receivedAt, total: 55)
            }
            Text(pending.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                PixelButton(title: "aprovar", tint: Palette.green, filled: true) {
                    hub.decide(requestId: pending.requestId, decision: .allow)
                }
                PixelButton(title: "negar", tint: Palette.red, filled: false) {
                    hub.decide(requestId: pending.requestId, decision: .deny)
                }
                PixelButton(title: "terminal", tint: Palette.inkSecondary, filled: false) {
                    hub.decide(requestId: pending.requestId, decision: .ask)
                }
            }
        }
        .padding(10)
        .background(
            Rectangle()
                .fill(Color.white.opacity(0.045))
                .overlay(Rectangle().stroke(Palette.amber.opacity(0.4), lineWidth: 2))
        )
        .padding(.bottom, 8)
    }
}

/// HP-bar style countdown: 10 pixel segments draining left to right.
struct TimeoutBar: View {
    let since: Date
    let total: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(since)
            let remaining = max(0.0, 1 - elapsed / total)
            let full = Int((remaining * 10).rounded(.up))
            let color = remaining < 0.25
                ? Palette.red
                : remaining < 0.5 ? Palette.amber : Palette.green
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { index in
                    Rectangle()
                        .fill(index < full ? color : Color.white.opacity(0.12))
                        .frame(width: 4, height: 7)
                }
            }
        }
    }
}

/// Game-menu button: hard shadow, 2px border, presses down on hover-click.
struct PixelButton: View {
    let title: String
    let tint: Color
    let filled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            PixelText(title, size: 7, color: filled ? .black : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Rectangle().fill(
                        filled
                            ? tint.opacity(hovering ? 1 : 0.9)
                            : tint.opacity(hovering ? 0.18 : 0)
                    )
                )
                .overlay(Rectangle().stroke(tint.opacity(filled ? 0 : 0.7), lineWidth: 2))
                .shadow(
                    color: (filled ? tint : Color.black).opacity(0.5),
                    radius: 0,
                    x: hovering ? 1 : 2,
                    y: hovering ? 1 : 2
                )
                .offset(x: hovering ? 1 : 0, y: hovering ? 1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.1)) { hovering = h }
        }
    }
}
