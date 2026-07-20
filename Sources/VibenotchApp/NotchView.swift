import SwiftUI
import VibenotchCore

/// The black surface that fuses with the notch. Collapsed: an LED strip per
/// session beside the notch (hardware VU-meter language). Expanded: the
/// session console with the approval card.
struct NotchView: View {
    @ObservedObject var hub: AgentHub
    @ObservedObject var state: NotchUIState

    static let expandedWidth: CGFloat = 400
    static let rowHeight: CGFloat = 46
    static let cardHeight: CGFloat = 104
    static let wingWidth: CGFloat = 70

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
            ? rowHeight + 30
            : CGFloat(sessionCount) * rowHeight
        let card: CGFloat = hasPending ? cardHeight : 0
        let height = notchHeight + rows + card + 20
        return CGSize(
            width: max(expandedWidth, notchWidth + wingWidth * 2),
            height: min(height, 480)
        )
    }

    private var hasPending: Bool {
        hub.sessions.contains { $0.pending != nil }
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
        .animation(.spring(duration: 0.32, bounce: 0.12), value: state.expanded)
        .animation(.spring(duration: 0.32, bounce: 0.12), value: hub.sessions.map(\.id))
        .onHover { hovering in
            // Expansion/collapse authority lives in NotchWindowController;
            // the view only reports raw hover.
            if state.hovering != hovering { state.hovering = hovering }
        }
    }

    /// True black, one hairline when open, amber halo only while something
    /// needs the user. Nothing else — the surface must read as hardware.
    private var surface: some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: .init(bottomLeading: 18, bottomTrailing: 18),
            style: .continuous
        )
        return ZStack {
            shape.fill(.black)
            if state.expanded {
                shape.strokeBorder(Palette.hairline, lineWidth: 1)
            }
            if hasPending {
                shape
                    .strokeBorder(Palette.amber.opacity(0.55), lineWidth: 1)
                    .blur(radius: 2.5)
                    .breathing(period: 1.5)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(state.expanded ? 0.55 : 0), radius: 20, y: 10)
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        HStack {
            // Left wing: the meter — alive only while agents run.
            HStack {
                if hub.sessions.contains(where: { $0.status == .running }) {
                    EqualizerBars(tint: Palette.green)
                        .frame(width: 18, height: 11)
                }
            }
            .padding(.leading, 18)
            .frame(width: Self.wingWidth, alignment: .leading)

            Spacer()

            // Right wing: one LED per session, newest first.
            HStack(spacing: 6) {
                if hub.sessions.isEmpty {
                    LED(color: Palette.inkTertiary, lit: false)
                } else {
                    ForEach(hub.sessions.prefix(6)) { session in
                        LED(
                            color: Palette.status(session.status),
                            lit: session.status != .idle,
                            urgent: session.pending != nil
                        )
                    }
                }
            }
            .padding(.trailing, 18)
            .frame(width: Self.wingWidth, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 10)
            if hub.sessions.isEmpty {
                VStack(spacing: 5) {
                    RockySprite(state: "rocky-sleeping", fallback: "south", size: 34)
                        .breathing(period: 3.5)
                    EtchedLabel(text: "rocky de plantão", color: Palette.inkTertiary)
                    Text("rode claude ou codex num terminal")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.inkTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight + 30)
            } else {
                ForEach(Array(hub.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        Rectangle()
                            .fill(Palette.hairline)
                            .frame(height: 1)
                            .padding(.horizontal, 2)
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

// MARK: - Animated primitives

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

/// A physical indicator light: hot core, colored halo. Urgent LEDs pulse.
struct LED: View {
    let color: Color
    var lit: Bool = true
    var urgent: Bool = false

    var body: some View {
        Circle()
            .fill(lit ? color : Color.white.opacity(0.12))
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .fill(Color.white.opacity(lit ? 0.55 : 0))
                    .frame(width: 2, height: 2)
                    .offset(x: -0.5, y: -0.5)
            )
            .shadow(color: lit ? color.opacity(0.9) : .clear, radius: urgent ? 5 : 2.5)
            .breathing(period: urgent ? 0.8 : 3.2)
            .opacity(lit ? 1 : 0.8)
    }
}

/// The signature mark: a 4-bar meter breathing with agent activity.
struct EqualizerBars: View {
    var tint: Color
    var barCount: Int = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    // Irrational-ish phase offsets so the loop never reads
                    // as a repeating pattern.
                    let phase = t * 2.6 + Double(index) * 1.618 * 2
                    let level = 0.30 + 0.70 * abs(sin(phase)) * (0.75 + 0.25 * sin(t * 0.9 + Double(index)))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(
                            LinearGradient(
                                colors: [tint, Palette.greenDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: 11 * level)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
            .shadow(color: tint.opacity(0.6), radius: 3)
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
        case .waitingPermission: "permissão"
        case .waitingInput: "sua vez"
        case .idle: "ocioso"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Group {
                    if session.status == .running {
                        EqualizerBars(tint: Palette.green)
                    } else {
                        LED(
                            color: Palette.status(session.status),
                            lit: session.status != .idle,
                            urgent: session.pending != nil
                        )
                    }
                }
                .frame(width: 16, height: 11)

                Text(session.projectName)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)

                if session.agent != "claude-code" {
                    EtchedLabel(text: session.agent, color: Palette.inkTertiary)
                }

                if session.status == .running, let action = session.lastAction {
                    ActionTicker(action: action)
                } else {
                    EtchedLabel(
                        text: statusLabel,
                        color: session.status == .waitingInput
                            ? Palette.amber
                            : Palette.inkTertiary
                    )
                }

                Spacer(minLength: 8)

                Button {
                    TerminalFocus.focus(session: session)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hoveringTerminal ? Palette.green : Palette.inkTertiary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.spring(duration: 0.18)) { hoveringTerminal = hovering }
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
        .animation(.spring(duration: 0.3, bounce: 0.15), value: session.pending)
        .animation(.easeInOut(duration: 0.25), value: session.lastAction)
    }
}

/// Live "what the agent is doing" readout. First token bright (the tool),
/// remainder dim — reads like a terminal, changes with a soft crossfade.
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
        HStack(alignment: .top, spacing: 0) {
            // Accent spine — the card's "LED" edge.
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.amber)
                .frame(width: 2)
                .breathing(period: 1.2)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    RockySprite(state: "rocky-alert", fallback: "south", size: 16)
                        .breathing(period: 1.2)
                    EtchedLabel(text: pending.toolName, color: Palette.amber)
                    Spacer()
                    TimeoutRing(since: pending.receivedAt, total: 55)
                        .frame(width: 11, height: 11)
                }
                Text(pending.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    DecisionButton(title: "Aprovar", style: .fill(Palette.green)) {
                        hub.decide(requestId: pending.requestId, decision: .allow)
                    }
                    DecisionButton(title: "Negar", style: .outline(Palette.red)) {
                        hub.decide(requestId: pending.requestId, decision: .deny)
                    }
                    DecisionButton(title: "No terminal", style: .ghost) {
                        hub.decide(requestId: pending.requestId, decision: .ask)
                    }
                }
            }
            .padding(.leading, 10)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
        )
        .padding(.bottom, 8)
    }
}

/// Countdown ring for the pending decision (visual, approximate).
struct TimeoutRing: View {
    let since: Date
    let total: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(since)
            let remaining = max(0, 1 - elapsed / total)
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1.5)
                .overlay(
                    Circle()
                        .trim(from: 0, to: remaining)
                        .stroke(
                            remaining < 0.25 ? Palette.red : Palette.amber,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                )
        }
    }
}

struct DecisionButton: View {
    enum Style {
        case fill(Color)
        case outline(Color)
        case ghost
    }

    let title: String
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 4.5)
                .background(background)
                .overlay(border)
                .foregroundStyle(foreground)
                .clipShape(Capsule())
                .scaleEffect(hovering ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(duration: 0.16)) { hovering = h }
        }
    }

    private var background: some View {
        Group {
            switch style {
            case .fill(let color):
                Capsule().fill(color.opacity(hovering ? 1 : 0.85))
            case .outline(let color):
                Capsule().fill(color.opacity(hovering ? 0.22 : 0.0))
            case .ghost:
                Capsule().fill(Color.white.opacity(hovering ? 0.10 : 0.0))
            }
        }
    }

    private var border: some View {
        Group {
            switch style {
            case .fill:
                Capsule().strokeBorder(.clear, lineWidth: 1)
            case .outline(let color):
                Capsule().strokeBorder(color.opacity(hovering ? 0.9 : 0.45), lineWidth: 1)
            case .ghost:
                Capsule().strokeBorder(Palette.hairline, lineWidth: 1)
            }
        }
    }

    private var foreground: Color {
        switch style {
        case .fill: .black
        case .outline(let color): color
        case .ghost: Palette.inkSecondary
        }
    }
}
