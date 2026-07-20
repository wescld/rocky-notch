import SwiftUI
import VibenotchCore

/// Dark refined HUD fused with the notch, Vibe-Island-calibre: the pixel
/// charm lives in Rocky (the mascot); everything around him is quiet,
/// rounded and precise. Green only where it means something.
struct NotchView: View {
    @ObservedObject var hub: AgentHub
    @ObservedObject var state: NotchUIState

    static let expandedWidth: CGFloat = 430
    static let rowHeight: CGFloat = 40
    static let featuredHeight: CGFloat = 66
    static let cardHeight: CGFloat = 118
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
            ? rowHeight + 84
            : CGFloat(sessionCount) * rowHeight + (hasPending ? cardHeight : 26) + 20
        let height = notchHeight + rows + 18
        return CGSize(
            width: max(expandedWidth, notchWidth + wingWidth * 2),
            height: min(height, 520)
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
        .animation(.spring(duration: 0.32, bounce: 0.1), value: state.expanded)
        .animation(.spring(duration: 0.32, bounce: 0.1), value: hub.sessions.map(\.id))
        .onHover { hovering in
            // Expansion/collapse authority lives in NotchWindowController;
            // the view only reports raw hover.
            if state.hovering != hovering { state.hovering = hovering }
        }
    }

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
        }
        .compositingGroup()
        .shadow(color: .black.opacity(state.expanded ? 0.5 : 0), radius: 16, y: 8)
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        HStack {
            HStack(spacing: 9) {
                if hasPending {
                    RockySprite(state: "rocky-alert", fallback: "south", size: 20)
                } else if anyRunning {
                    RockyAnimatedSprite(size: 20)
                } else {
                    RockySprite(state: "rocky-sleeping", fallback: "south", size: 20)
                }
            }
            .padding(.leading, 18)
            .padding(.bottom, 1)
            .frame(width: Self.wingWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .center)

            Spacer()

            // Session count chip; amber while something needs the user.
            HStack(spacing: 6) {
                if !hub.sessions.isEmpty {
                    Text("\(hub.sessions.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(hasPending ? Color.black : Palette.inkSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(hasPending ? Palette.amber : Color.white.opacity(0.12))
                        )
                        .breathing(period: hasPending ? 1.0 : 100)
                }
            }
            .padding(.trailing, 18)
            .frame(width: Self.wingWidth, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Expanded

    /// Aggregates for the insights header (sessions currently tracked).
    private var totalTokens: Int { hub.sessions.reduce(0) { $0 + $1.tokens } }
    private var totalWork: TimeInterval { hub.sessions.reduce(0) { $0 + $1.activeSeconds } }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear.frame(height: 6)
            if !hub.sessions.isEmpty,
               SessionMeta.tokens(totalTokens) != nil || SessionMeta.workTime(totalWork) != nil {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.amber)
                    if let tokens = SessionMeta.tokens(totalTokens) {
                        Text(tokens).foregroundStyle(Palette.green)
                    }
                    if let work = SessionMeta.workTime(totalWork) {
                        if SessionMeta.tokens(totalTokens) != nil {
                            Text("·").foregroundStyle(Palette.inkTertiary)
                        }
                        Text(work).foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer()
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
            if hub.sessions.isEmpty {
                VStack(spacing: 10) {
                    RockySprite(state: "rocky-sleeping", fallback: "south", size: 64)
                    Text("Rocky de plantão. Rode claude ou codex num terminal.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight + 76)
            } else {
                ForEach(hub.sessions) { session in
                    if session.pending != nil {
                        PendingSessionCard(session: session, hub: hub)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        SessionRow(session: session)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            Color.clear.frame(height: 8)
        }
        .padding(.top, 28)
        .padding(.horizontal, 12)
        .colorScheme(.dark)
    }
}

// MARK: - Shared bits

/// Context chip: agent, terminal app, elapsed time.
struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.09))
            )
    }
}

enum SessionMeta {
    static func tokens(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        if count < 1000 { return "\(count) tok" }
        if count < 1_000_000 {
            return "\((Double(count) / 1000).formatted(.number.precision(.fractionLength(0))))k tok"
        }
        return "\((Double(count) / 1_000_000).formatted(.number.precision(.fractionLength(1))))M tok"
    }

    static func workTime(_ seconds: TimeInterval) -> String? {
        let minutes = Int(seconds / 60)
        guard minutes >= 1 else { return nil }
        if minutes < 60 { return "\(minutes)min" }
        let rest = minutes % 60
        return rest > 0 ? "\(minutes / 60)h\(rest)min" : "\(minutes / 60)h"
    }

    static func agentLabel(_ session: AgentSession) -> String {
        session.agent == "claude-code" ? "Claude" : session.agent.capitalized
    }

    static func terminalLabel(_ session: AgentSession) -> String? {
        guard let pid = session.terminalAppPid,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return nil }
        return app.localizedName
    }

    static func elapsed(_ session: AgentSession) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(session.lastEventAt) / 60))
        if minutes < 1 { return "agora" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h\(minutes % 60 > 0 ? "\(minutes % 60)m" : "")"
    }
}

/// Quiet row for sessions that don't need attention (dot + name + chips).
struct SessionRow: View {
    let session: AgentSession
    @State private var hovering = false

    private var statusColor: Color { Palette.status(session.status) }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.7), radius: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if session.status == .idle {
                    Text("terminou · clique pra ir")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.green)
                } else if session.status == .waitingInput {
                    Text("sua vez no terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.amber)
                } else if let action = session.lastAction {
                    ActionTicker(action: action)
                }
            }
            Spacer(minLength: 8)
            if session.status == .running {
                EqualizerBars(tint: Palette.green)
                    .frame(width: 14, height: 9)
            }
            if let tokens = SessionMeta.tokens(session.tokens) {
                Chip(text: tokens)
            }
            Chip(text: SessionMeta.agentLabel(session))
            if let terminal = SessionMeta.terminalLabel(session) {
                Chip(text: terminal)
            }
            Text(SessionMeta.elapsed(session))
                .font(.system(size: 10))
                .foregroundStyle(Palette.inkTertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: NotchView.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { TerminalFocus.focus(session: session) }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
        .animation(.easeInOut(duration: 0.25), value: session.lastAction)
    }
}

/// The featured card: Rocky front and center, the request, the answer.
struct PendingSessionCard: View {
    let session: AgentSession
    @ObservedObject var hub: AgentHub

    var body: some View {
        guard let pending = session.pending else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    RockySprite(state: "rocky-alert", fallback: "south", size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.projectName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text("Rocky pergunta: \(pending.toolName)?")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.amber)
                    }
                    Spacer(minLength: 8)
                    Chip(text: SessionMeta.agentLabel(session))
                    if let terminal = SessionMeta.terminalLabel(session) {
                        Chip(text: terminal)
                    }
                }
                Text(pending.summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.black.opacity(0.5))
                    )
                HStack(spacing: 7) {
                    ActionButton(title: "Aprovar", style: .fill(Palette.green)) {
                        hub.decide(requestId: pending.requestId, decision: .allow)
                    }
                    ActionButton(title: "Negar", style: .tint(Palette.red)) {
                        hub.decide(requestId: pending.requestId, decision: .deny)
                    }
                    ActionButton(title: "No terminal", style: .neutral) {
                        hub.decide(requestId: pending.requestId, decision: .ask)
                    }
                    Spacer()
                    TimeoutBar(since: pending.receivedAt, total: 55)
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Palette.amber.opacity(0.35), lineWidth: 1)
                    )
            )
            .padding(.vertical, 3)
        )
    }
}

struct ActionButton: View {
    enum Style {
        case fill(Color)
        case tint(Color)
        case neutral
    }

    let title: String
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
    }

    private var background: some View {
        Group {
            switch style {
            case .fill(let color):
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(hovering ? 1 : 0.88))
            case .tint(let color):
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(hovering ? 0.28 : 0.16))
            case .neutral:
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.14 : 0.09))
            }
        }
    }

    private var foreground: Color {
        switch style {
        case .fill: .black
        case .tint(let color): color
        case .neutral: Palette.inkSecondary
        }
    }
}

// MARK: - Primitives

/// Gentle infinite pulse (opacity) for "needs attention" accents.
private struct BreathingModifier: ViewModifier {
    let period: Double
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.45 : 1)
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

/// Rocky alive: cycles the idle frames (breathing carapace).
struct RockyAnimatedSprite: View {
    let size: CGFloat
    private static let frames: [NSImage] = (0..<9).compactMap { index in
        guard let url = Bundle.main.url(
            forResource: "idle-\(index)", withExtension: "png", subdirectory: "Art"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        if Self.frames.isEmpty {
            RockySprite(state: "south", fallback: "south", size: size)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { timeline in
                let index = Int(timeline.date.timeIntervalSinceReferenceDate * 8)
                    % Self.frames.count
                Image(nsImage: Self.frames[index])
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
        }
    }
}

/// Rocky sprite from the bundled pixel art, rendered crisp (no smoothing).
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

/// Quantized mini meter, Rocky's voice made visible.
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
                    let height = (10.0 * level / 2).rounded() * 2
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tint)
                        .frame(width: 3, height: max(2, height))
                }
            }
            .shadow(color: tint.opacity(0.5), radius: 2)
        }
    }
}

/// Live "what the agent is doing" readout: tool bright, args dim.
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

/// Segmented countdown, draining green → amber → red.
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
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < full ? color : Color.white.opacity(0.12))
                        .frame(width: 3.5, height: 7)
                }
            }
        }
    }
}
