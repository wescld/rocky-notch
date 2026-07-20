import SwiftUI
import RockyCore

/// Dark refined HUD fused with the notch, Vibe-Island-calibre: the pixel
/// charm lives in Rocky (the mascot); everything around him is quiet,
/// rounded and precise. Green only where it means something.
struct NotchView: View {
    @ObservedObject var hub: AgentHub
    @ObservedObject var state: NotchUIState
    var notchWidth: CGFloat = 200
    var notchHeight: CGFloat = 37

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
        notchHeight: CGFloat,
        pendingDiffLines: Int = 0
    ) -> CGSize {
        if !expanded {
            // Slightly taller than the physical notch so the glass rim on the
            // bottom edge is fully visible below the hardware cutout.
            return CGSize(width: notchWidth + wingWidth * 2, height: notchHeight + 5)
        }
        let card = hasPending ? cardHeight + CGFloat(pendingDiffLines) * 21 : 26
        let rows = sessionCount == 0
            ? rowHeight + 84
            : CGFloat(sessionCount) * rowHeight + card + 20 + 40
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
        let shape = state.expanded
            ? NotchShape(topRadius: 14, bottomRadius: 18, convexTop: true)
            : NotchShape(topRadius: 7, bottomRadius: 18)
        return ZStack {
            shape.fill(.black)
            // Liquid-glass lip: a light rim that only exists on the lateral
            // and bottom edges (clear at the top, so the fusion with the
            // physical notch stays seamless) — reads as a glass edge
            // catching light.
            shape.stroke(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.16), location: 0.10),
                        .init(color: .white.opacity(0.20), location: 0.55),
                        .init(color: .white.opacity(state.expanded ? 0.34 : 0.28), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .compositingGroup()
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        HStack {
            HStack(spacing: 9) {
                if hasPending {
                    RockySprite(state: "rocky-alert", fallback: "south", size: 20)
                } else if !hub.celebrating.isEmpty {
                    RockyAnimatedSprite(prefix: "dance", fallback: "rocky-celebrating", fps: 10, size: 22)
                        .transition(.scale.combined(with: .opacity))
                } else if anyRunning {
                    RockyAnimatedSprite(size: 20)
                } else {
                    RockySprite(state: "rocky-sleeping", fallback: "south", size: 20)
                }
            }
            .pokeable()
            .animation(.spring(duration: 0.3, bounce: 0.5), value: hub.celebrating)
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
        SessionListView(hub: hub)
            .padding(.top, 28)
            .padding(.horizontal, 12)
            .colorScheme(.dark)
    }
}

/// The real notch silhouette: concave flares at the top (where the panel
/// meets the menu bar, like the hardware cutout) and convex rounded bottom
/// corners. The top edge stays straight for seamless fusion.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// false = concave flare (fused with the hardware notch, collapsed);
    /// true = regular convex rounding (floating card, expanded).
    var convexTop: Bool = false

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = topRadius
        let b = bottomRadius
        if convexTop {
            p.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
            p.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + t),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
            p.addQuadCurve(
                to: CGPoint(x: rect.maxX - b, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            p.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
            p.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - b),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
            p.addQuadCurve(
                to: CGPoint(x: rect.minX + t, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
            p.closeSubpath()
            return p
        }
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + t, y: rect.minY + t),
            control: CGPoint(x: rect.minX + t, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
            control: CGPoint(x: rect.minX + t, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
            control: CGPoint(x: rect.maxX - t, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - t, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}


/// The session console: insights header + rows + pending cards. Shared by
/// the notch panel and the menu bar mode.
struct SessionListView: View {
    @ObservedObject var hub: AgentHub

    private var totalTokens: Int { hub.sessions.reduce(0) { $0 + $1.tokens } }
    private var totalWork: TimeInterval { hub.sessions.reduce(0) { $0 + $1.activeSeconds } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear.frame(height: 6)
            if !hub.sessions.isEmpty,
               SessionMeta.tokens(totalTokens) != nil || SessionMeta.workTime(totalWork) != nil {
                HStack(spacing: 5) {
                    TokenIcon(size: 11)
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
                        .pokeable()
                    Text("Rocky on watch. Run claude or codex in a terminal.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: NotchView.rowHeight + 76)
            } else {
                ForEach(hub.sessions) { session in
                    if session.pending != nil {
                        PendingSessionCard(session: session, hub: hub)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        SessionRow(
                            session: session,
                            celebrating: hub.celebrating.contains(session.id)
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                // Working agents = Rocky thinking/snacking; quiet = patrol.
                BottomRocky(anyRunning: hub.sessions.contains { $0.status == .running })
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
            }
            Color.clear.frame(height: 8)
        }
    }
}

/// The token crystal: Rocky's food, and the icon for token counters.
struct TokenIcon: View {
    let size: CGFloat

    private static let image: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "token", withExtension: "png", subdirectory: "Art"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.8))
                .foregroundStyle(Palette.green)
        }
    }
}

/// Physical press: shrinks while the mouse is down, springs back on release.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .animation(.spring(duration: 0.15, bounce: 0.4), value: configuration.isPressed)
    }
}

/// Makes any Rocky sprite poke-able: click → happy hop + trill.
private struct PokeableModifier: ViewModifier {
    @State private var poked = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(poked ? 1.3 : 1)
            .rotationEffect(.degrees(poked ? -8 : 0))
            .animation(.spring(duration: 0.25, bounce: 0.65), value: poked)
            .onTapGesture {
                guard !poked else { return }
                poked = true
                RockyVoice.shared.poke()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    poked = false
                }
            }
    }
}

extension View {
    func pokeable() -> some View {
        modifier(PokeableModifier())
    }
}

/// The bottom-strip Rocky: patrols when idle; while agents work he
/// alternates between thinking and snacking on a token crystal. Poking him
/// startles him (one-shot reaction) into a sprint before settling down.
struct BottomRocky: View {
    let anyRunning: Bool
    @State private var reactUntil: Date?
    @State private var runBurstUntil: Date?

    private static let reactDuration = 0.7
    private static let sprintDuration = 2.8

    /// Rocky's inner monologue while the agents work. Rotates with his mood.
    private static let musings = [
        "Rocky thinks...",
        "Rocky watches the agents...",
        "Rocky likes rocks",
        "Rocky counts tokens...",
        "Rocky smells good code",
        "Rocky vibes...",
        "Rocky says: amaze!",
        "Rocky asks: question?",
        "Rocky chews a crystal...",
        "Rocky hums in chords...",
        "Rocky guards the notch...",
        "Rocky dreams of astrophage...",
        "Rocky waits, like a rock",
        "Rocky read that somewhere",
        "Rocky trusts, but verifies",
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let now = timeline.date
            Group {
                if let until = reactUntil, until > now {
                    HStack {
                        Spacer()
                        RockyOneShot(prefix: "react", fallback: "rocky-alert", duration: Self.reactDuration, size: 26)
                        Spacer()
                    }
                } else if let until = runBurstUntil, until > now {
                    WalkingRocky(size: 24, speed: 110, fps: 14)
                } else if anyRunning {
                    // Alternate moods every 9s: think, then snack. The musing
                    // rotates on the same clock (prime stride ≈ shuffled).
                    let slot = Int(now.timeIntervalSinceReferenceDate / 9)
                    let thinking = slot % 2 == 0
                    let musing = Self.musings[(slot * 7) % Self.musings.count]
                    HStack(spacing: 8) {
                        Spacer()
                        RockyAnimatedSprite(
                            prefix: thinking ? "think" : "eat",
                            fallback: "south",
                            fps: thinking ? 6 : 8,
                            size: 24
                        )
                        .onTapGesture { startle() }
                        Text(musing)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.inkTertiary)
                            .id(musing)
                            .transition(.opacity)
                        Spacer()
                    }
                    .animation(.easeInOut(duration: 0.4), value: musing)
                } else {
                    WalkingRocky()
                }
            }
        }
        .frame(height: 26)
    }

    private func startle() {
        RockyVoice.shared.poke()
        let now = Date()
        reactUntil = now.addingTimeInterval(Self.reactDuration)
        runBurstUntil = now.addingTimeInterval(Self.reactDuration + Self.sprintDuration)
    }
}

/// Plays an animation once (no loop), then holds the last frame.
struct RockyOneShot: View {
    let prefix: String
    let fallback: String
    let duration: Double
    let size: CGFloat
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 16.0)) { timeline in
            let frames = RockyAnimatedSprite.loadFrames(prefix: prefix)
            if frames.isEmpty {
                RockySprite(state: fallback, fallback: "south", size: size)
            } else {
                let progress = min(1, timeline.date.timeIntervalSince(start) / duration)
                let index = min(frames.count - 1, Int(progress * Double(frames.count)))
                Image(nsImage: frames[index])
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
        }
        .onAppear { start = Date() }
    }
}

/// Rocky pacing back and forth under the session list, keeping watch.
struct WalkingRocky: View {
    var size: CGFloat = 22
    /// Points per second of patrol speed.
    var speed: Double = 26
    /// Step animation rate; higher when sprinting.
    var fps: Double = 10

    private static var frames: [NSImage] = (0..<16).compactMap { index in
        guard let url = Bundle.main.url(
            forResource: "walk-\(index)", withExtension: "png", subdirectory: "Art"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }

    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            let track = max(1, geo.size.width - size)
            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                // Clock relative to appearance: Rocky always enters at the
                // left edge walking right — no random mid-patrol jump (and no
                // flicker) when the panel expands.
                let t = max(0, timeline.date.timeIntervalSince(start))
                // Triangle wave 0→1→0 across the track.
                let cycle = (t * speed).truncatingRemainder(dividingBy: track * 2)
                let goingRight = cycle < track
                let x = goingRight ? cycle : track * 2 - cycle

                Group {
                    if Self.frames.isEmpty {
                        RockySprite(state: "east", fallback: "south", size: size)
                    } else {
                        let frame = Int(t * fps) % Self.frames.count
                        Image(nsImage: Self.frames[frame])
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: size, height: size)
                    }
                }
                .scaleEffect(x: goingRight ? 1 : -1, y: 1)
                .pokeable()
                .offset(x: x)
            }
        }
        .frame(height: size)
        .onAppear { start = Date() }
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
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h\(minutes % 60 > 0 ? "\(minutes % 60)m" : "")"
    }
}

/// Quiet row for sessions that don't need attention (dot + name + chips).
struct SessionRow: View {
    let session: AgentSession
    var celebrating = false
    @State private var hovering = false

    private var statusColor: Color { Palette.status(session.status) }

    var body: some View {
        HStack(spacing: 10) {
            if celebrating {
                RockyAnimatedSprite(prefix: "dance", fallback: "rocky-celebrating", fps: 10, size: 24)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.7), radius: 2)
                if session.status == .running {
                    RockyAnimatedSprite(size: 18)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if session.status == .idle {
                    Text("done · click to jump")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.green)
                } else if session.status == .waitingInput {
                    Text("your turn in the terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.amber)
                } else if let action = session.lastAction {
                    ActionTicker(action: action)
                } else if let task = session.task {
                    Text("You: \(task)")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
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
        .onTapGesture {
            RockyVoice.shared.tap()
            TerminalFocus.focus(session: session)
        }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
        .animation(.easeInOut(duration: 0.25), value: session.lastAction)
        .animation(.spring(duration: 0.3, bounce: 0.5), value: celebrating)
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
                        .pokeable()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.projectName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        if let task = session.task {
                            Text("You: \(task)")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.inkSecondary)
                                .lineLimit(1)
                        }
                        Text("Rocky asks: \(pending.toolName)?")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.amber)
                    }
                    Spacer(minLength: 8)
                    Chip(text: SessionMeta.agentLabel(session))
                    if let terminal = SessionMeta.terminalLabel(session) {
                        Chip(text: terminal)
                    }
                }
                if let diff = EditDiff.from(toolName: pending.toolName, input: pending.toolInput) {
                    DiffPreview(diff: diff)
                } else {
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
                }
                HStack(spacing: 7) {
                    ActionButton(title: "Approve", style: .fill(Palette.green)) {
                        RockyVoice.shared.approve()
                        hub.decide(requestId: pending.requestId, decision: .allow)
                    }
                    ActionButton(title: "Deny", style: .tint(Palette.red)) {
                        RockyVoice.shared.deny()
                        hub.decide(requestId: pending.requestId, decision: .deny)
                    }
                    ActionButton(title: "In terminal", style: .neutral) {
                        RockyVoice.shared.tap()
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

/// Vibe-Island-style diff block: context dim, − red, + green, count footer.
struct DiffPreview: View {
    let diff: EditDiff
    static let maxLines = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.lines.prefix(Self.maxLines).enumerated()), id: \.offset) { _, line in
                diffRow(line)
            }
            HStack(spacing: 6) {
                if diff.additions > 0 {
                    Text("+\(diff.additions)").foregroundStyle(Palette.green)
                }
                if diff.removals > 0 {
                    Text("−\(diff.removals)").foregroundStyle(Palette.red)
                }
                if diff.lines.count > Self.maxLines {
                    Text("· \(diff.lines.count - Self.maxLines) more lines")
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func diffRow(_ line: EditDiff.Line) -> some View {
        let (prefix, text, color, background): (String, String, Color, Color) = {
            switch line {
            case .context(let t): (" ", t, Palette.inkTertiary, .clear)
            case .removed(let t): ("−", t, Palette.red, Palette.red.opacity(0.10))
            case .added(let t): ("+", t, Palette.green, Palette.green.opacity(0.10))
            }
        }()
        HStack(spacing: 6) {
            Text(prefix)
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(color == Palette.inkTertiary ? Palette.inkTertiary : Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 2.5)
        .background(background)
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
        .buttonStyle(PressableStyle())
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

/// Rocky alive: cycles bundled animation frames.
struct RockyAnimatedSprite: View {
    var prefix = "idle"
    var fallback = "south"
    var fps: Double = 8
    let size: CGFloat

    private static var cache: [String: [NSImage]] = [:]

    static func loadFrames(prefix: String) -> [NSImage] {
        frames(prefix: prefix)
    }

    private static func frames(prefix: String) -> [NSImage] {
        if let cached = cache[prefix] { return cached }
        let loaded: [NSImage] = (0..<16).compactMap { index in
            guard let url = Bundle.main.url(
                forResource: "\(prefix)-\(index)", withExtension: "png", subdirectory: "Art"
            ) else { return nil }
            return NSImage(contentsOf: url)
        }
        cache[prefix] = loaded
        return loaded
    }

    var body: some View {
        let frames = Self.frames(prefix: prefix)
        if frames.isEmpty {
            RockySprite(state: fallback, fallback: "south", size: size)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / fps)) { timeline in
                let index = Int(timeline.date.timeIntervalSinceReferenceDate * fps)
                    % frames.count
                Image(nsImage: frames[index])
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
