import AppKit
import Combine
import SwiftUI
import RockyCore

/// What the expanded notch is emphasizing right now.
enum NotchAttention: Equatable {
    /// Browse sessions / pending cards inline.
    case list
    /// A turn just finished — show a brief completion card.
    case completion(sessionId: String)
}

@MainActor
final class NotchUIState: ObservableObject {
    @Published var expanded = false
    @Published var hovering = false
    @Published var attention: NotchAttention = .list
}

/// Owns the borderless panel that hugs the notch (or floats as a pill on
/// notchless displays). The panel frame only ever covers what is visible:
/// collapsed it sits over the notch strip, expanded it grows downward.
@MainActor
final class NotchWindowController {
    private let panel: NSPanel
    private let hub: AgentHub
    private let state = NotchUIState()
    private var observation: AnyCancellable?

    init(hub: AgentHub) {
        self.hub = hub

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        self.panel = panel

        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let m = Self.metrics(for: screen)
        let root = NotchView(
            hub: hub,
            state: state,
            notchWidth: m.notchWidth,
            notchHeight: m.hasNotch ? m.notchHeight : 0
        )
        let hosting = NSHostingView(rootView: root)
        // Frame-based layout only: an NSHostingView constrained directly as
        // contentView of a borderless panel enters an update-constraints loop
        // and AppKit aborts. The panel frame is the single size authority.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        let container = NSView()
        container.addSubview(hosting)
        hosting.frame = container.bounds
        panel.contentView = container

        // Layout outside the current update transaction; never mutate
        // published state from inside this sink (reentrancy crash).
        observation = state.$expanded
            .combineLatest(state.$hovering, hub.$store)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                DispatchQueue.main.async { self?.syncAndLayout() }
            }

        syncAndLayout()
        panel.orderFrontRegardless()
    }

    /// Reconciles auto-expand/collapse with pending state, then resizes.
    /// Expanding is immediate; collapsing is debounced and re-checked against
    /// the real mouse position, otherwise the frame change itself generates
    /// hover-exit events and the panel flickers.
    ///
    /// A pending request keeps the panel open until the user has seen it:
    /// hovering the card counts as seeing, so once the mouse leaves (or the
    /// request resolves) the panel may collapse. The card stays available on
    /// re-hover for as long as the request lives.
    private var collapseTimer: Timer?
    private var completionDismissTimer: Timer?
    private var revealedRequests: Set<String> = []
    private var acknowledgedRequests: Set<String> = []

    private func syncAndLayout() {
        let pendingIds = Set(hub.sessions.compactMap { $0.pending?.requestId })
        revealedRequests.formIntersection(pendingIds)
        acknowledgedRequests.formIntersection(pendingIds)
        let hasNewPending = !pendingIds.subtracting(revealedRequests).isEmpty

        if state.hovering {
            acknowledgedRequests.formUnion(pendingIds)
        }
        let hasUnseenPending = !pendingIds.subtracting(acknowledgedRequests).isEmpty

        // Pending always wins over a completion surface.
        if hasNewPending || hasUnseenPending {
            if case .completion = state.attention {
                state.attention = .list
                completionDismissTimer?.invalidate()
                completionDismissTimer = nil
            }
        }

        let holdingCompletion: Bool = {
            if case .completion = state.attention { return true }
            return false
        }()

        if hasNewPending || hasUnseenPending || state.hovering || holdingCompletion {
            revealedRequests.formUnion(pendingIds)
            collapseTimer?.invalidate()
            collapseTimer = nil
            if !state.expanded { state.expanded = true }
        } else if state.expanded, collapseTimer == nil {
            scheduleCollapse()
        }
        layout()
    }

    private func scheduleCollapse() {
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.collapseTimer = nil
                let mouseInside = NSPointInRect(NSEvent.mouseLocation, self.panel.frame)
                if !mouseInside {
                    self.state.expanded = false
                } else {
                    // Hover events got lost during the resize; resync.
                    self.state.hovering = true
                }
            }
        }
    }

    private var targetScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    static func metrics(for screen: NSScreen) -> (notchWidth: CGFloat, notchHeight: CGFloat, hasNotch: Bool) {
        let hasNotch = screen.safeAreaInsets.top > 0
        guard hasNotch,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else {
            return (200, 34, false)
        }
        return (screen.frame.width - left.width - right.width, screen.safeAreaInsets.top, true)
    }

    private func layout() {
        let screen = targetScreen
        let m = Self.metrics(for: screen)
        let pendingDiffLines = hub.sessions
            .compactMap(\.pending)
            .compactMap { EditDiff.from(toolName: $0.toolName, input: $0.toolInput) }
            .map { min($0.lines.count, DiffPreview.maxLines) + 1 }
            .reduce(0, +)
        // The card height is fixed while the picker steps through questions,
        // so reserve room for the tallest one (plus its Submit row).
        let pendingOptionRows = hub.sessions
            .compactMap(\.pending)
            .compactMap { AskUserQuestionRequest.from(toolName: $0.toolName, input: $0.toolInput) }
            .map { request in
                request.questions.map { $0.options.count + ($0.multiSelect ? 1 : 0) }.max() ?? 0
            }
            .reduce(0, +)
        let showingCompletion: Bool = {
            if case .completion = state.attention { return true }
            return false
        }()
        // Completion card replaces one row visually; keep height similar to a pending card.
        let size = NotchView.size(
            expanded: state.expanded,
            sessionCount: max(0, hub.sessions.count - (showingCompletion ? 1 : 0)),
            hasPending: hub.sessions.contains { $0.pending != nil } || showingCompletion,
            notchWidth: m.notchWidth,
            notchHeight: m.notchHeight,
            pendingDiffLines: pendingDiffLines,
            pendingOptionRows: pendingOptionRows
        )
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        let frame = CGRect(origin: origin, size: size)
        guard frame != panel.frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Expand when a permission arrives so it's visible without hover.
    func revealPending() {
        state.attention = .list
        state.expanded = true
    }

    /// Brief auto-expand completion card after a turn finishes.
    func revealCompletion(sessionId: String) {
        guard Preferences.showCompletionCards else { return }
        // Don't interrupt an open permission card.
        if hub.sessions.contains(where: { $0.pending != nil }) { return }
        state.attention = .completion(sessionId: sessionId)
        state.expanded = true
        completionDismissTimer?.invalidate()
        completionDismissTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .completion(let id) = self.state.attention, id == sessionId {
                    self.state.attention = .list
                }
                self.completionDismissTimer = nil
                self.syncAndLayout()
            }
        }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}
