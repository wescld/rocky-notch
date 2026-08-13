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
    /// Reports the expanded content's true height to the window controller.
    /// A closure rather than published state: measurement happens during a view
    /// update, and mutating an `@ObservableObject` from there is the reentrancy
    /// the controller's own subscription already goes out of its way to avoid.
    var onContentHeight: (CGFloat) -> Void = { _ in }
    /// Lets the session count travel between the resting and open cap layouts.
    @Namespace private var capNamespace

    static let expandedWidth: CGFloat = 560
    static let rowHeight: CGFloat = 40
    static let backgroundRowHeight: CGFloat = 20
    /// A fan-out can be a dozen agents and the panel has no scroll, so the
    /// nested rows are capped and the remainder is counted, never dropped.
    static let maxBackgroundRows = 4
    /// The cap once the user opens the group, which is a wider allowance for
    /// something they explicitly asked to see — not an unlimited one. The
    /// panel is clamped to the display and cannot scroll, so a fan-out of
    /// thirty would push the rows below it off the bottom edge; past this the
    /// remainder keeps being grouped, exactly as it is when closed.
    static let maxExpandedBackgroundRows = 12
    static let wingWidth: CGFloat = 78

    /// The pill fused with the notch. Also the cap of the expanded island:
    /// this size is identical in every state, which is what keeps the top edge
    /// from ever appearing to move.
    static func capSize(notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        // Slightly taller than the physical notch so the glass rim on the
        // bottom edge is fully visible below the hardware cutout.
        CGSize(width: notchWidth + wingWidth * 2, height: notchHeight + 5)
    }

    /// Panel size for a given measured content height. The height is measured,
    /// never guessed: a pending card's height depends on its diff, its question
    /// count and how its chips wrap, and every formula that tried to predict it
    /// silently clipped the overflow.
    static func expandedSize(
        contentHeight: CGFloat,
        notchWidth: CGFloat,
        notchHeight: CGFloat
    ) -> CGSize {
        let cap = capSize(notchWidth: notchWidth, notchHeight: notchHeight)
        return CGSize(
            width: max(expandedWidth, cap.width),
            height: cap.height + max(0, contentHeight)
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

    /// Drives Rocky in the closed cap, which is the only thing the user sees
    /// without opening the notch — so it has to count delegated work too.
    /// Showing him asleep over three running agents is the exact "nothing is
    /// happening" this change exists to fix, surviving where it is most seen.
    private var anyRunning: Bool {
        hub.sessions.contains { $0.status == .running || $0.status == .delegating }
    }

    private var cap: CGSize {
        Self.capSize(notchWidth: notchWidth, notchHeight: notchHeight)
    }

    /// How much of the panel's height the silhouette currently occupies.
    private func visibleFraction(of total: CGFloat) -> CGFloat {
        guard total > 0 else { return 1 }
        let visible = min(
            cap.height + max(0, state.expandedHeight - cap.height) * state.revealProgress,
            total
        )
        return max(0.01, visible / total)
    }

    private var silhouette: NotchShape {
        NotchShape(
            progress: state.revealProgress,
            capWidth: cap.width,
            capHeight: cap.height,
            expandedHeight: state.expandedHeight
        )
    }

    var body: some View {
        let shape = silhouette
        // GeometryReader anchors its content at the top-left and lets it
        // overflow, which is exactly what the reveal needs. A plain
        // `.frame(alignment: .top)` does not: the window resize and SwiftUI's
        // layout pass never land on the same frame, and while the panel is
        // still collapsed the stack gets a shorter proposal, spills in both
        // directions and rides up over the cap for a frame or two.
        GeometryReader { _ in
            VStack(spacing: 0) {
                // The wings never unmount: Rocky and the session chip live in
                // the cap in every state, so opening the panel grows a console
                // underneath them instead of swapping one surface for another.
                capContent
                    .frame(height: cap.height)
                if state.contentMounted {
                    expandedContent
                        // The mask clips drawing, not hit-testing: without this
                        // a click in the not-yet-revealed region would hit an
                        // Approve button the user cannot see.
                        .allowsHitTesting(state.phase == .expanded)
                }
            }
            // Natural height, never the height the panel currently happens
            // to be, so the console is laid out once and simply revealed.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(shape.fill(.black))
        .clipShape(shape)
        // Liquid-glass lip: a light rim that only exists on the lateral
        // and bottom edges (clear at the top, so the fusion with the
        // physical notch stays seamless) — reads as a glass edge
        // catching light.
        .overlay(
            GeometryReader { geo in
                // The gradient spans the *visible* silhouette, not the panel
                // bounds. Measured over the full height, the bottom rim would
                // sample the middle of the ramp while the island is still
                // growing and the lip would fade in instead of tracking the
                // bottom edge.
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.16), location: 0.10),
                            .init(color: .white.opacity(0.20), location: 0.55),
                            .init(color: .white.opacity(0.30), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: visibleFraction(of: geo.size.height))
                    ),
                    lineWidth: 1
                )
            }
        )
        .compositingGroup()
        // Hover only counts inside the silhouette, never in the transparent
        // area the window keeps around it while the island is still growing.
        .contentShape(shape)
        .onHover { hovering in
            // Expansion/collapse authority lives in NotchWindowController;
            // the view only reports raw hover.
            if state.hovering != hovering { state.hovering = hovering }
        }
    }

    // MARK: - Cap

    /// Width of the cap strip right now. It tracks the silhouette so the
    /// wings ride the growing edges instead of staying bunched in the middle.
    private var capBarWidth: CGFloat {
        cap.width + max(0, Self.expandedWidth - cap.width) * state.revealProgress
    }

    /// The stats only exist in the space the opening reveals, so they come in
    /// late and never crowd the closed pill.
    private var insightsOpacity: Double {
        Double(max(0, min(1, (state.revealProgress - 0.55) / 0.35)))
    }

    /// Usable width on each side of the hardware cutout. Anything drawn behind
    /// the notch simply does not exist to the user — the framebuffer keeps it,
    /// the panel does not show it — so each wing is clamped to the strip beside
    /// it and drops its optional parts rather than sliding under the cutout.
    private var sideWidth: CGFloat {
        max(0, (capBarWidth - notchWidth) / 2 - capInset)
    }

    /// Breathing room measured from the *visible* wall, not the panel edge.
    /// The concave flare carves inward and grows as the island opens, so a
    /// constant padding leaves Rocky flush against the edge once open.
    private var capInset: CGFloat {
        let flare = NotchShape.restFlare
            + (NotchShape.openFlare - NotchShape.restFlare) * state.revealProgress
        return flare + Self.capPadding
    }

    /// Tighter than the body's, to buy the stats a few points beside a wide
    /// hardware cutout.
    static let capPadding: CGFloat = 12

    /// At rest the cap is the pill it always was — Rocky on one wing, the count
    /// on the other, the hardware notch between them. The stats layout only
    /// belongs to the opened island, and `matchedGeometryEffect` carries the
    /// count across so it travels instead of jumping.
    private var capContent: some View {
        Group {
            if state.revealProgress < 0.5 {
                restingWings
            } else {
                openWings
            }
        }
        .frame(width: capBarWidth)
        .frame(maxHeight: .infinity)
    }

    private var restingWings: some View {
        HStack(spacing: 0) {
            rockyWing
            Spacer(minLength: 8)
            countChip
                .matchedGeometryEffect(id: "count", in: capNamespace)
                .padding(.trailing, capInset)
        }
    }

    private var openWings: some View {
        HStack(spacing: 0) {
            // Same rule as the right strip: `fixedSize` pins Rocky, never the
            // row, or the ViewThatFits beside him is offered unbounded width
            // and stops shedding. Horizontal only — he still stretches
            // vertically to stay centred in the cap.
            HStack(spacing: 9) {
                rockyWing
                    .fixedSize(horizontal: true, vertical: false)
                // Sheds the work time, then the tokens, on narrower notches.
                ViewThatFits(in: .horizontal) {
                    capStats(includeWork: true)
                    capStats(includeWork: false)
                    EmptyView()
                }
                .transition(.opacity)
            }
            .frame(width: sideWidth + capInset, alignment: .leading)

            Spacer(minLength: 0)

            // Account limits and the count share the right strip; the count
            // keeps the wing it holds at rest, so it never travels on opening.
            // The middle is deliberately left empty — the cutout covers it.
            // `fixedSize` belongs on the count alone, never on the row: applied
            // to the row it proposes an unbounded width to its children, and a
            // ViewThatFits offered unbounded width concludes its widest option
            // fits every time. It would never degrade, and the overflow would
            // spill past the trailing alignment straight under the cutout.
            HStack(spacing: 9) {
                ViewThatFits(in: .horizontal) {
                    capUsage(.full)
                    capUsage(.hottestAgent)
                    capUsage(.hottestSession)
                    EmptyView()
                }
                .transition(.opacity)
                countChip
                    .fixedSize()
                    .matchedGeometryEffect(id: "count", in: capNamespace)
            }
            .padding(.trailing, capInset)
            .frame(width: sideWidth + capInset, alignment: .trailing)
        }
    }

    private var rockyWing: some View {
        rockyGlyph
            .pokeable()
            .animation(.spring(duration: 0.3, bounce: 0.5), value: hub.celebrating)
            .padding(.leading, capInset)
            .padding(.bottom, 1)
            // Centred in the cap strip: without this the sprite sits flush with
            // the top edge and its head gets clipped by the screen.
            .frame(maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var rockyGlyph: some View {
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

    /// Session count chip; amber while something needs the user.
    @ViewBuilder
    private var countChip: some View {
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

    /// Tokens burned and time actually worked, across tracked sessions.
    @ViewBuilder
    private func capStats(includeWork: Bool) -> some View {
        let tokens = SessionMeta.tokens(totalTokens)
        let work = includeWork ? SessionMeta.workTime(totalWork) : nil
        if tokens != nil || work != nil {
            HStack(spacing: 5) {
                TokenIcon(size: 11)
                if let tokens {
                    Text(tokens).foregroundStyle(Palette.green)
                }
                if let work {
                    if tokens != nil {
                        Text("·").foregroundStyle(Palette.inkTertiary)
                    }
                    Text(work).foregroundStyle(Palette.inkSecondary)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .fixedSize()
        }
    }

    /// How much of the account strip the space beside the notch can hold.
    /// Sheds an agent first, then the weekly figures. What survives a squeeze
    /// is whichever account is closest to running out, never a fixed one:
    /// dropping a spent account to keep a calm one would hide the very figure
    /// the colour rule exists to raise.
    private enum UsageDensity {
        case full
        case hottestAgent
        case hottestSession
    }

    @ViewBuilder
    private func capUsage(_ density: UsageDensity) -> some View {
        let showUsage = Preferences.showAccountUsage
        let claude = showUsage ? hub.claudeUsage : nil
        let codex = showUsage ? hub.codexUsage : nil
        let claudeSession = claude?.fiveHour
        let codexSession = codex?.primary
        let weeklyFits = density != .hottestSession

        // Rank by each account's own worst window, then let the ranking decide
        // only who survives — never the running order. Chips that reshuffle as
        // the figures drift would cost the glance-and-know the strip is for.
        let bothFit = density == .full
        let claudeKeeps = UsageHeat.keepsFirst(
            claudeSession == nil
                ? nil
                : UsageHeat.peak([claudeSession?.usedPercentage, claude?.sevenDay?.usedPercentage]),
            over: codexSession == nil
                ? nil
                : UsageHeat.peak([codexSession?.usedPercentage, codex?.secondary?.usedPercentage])
        )

        HStack(spacing: 5) {
            if let claudeSession, bothFit || claudeKeeps {
                AccountUsageChip(
                    claude: claudeSession,
                    weekly: weeklyFits ? claude?.sevenDay : nil
                )
            }
            // No dot between the agents here, unlike the panel: each chip opens
            // with its own logo, which separates them well enough, and the
            // glyph costs more width than the strip beside a 209pt cutout can
            // spare once both windows show.
            if let codexSession, bothFit || !claudeKeeps {
                AccountUsageChip(
                    codex: codexSession,
                    weekly: weeklyFits ? codex?.secondary : nil
                )
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .fixedSize()
    }

    // MARK: - Expanded

    /// Aggregates for the insights header (sessions currently tracked).
    private var totalTokens: Int { hub.sessions.reduce(0) { $0 + $1.tokens } }
    private var totalWork: TimeInterval { hub.sessions.reduce(0) { $0 + $1.activeSeconds } }

    private var expandedContent: some View {
        SessionListView(
            hub: hub,
            attention: state.attention,
            showsInsights: false,
            expandedRows: state.expandedRows,
            onToggleExpand: { state.toggleRow($0) },
            expandedDelegations: state.expandedDelegations,
            onToggleDelegation: { state.toggleDelegation($0) },
            onDismiss: { hub.dismiss(sessionId: $0) }
        )
            .padding(.horizontal, 18)
            .colorScheme(.dark)
            .frame(width: Self.expandedWidth)
            // Report the ideal height rather than accepting whatever the panel
            // currently offers — otherwise the measurement would echo back the
            // window size and the panel could never learn it is too short.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                onContentHeight(height)
            }
    }
}

/// The session console: insights header + rows + pending cards. Shared by
/// the notch panel and the menu bar mode.
struct SessionListView: View {
    @ObservedObject var hub: AgentHub
    var attention: NotchAttention = .list
    /// The notch shows these in its cap strip instead, where the opening
    /// reveals empty space beside the hardware cutout. The menu bar card has
    /// no cap, so it keeps the inline header.
    var showsInsights = true
    /// Accordion rows the user opened, and the toggle. Supplied by the notch
    /// (which resizes the panel to fit); nil in the menu bar, where rows keep
    /// the plain click-to-jump behaviour.
    var expandedRows: Set<String> = []
    var onToggleExpand: ((String) -> Void)? = nil
    /// Sessions whose delegated work is opened past the resting cap, and the
    /// toggle. Same deal as `expandedRows`: only the notch can grow to fit, so
    /// the menu bar card leaves the group closed.
    var expandedDelegations: Set<String> = []
    var onToggleDelegation: ((String) -> Void)? = nil
    /// Clear a finished session from the panel (the row "×").
    var onDismiss: ((String) -> Void)? = nil

    private var totalTokens: Int { hub.sessions.reduce(0) { $0 + $1.tokens } }
    private var totalWork: TimeInterval { hub.sessions.reduce(0) { $0 + $1.activeSeconds } }

    private var completionSession: AgentSession? {
        guard case .completion(let id) = attention else { return nil }
        return hub.sessions.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear.frame(height: 6)
            if showsInsights,
               !hub.sessions.isEmpty || hub.claudeUsage != nil || hub.codexUsage != nil {
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
                        VStack(spacing: 0) {
                            PendingSessionCard(session: session, hub: hub)
                            // A session can be blocked on the user *and* still
                            // have agents running. Dropping the children while
                            // the card is up removed that context at the moment
                            // the user is being asked to decide something.
                            DelegatedRows(
                                session: session,
                                expanded: expandedDelegations.contains(session.id),
                                onToggleExpand: onToggleDelegation.map { toggle in
                                    { toggle(session.id) }
                                }
                            )
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if case .completion(let id) = attention, session.id == id {
                        // Featured as CompletionCard above; skip duplicate row.
                        EmptyView()
                    } else {
                        VStack(spacing: 0) {
                            SessionRow(
                                session: session,
                                celebrating: hub.celebrating.contains(session.id),
                                expanded: expandedRows.contains(session.id),
                                onToggleExpand: onToggleExpand.map { toggle in { toggle(session.id) } },
                                onDismiss: onDismiss.map { dismiss in { dismiss(session.id) } }
                            )
                            DelegatedRows(
                                session: session,
                                expanded: expandedDelegations.contains(session.id),
                                onToggleExpand: onToggleDelegation.map { toggle in
                                    { toggle(session.id) }
                                }
                            )
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                // Working agents = Rocky thinking/snacking; quiet = patrol.
                BottomRocky(anyRunning: hub.sessions.contains {
                    $0.status == .running || $0.status == .delegating
                })
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
                // The panel is not fighting the cutout for width, so both
                // windows always show here — the cap may have had to shed one,
                // and the same figure must not read two ways on one screen.
                if let five = claude?.fiveHour {
                    if hasTokens || hasWork {
                        Text("·").foregroundStyle(Palette.inkTertiary)
                    }
                    AccountUsageChip(claude: five, weekly: claude?.sevenDay)
                }
                if let primary = codex?.primary {
                    if hasTokens || hasWork || hasClaude {
                        Text("·").foregroundStyle(Palette.inkTertiary)
                    }
                    AccountUsageChip(codex: primary, weekly: codex?.secondary)
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

/// One agent's account reading: its logo, the session figure, and — when the
/// caller has room for it — the weekly figure sharing that same logo.
///
/// The window label is dropped once both figures show, and so is the second
/// percent sign: the first one sets the unit for the pair, and on a 209pt
/// cutout that one glyph is the difference between both agents fitting beside
/// the notch and one of them being shed entirely.
///
/// Colour follows the hotter of the two windows, so a spent week warns through
/// a calm session instead of hiding behind it.
struct AccountUsageChip: View {
    private let agent: String
    private let session: Int
    private let sessionHeat: Double
    private let sessionLabel: String
    private let weeklyRounded: Int?
    private let weeklyHeat: Double?
    private let help: String

    init(claude session: ClaudeUsageWindow, weekly: ClaudeUsageWindow?) {
        agent = "claude-code"
        self.session = session.roundedUsedPercentage
        sessionHeat = session.usedPercentage
        sessionLabel = "5h"
        weeklyRounded = weekly?.roundedUsedPercentage
        weeklyHeat = weekly?.usedPercentage
        help = "Claude account usage"
    }

    init(codex session: CodexUsageWindow, weekly: CodexUsageWindow?) {
        agent = "codex"
        self.session = session.roundedUsedPercentage
        sessionHeat = session.usedPercentage
        sessionLabel = session.label
        weeklyRounded = weekly?.roundedUsedPercentage
        weeklyHeat = weekly?.usedPercentage
        help = "Codex account usage"
    }

    var body: some View {
        HStack(spacing: 3) {
            AgentLogo(agent: agent, size: 11)
            if let weeklyRounded {
                Text("\(session)%·\(weeklyRounded)w")
            } else {
                Text("\(session)% \(sessionLabel)")
            }
        }
        .foregroundStyle(
            UsageHeat.isHot([sessionHeat, weeklyHeat])
                ? Palette.amber
                : Palette.inkSecondary
        )
        .help(help)
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
        case "claude-code", "claude": return "claude"
        case "codex": return "codex"
        case "grok": return "grok"
        case "cursor": return "cursor"
        case "kimi-code": return "kimi"
        case "opencode": return "opencode"
        case "agy": return "agy"
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

    /// Fallback subtitle for a session that parked without leaving words.
    static func delegatedSummary(_ session: AgentSession) -> String {
        let count = session.backgroundTasks.count
        return count == 1
            ? "1 running in background"
            : "\(count) running in background"
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
    /// Accordion: whether this row is opened, and the toggle. When the toggle
    /// is nil (menu bar) the row keeps plain click-to-jump.
    var expanded = false
    var onToggleExpand: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    @State private var hovering = false

    /// Finished rows can be cleared from the panel; live ones cannot.
    private var isDismissible: Bool {
        onDismiss != nil && session.status == .idle
    }

    private var statusColor: Color { Palette.status(session.status) }

    /// The closing message that can be read in full by opening the row.
    static func expandableMessage(_ session: AgentSession) -> String? {
        guard session.status == .idle || session.status == .waitingInput,
              let message = session.lastAgentMessage, !message.isEmpty
        else { return nil }
        return message
    }

    private var isExpandable: Bool {
        onToggleExpand != nil && SessionRow.expandableMessage(session) != nil
    }

    private func jump() {
        RockyVoice.shared.tap()
        TerminalFocus.focus(session: session)
    }

    /// A finished turn whose closing line asked something. Drawn as a hollow
    /// amber ring: same colour as the filled "waiting on you" dot, so scanning
    /// the list stays one rule — amber means me — with the ring reading as the
    /// lower intensity of that signal rather than a separate concept.
    /// Hint only: see `SessionStore.asksSomething`.
    private var showsQuestionHint: Bool {
        session.status == .idle && session.handoffAsksSomething
    }

    var body: some View {
        // Alignment stays .center across expand/collapse: switching to .top
        // isn't interpolatable, so the dot and trailing time would jump at the
        // start of the animation instead of gliding with the growth.
        HStack(alignment: .center, spacing: 10) {
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
                if session.status == .running || session.status == .delegating {
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
                        .lineLimit(expanded ? 8 : 1)
                } else if session.status == .waitingInput {
                    Text("your turn in the terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.amber)
                } else if session.status == .delegating, let message = session.lastAgentMessage {
                    // The child rows below say what is running; the agent's
                    // closing line says why the main loop stepped back.
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                } else if session.status == .delegating {
                    Text(SessionMeta.delegatedSummary(session))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.green)
                } else if session.status == .idle, let message = session.lastAgentMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(expanded ? 8 : 1)
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
            // Survives the notch being collapsed to a single row, which is the
            // state the user is in when they glance at it.
            if !session.backgroundTasks.isEmpty {
                Chip(text: "↳\(session.backgroundTasks.count)")
            }
            if let tokens = SessionMeta.tokens(session.tokens) {
                Chip(text: tokens)
            }
            // While the row toggles open on click, the identity chips carry the
            // jump-to-terminal action instead.
            AgentChip(session: session)
                .contentShape(Rectangle())
                .onTapGesture { if isExpandable { jump() } }
                .help(isExpandable ? "Jump to terminal" : "")
            if let terminal = SessionMeta.terminalLabel(session) {
                Chip(text: terminal)
                    .contentShape(Rectangle())
                    .onTapGesture { if isExpandable { jump() } }
                    .help(isExpandable ? "Jump to terminal" : "")
            }
            if isExpandable {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.inkTertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            // Hovering a finished row swaps its elapsed time for a dismiss
            // button, so ghosts can be cleared without waiting on retention.
            if isDismissible, hovering {
                Button(action: { onDismiss?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(width: 18, height: 18)
                        .background(
                            Circle().fill(Color.white.opacity(0.10))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss this session")
            } else {
                Text(SessionMeta.elapsed(session))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, expanded ? 8 : 0)
        .frame(minHeight: NotchView.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Expandable rows toggle open on click (identity chips jump);
            // everything else keeps the plain click-to-jump.
            if isExpandable, let toggle = onToggleExpand {
                RockyVoice.shared.tap()
                toggle()
            } else {
                jump()
            }
        }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
        .animation(.easeInOut(duration: 0.25), value: session.lastAction)
        .animation(.spring(duration: 0.3, bounce: 0.5), value: celebrating)
        .animation(.easeOut(duration: 0.28), value: expanded)
    }
}

/// The work a session handed off, nested under it.
///
/// A subagent belongs to its parent in a way a delegated CLI — its own session,
/// its own row — does not, and flattening them would leave four rows all named
/// after the same project. Every child gets a line: a shell's never moves (no
/// hooks, no transcript to tail), but "what was dispatched" is the question the
/// notch exists to answer, and a stale sentence answers it where a count does
/// not. Past the cap the remainder is grouped, never dropped silently.
///
/// One view, used under a plain row and under a pending card alike, so the two
/// cannot drift apart.
struct DelegatedRows: View {
    let session: AgentSession
    /// Whether the user opened the group, and the toggle. Nil where the
    /// surface cannot resize itself (the menu bar card), which leaves the
    /// resting cap and the grouped line exactly as they were.
    var expanded = false
    var onToggleExpand: (() -> Void)? = nil

    var body: some View {
        let cap = expanded ? NotchView.maxExpandedBackgroundRows : NotchView.maxBackgroundRows
        let drawn = Array(session.backgroundTasks.prefix(cap))
        let grouped = Array(session.backgroundTasks.dropFirst(drawn.count))
        // Open with nothing left over, the line has no count to carry — but it
        // is still the only way back, so it stays as long as there is anything
        // the resting cap would have hidden. A fan-out that finished down to
        // four rows drops it: there is no longer a group to collapse.
        let collapsible = expanded && session.backgroundTasks.count > NotchView.maxBackgroundRows
        ForEach(drawn) { task in
            BackgroundTaskRow(task: task)
        }
        if !grouped.isEmpty || collapsible {
            BackgroundTaskOverflowRow(
                tasks: grouped,
                expanded: expanded,
                onToggle: onToggleExpand
            )
        }
    }
}

/// One piece of work a session handed off. Quieter and narrower than a session
/// row on purpose: it is not somewhere you can jump to, it is something you are
/// being told about — and the eye should read the parent first.
struct BackgroundTaskRow: View {
    // Qualified: SwiftUI ships a `BackgroundTask` of its own.
    let task: RockyCore.BackgroundTask

    var body: some View {
        HStack(spacing: 7) {
            Text("↳")
                .font(.system(size: 10))
                .foregroundStyle(Palette.inkTertiary)
            if let provider = task.providerLabel {
                Text(provider)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
            // The agent wrote this sentence for a human; nothing Rocky could
            // synthesize from the task type would beat it.
            Text(task.title)
                .font(.system(size: 10))
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
            if let action = task.lastAction {
                Text(action)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.green.opacity(0.7))
                    .lineLimit(1)
                    // Gives up its width first: the identity of the work
                    // matters more than the tool it happens to be running.
                    .layoutPriority(-1)
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, 28)
        .padding(.trailing, 10)
        .frame(height: NotchView.backgroundRowHeight)
    }
}

/// Rocky never silently truncates a list it claims to be showing — and where
/// it groups, it still says who is in the group.
///
/// It is also the handle for the group: the only child line with nothing to
/// jump to, so the click is free to open the rest of the fan-out in place. The
/// chevron appears only where the click does something, which is the same rule
/// the session row follows.
struct BackgroundTaskOverflowRow: View {
    let tasks: [RockyCore.BackgroundTask]
    var expanded = false
    var onToggle: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Text("↳")
                .font(.system(size: 10))
                .foregroundStyle(Palette.inkTertiary)
            Text(RockyCore.BackgroundTask.overflowLabel(remaining: tasks, expanded: expanded))
                .font(.system(size: 10))
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
            if onToggle != nil {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.inkTertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, 28)
        .padding(.trailing, 10)
        .frame(height: NotchView.backgroundRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(hovering && onToggle != nil ? 0.05 : 0))
                .padding(.leading, 22)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard let onToggle else { return }
            RockyVoice.shared.tap()
            onToggle()
        }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
        .help(onToggle == nil ? "" : (expanded ? "Show fewer" : "Show every agent"))
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

    /// Every question is laid out, only the current one is shown. The stack
    /// therefore reserves the tallest question's height for the whole sequence,
    /// so the card never resizes under the cursor while the user is clicking
    /// through options — and it does it by real layout, not by counting rows.
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(request.questions.enumerated()), id: \.offset) { position, question in
                questionView(question, at: position)
                    .opacity(position == index ? 1 : 0)
                    .allowsHitTesting(position == index)
                    .accessibilityHidden(position != index)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: index)
    }

    private func questionView(
        _ question: AskUserQuestionRequest.Question,
        at position: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(question.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if request.questions.count > 1 {
                    Text("\(position + 1)/\(request.questions.count)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) { row, option in
                QuestionOptionRow(
                    number: row + 1,
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
