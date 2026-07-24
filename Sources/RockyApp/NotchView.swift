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
        pendingDiffLines: Int = 0,
        pendingOptionRows: Int = 0
    ) -> CGSize {
        if !expanded {
            // Slightly taller than the physical notch so the glass rim on the
            // bottom edge is fully visible below the hardware cutout.
            return CGSize(width: notchWidth + wingWidth * 2, height: notchHeight + 5)
        }
        let card = hasPending
            ? cardHeight + CGFloat(pendingDiffLines) * 21 + CGFloat(pendingOptionRows) * 32
            : 26
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

    /// Something is blocked on the user: an approval card, or an agent that
    /// told us it cannot proceed. The closed notch has to show this — otherwise
    /// the user only learns about it by opening the notch, which is the very
    /// terminal-hunting the app exists to end. Mirrors the menu bar icon rule.
    private var needsAttention: Bool {
        hub.sessions.contains {
            $0.status == .waitingPermission || $0.status == .waitingInput
        }
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
            shape.strokeBorder(
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
                if needsAttention {
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
                        .foregroundStyle(needsAttention ? Color.black : Palette.inkSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(needsAttention ? Palette.amber : Color.white.opacity(0.12))
                        )
                        .breathing(period: needsAttention ? 1.0 : 100)
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
        SessionListView(hub: hub, attention: state.attention)
            .padding(.top, 28)
            .padding(.horizontal, 12)
            .colorScheme(.dark)
    }
}

/// The real notch silhouette: concave flares at the top (where the panel
/// meets the menu bar, like the hardware cutout) and convex rounded bottom
/// corners. The top edge stays straight for seamless fusion.
struct NotchShape: InsettableShape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// false = concave flare (fused with the hardware notch, collapsed);
    /// true = regular convex rounding (floating card, expanded).
    var convexTop: Bool = false
    /// Amount the path is pulled inward on every edge. Used by `strokeBorder`
    /// so the rim is drawn fully inside the bounds — a centered `stroke` would
    /// clip its outer half against the window and read as a broken border.
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> NotchShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
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
    var attention: NotchAttention = .list

    private var totalTokens: Int { hub.sessions.reduce(0) { $0 + $1.tokens } }
    private var totalWork: TimeInterval { hub.sessions.reduce(0) { $0 + $1.activeSeconds } }

    private var completionSession: AgentSession? {
        guard case .completion(let id) = attention else { return nil }
        return hub.sessions.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear.frame(height: 6)
            if !hub.sessions.isEmpty || hub.claudeUsage != nil || hub.codexUsage != nil {
                insightsHeader
            }
            if let done = completionSession {
                CompletionCard(session: done)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.bottom, 4)
            }
            if hub.sessions.isEmpty {
                VStack(spacing: 10) {
                    RockySprite(state: "rocky-sleeping", fallback: "south", size: 64)
                        .pokeable()
                    Text("Rocky on watch. Run claude, codex, grok, or Cursor Agent.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: NotchView.rowHeight + 76)
            } else {
                ForEach(hub.sessions) { session in
                    if session.pending != nil {
                        PendingSessionCard(session: session, hub: hub)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if case .completion(let id) = attention, session.id == id {
                        // Featured as CompletionCard above; skip duplicate row.
                        EmptyView()
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
        .animation(.spring(duration: 0.32, bounce: 0.1), value: attention)
    }

    @ViewBuilder
    private var insightsHeader: some View {
        let hasTokens = SessionMeta.tokens(totalTokens) != nil
        let hasWork = SessionMeta.workTime(totalWork) != nil
        let showUsage = Preferences.showAccountUsage
        let claude = showUsage ? hub.claudeUsage : nil
        let codex = showUsage ? hub.codexUsage : nil
        let hasClaude = claude?.fiveHour != nil
        let hasCodex = codex?.primary != nil
        if hasTokens || hasWork || hasClaude || hasCodex {
            HStack(spacing: 5) {
                if hasTokens || hasWork {
                    TokenIcon(size: 11)
                    if let tokens = SessionMeta.tokens(totalTokens) {
                        Text(tokens).foregroundStyle(Palette.green)
                    }
                    if let work = SessionMeta.workTime(totalWork) {
                        if hasTokens {
                            Text("·").foregroundStyle(Palette.inkTertiary)
                        }
                        Text(work).foregroundStyle(Palette.inkSecondary)
                    }
                }
                if let five = claude?.fiveHour {
                    if hasTokens || hasWork {
                        Text("·").foregroundStyle(Palette.inkTertiary)
                    }
                    HStack(spacing: 3) {
                        AgentLogo(agent: "claude-code", size: 11)
                        Text("\(five.roundedUsedPercentage)% 5h")
                    }
                    .foregroundStyle(
                        five.usedPercentage >= 80 ? Palette.amber : Palette.inkSecondary
                    )
                    .help("Claude account usage")
                }
                if let primary = codex?.primary {
                    if hasTokens || hasWork || hasClaude {
                        Text("·").foregroundStyle(Palette.inkTertiary)
                    }
                    // Sample: logo + "13% 5h" (primary short window)
                    HStack(spacing: 3) {
                        AgentLogo(agent: "codex", size: 11)
                        Text("\(primary.roundedUsedPercentage)% \(primary.label)")
                    }
                    .foregroundStyle(
                        primary.usedPercentage >= 80 ? Palette.amber : Palette.inkSecondary
                    )
                    .help("Codex account usage")
                }
                Spacer()
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }
}

/// Featured "turn done" surface — Rocky celebrates; click jumps to terminal.
struct CompletionCard: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            RockyAnimatedSprite(prefix: "dance", fallback: "rocky-celebrating", fps: 10, size: 28)
                .pokeable()
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("Rocky says: done!")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.green)
                if let action = session.lastAction {
                    Text(action)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            AgentChip(session: session)
            if let terminal = SessionMeta.terminalLabel(session) {
                Chip(text: terminal)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.green.opacity(0.35), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            RockyVoice.shared.tap()
            TerminalFocus.focus(session: session)
        }
        .padding(.vertical, 3)
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

/// A CLI's brand mark, monochrome so it tints with the surrounding text
/// (amber when a quota runs hot, secondary ink otherwise). Falls back to
/// nothing renderable when the agent has no bundled logo — callers show the
/// text label instead.
struct AgentLogo: View {
    let agent: String
    var size: CGFloat = 11

    /// Agent key (as stored on the session) → bundled `logo-<slug>.png`.
    static func slug(for agent: String) -> String? {
        switch agent {
        case "claude-code": return "claude"
        case "codex": return "codex"
        case "grok": return "grok"
        case "cursor": return "cursor"
        case "kimi-code": return "kimi"
        case "opencode": return "opencode"
        default: return nil
        }
    }

    private static var cache: [String: NSImage] = [:]

    private static func image(_ slug: String) -> NSImage? {
        if let hit = cache[slug] { return hit }
        guard let url = Bundle.main.url(
            forResource: "logo-\(slug)", withExtension: "png", subdirectory: "Art"
        ), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[slug] = image
        return image
    }

    var body: some View {
        if let slug = Self.slug(for: agent), let image = Self.image(slug) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
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

/// The agent identity chip: the CLI's monochrome logo, with the name as a
/// hover tooltip. Falls back to a plain text chip for agents we have no logo
/// for, so nothing goes unlabelled.
struct AgentChip: View {
    let session: AgentSession

    var body: some View {
        let label = SessionMeta.agentLabel(session)
        if AgentLogo.slug(for: session.agent) != nil {
            AgentLogo(agent: session.agent, size: 12)
                .foregroundStyle(Palette.inkSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.09))
                )
                .help(label)
        } else {
            Chip(text: label)
        }
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
        switch session.agent {
        case "claude-code": return "Claude"
        case "codex": return "Codex"
        case "grok": return "Grok"
        case "cursor": return "Cursor"
        case "kimi-code": return "Kimi"
        case "opencode": return "OpenCode"
        default: return session.agent.capitalized
        }
    }

    /// Approve-button label. Kimi's hook is deny-only: allowing does not approve
    /// on the user's behalf, it just lets Kimi proceed — so "Continue" is honest
    /// where "Approve" would overpromise. "Block" stays effective.
    static func approveTitle(_ session: AgentSession) -> String {
        session.agent == "kimi-code" ? "Continue" : "Approve"
    }

    /// Host GUI app chip (Warp, Cursor, …). Hidden when it would duplicate
    /// the agent chip — Cursor Agent hosted in Cursor would otherwise show
    /// "Cursor · Cursor".
    static func terminalLabel(_ session: AgentSession) -> String? {
        // Prefer the name the hook classified (Warp / Ghostty / …) — more
        // stable than the localized GUI name and works when PID is gone.
        if let name = session.jumpTarget?.terminalApp, !name.isEmpty {
            if name.caseInsensitiveCompare(agentLabel(session)) == .orderedSame {
                return nil
            }
            return name
        }
        guard let pid = session.terminalAppPid,
              let app = NSRunningApplication(processIdentifier: pid),
              let name = app.localizedName, !name.isEmpty
        else { return nil }
        if name.caseInsensitiveCompare(agentLabel(session)) == .orderedSame {
            return nil
        }
        return name
    }

    /// Label for the "hand off to the host UI" button (Decision.ask).
    /// Cursor is an IDE, not a terminal; keep CLI agents as "In terminal".
    static func askFallbackTitle(_ session: AgentSession) -> String {
        session.agent == "cursor" ? "In IDE" : "In terminal"
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

    /// A finished turn whose closing line asked something. Drawn as a hollow
    /// amber ring: same colour as the filled "waiting on you" dot, so scanning
    /// the list stays one rule — amber means me — with the ring reading as the
    /// lower intensity of that signal rather than a separate concept.
    /// Hint only: see `SessionStore.asksSomething`.
    private var showsQuestionHint: Bool {
        session.status == .idle && session.handoffAsksSomething
    }

    var body: some View {
        HStack(spacing: 10) {
            if celebrating {
                RockyAnimatedSprite(prefix: "dance", fallback: "rocky-celebrating", fps: 10, size: 24)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Group {
                    if showsQuestionHint {
                        Circle()
                            .strokeBorder(Palette.amber, lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                    } else {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                    }
                }
                .shadow(
                    color: (showsQuestionHint ? Palette.amber : statusColor).opacity(0.7),
                    radius: 2
                )
                if session.status == .running {
                    RockyAnimatedSprite(size: 18)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                // The agent's closing words come first when the turn is over:
                // "Want me to commit?" is what tells the user this session
                // needs them, without opening the terminal to find out.
                if session.status == .waitingInput, let message = session.lastAgentMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.amber)
                        .lineLimit(1)
                } else if session.status == .waitingInput {
                    Text("your turn in the terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.amber)
                } else if session.status == .idle, let message = session.lastAgentMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                } else if session.status == .idle {
                    Text("done · click to jump")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.green)
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
            AgentChip(session: session)
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
        let ask = AskUserQuestionRequest.from(toolName: pending.toolName, input: pending.toolInput)
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
                        Text(ask != nil ? "Rocky asks" : "Rocky asks: \(pending.toolName)?")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.amber)
                    }
                    Spacer(minLength: 8)
                    AgentChip(session: session)
                    if let terminal = SessionMeta.terminalLabel(session) {
                        Chip(text: terminal)
                    }
                }
                if let ask {
                    QuestionPicker(request: ask, pending: pending, hub: hub)
                        .id(pending.requestId)
                } else if let diff = EditDiff.from(toolName: pending.toolName, input: pending.toolInput) {
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
                    if ask == nil {
                        ActionButton(title: SessionMeta.approveTitle(session), style: .fill(Palette.green)) {
                            RockyVoice.shared.approve()
                            hub.decide(requestId: pending.requestId, decision: .allow)
                        }
                        ActionButton(title: "Deny", style: .tint(Palette.red)) {
                            RockyVoice.shared.deny()
                            hub.decide(requestId: pending.requestId, decision: .deny)
                        }
                    }
                    // Kimi is deny-only and gated only in auto / yolo, where it
                    // never falls back to a terminal prompt — "In terminal" would
                    // just mean "Continue". Hide it so the card reads Continue / Deny.
                    if session.agent != "kimi-code" {
                        ActionButton(title: SessionMeta.askFallbackTitle(session), style: .neutral) {
                            RockyVoice.shared.tap()
                            hub.decide(requestId: pending.requestId, decision: .ask)
                        }
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

/// AskUserQuestion rendered as tappable option rows: the user answers from
/// the notch and the terminal picker never appears. Multi-question inputs
/// advance one question at a time; multi-select collects then submits.
struct QuestionPicker: View {
    let request: AskUserQuestionRequest
    let pending: PendingPermission
    @ObservedObject var hub: AgentHub

    @State private var index = 0
    @State private var answers: [String: [String]] = [:]
    @State private var selected: Set<String> = []

    private var question: AskUserQuestionRequest.Question {
        request.questions[min(index, request.questions.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(question.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if request.questions.count > 1 {
                    Text("\(index + 1)/\(request.questions.count)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) { position, option in
                QuestionOptionRow(
                    number: position + 1,
                    option: option,
                    selected: selected.contains(option.label)
                ) {
                    choose(option)
                }
            }
            if question.multiSelect {
                ActionButton(title: "Submit", style: .fill(Palette.green)) {
                    guard !selected.isEmpty else { return }
                    advance(with: question.options.map(\.label).filter(selected.contains))
                }
                .opacity(selected.isEmpty ? 0.4 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: index)
    }

    private func choose(_ option: AskUserQuestionRequest.Option) {
        if question.multiSelect {
            RockyVoice.shared.tap()
            if selected.contains(option.label) {
                selected.remove(option.label)
            } else {
                selected.insert(option.label)
            }
        } else {
            advance(with: [option.label])
        }
    }

    private func advance(with labels: [String]) {
        answers[question.text] = labels
        selected = []
        if index + 1 < request.questions.count {
            RockyVoice.shared.tap()
            index += 1
        } else {
            RockyVoice.shared.approve()
            hub.decide(
                requestId: pending.requestId,
                decision: .allow,
                updatedInput: AskUserQuestionRequest.updatedInput(
                    original: pending.toolInput,
                    answers: answers
                )
            )
        }
    }
}

struct QuestionOptionRow: View {
    let number: Int
    let option: AskUserQuestionRequest.Option
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? Color.black : Palette.inkSecondary)
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(selected ? Palette.green : Color.white.opacity(0.10))
                    )
                Text(option.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if let description = option.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        selected ? Palette.green.opacity(0.6) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
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
