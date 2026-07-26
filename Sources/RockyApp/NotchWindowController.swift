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

/// Where the island is in its open/close cycle. Intent (`wantsExpanded`) and
/// presentation (`revealProgress`) are deliberately separate: the window has to
/// reach its final size *before* the reveal starts, or SwiftUI would animate
/// inside a window that is still collapsed.
enum NotchPhase {
    case collapsed
    case expanding
    case expanded
    case collapsing
}

@MainActor
final class NotchUIState: ObservableObject {
    /// The user (or a pending request) wants the console open.
    @Published var wantsExpanded = false
    /// 0 = collapsed pill, 1 = fully expanded. Single source of truth for the
    /// silhouette, the mask and the hit area, so they cannot drift apart.
    @Published var revealProgress: CGFloat = 0
    @Published var phase: NotchPhase = .collapsed
    @Published var hovering = false
    @Published var attention: NotchAttention = .list
    /// Panel height once fully expanded. Animatable, so a session arriving
    /// while the panel is already open grows the island instead of snapping it.
    @Published var expandedHeight: CGFloat = 0

    /// The console stays mounted through the whole close animation, and gets
    /// mounted before opening so it can be measured. It is torn down only once
    /// the island is fully closed — otherwise Rocky's sprite timelines would
    /// keep animating behind a shut notch.
    var contentMounted: Bool { wantsExpanded || phase != .collapsed }

    /// Session rows the user clicked open to read the full closing message,
    /// accordion-style. Kept here rather than as row-local state so it survives
    /// the console being torn down and remounted around the close animation.
    /// The panel grows to fit on its own: the taller row is measured like any
    /// other content, so nothing here has to predict its height.
    @Published var expandedRows: Set<String> = []

    func toggleRow(_ id: String) {
        if expandedRows.contains(id) {
            expandedRows.remove(id)
        } else {
            expandedRows.insert(id)
        }
    }
}

/// Owns the borderless panel that hugs the notch (or floats as a pill on
/// notchless displays). The panel frame only ever covers what is visible:
/// collapsed it sits over the notch strip, expanded it grows downward.
///
/// The panel never animates its own frame. It jumps to the final size and
/// SwiftUI animates the silhouette growing inside it, so there is exactly one
/// curve in play — two competing ones is what used to make the top edge look
/// like it detached from the hardware notch.
@MainActor
final class NotchWindowController {
    private let panel: NSPanel
    private let hub: AgentHub
    private let state = NotchUIState()
    private let hosting: NSHostingView<NotchView>
    private var observation: AnyCancellable?

    /// Low bounce on purpose: the island settles, it does not wobble. More
    /// overshoot would also ask for height the panel frame cannot draw.
    private static let reveal = Animation.spring(duration: 0.3, bounce: 0.08)
    /// How long the pointer must stay before the panel opens. Crossing the
    /// notch on the way to the menu bar should not fling the console open.
    private static let hoverIntent: TimeInterval = 0.12

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
        var root = NotchView(
            hub: hub,
            state: state,
            notchWidth: m.notchWidth,
            notchHeight: m.hasNotch ? m.notchHeight : 0
        )
        let hosting = NSHostingView(rootView: root)
        self.hosting = hosting
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

        root.onContentHeight = { [weak self] height in
            self?.contentHeightChanged(height)
        }
        hosting.rootView = root

        // Layout outside the current update transaction; never mutate
        // published state from inside this sink (reentrancy crash).
        observation = state.$wantsExpanded
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
    private var hoverIntentTimer: Timer?
    private var hoverConfirmed = false
    private var revealedRequests: Set<String> = []
    private var acknowledgedRequests: Set<String> = []
    private var generation = 0
    private var measuredContentHeight: CGFloat = 0
    /// Whether `measuredContentHeight` describes the console that is mounted
    /// right now. Cleared when it is torn down, so the next opening waits for
    /// a real measurement instead of trusting the previous one.
    private var hasFreshMeasurement = false
    private var screenMetrics: (notchWidth: CGFloat, notchHeight: CGFloat, hasNotch: Bool)?

    private func syncAndLayout() {
        updateHoverIntent()

        let pendingIds = Set(hub.sessions.compactMap { $0.pending?.requestId })
        revealedRequests.formIntersection(pendingIds)
        acknowledgedRequests.formIntersection(pendingIds)
        // Forget accordion state for sessions that are gone, so a reused id
        // never reopens on its own.
        let liveIds = Set(hub.sessions.map(\.id))
        if !state.expandedRows.isSubset(of: liveIds) {
            state.expandedRows.formIntersection(liveIds)
        }
        let hasNewPending = !pendingIds.subtracting(revealedRequests).isEmpty

        if hoverConfirmed {
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

        if hasNewPending || hasUnseenPending || hoverConfirmed || holdingCompletion {
            revealedRequests.formUnion(pendingIds)
            collapseTimer?.invalidate()
            collapseTimer = nil
            if !state.wantsExpanded { state.wantsExpanded = true }
        } else if state.wantsExpanded, collapseTimer == nil {
            scheduleCollapse()
        }
        layout()
    }

    /// Opening waits for the pointer to settle; closing keeps its own debounce.
    private func updateHoverIntent() {
        guard state.hovering else {
            hoverIntentTimer?.invalidate()
            hoverIntentTimer = nil
            hoverConfirmed = false
            return
        }
        // Already inside the open panel: no reason to re-earn the intent.
        if state.wantsExpanded { hoverConfirmed = true }
        guard !hoverConfirmed, hoverIntentTimer == nil else { return }
        hoverIntentTimer = Timer.scheduledTimer(
            withTimeInterval: Self.hoverIntent,
            repeats: false
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hoverIntentTimer = nil
                guard self.state.hovering else { return }
                self.hoverConfirmed = true
                self.syncAndLayout()
            }
        }
    }

    private func scheduleCollapse() {
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.collapseTimer = nil
                if !self.mouseInsidePresentedIsland() {
                    self.state.wantsExpanded = false
                } else {
                    // Hover events got lost during the resize; resync.
                    self.state.hovering = true
                    self.hoverConfirmed = true
                }
            }
        }
    }

    /// Hit-testing against what the user can actually see. Testing the panel
    /// frame instead would report "inside" for the whole expanded box — the
    /// panel would pin itself open from empty space beside the island.
    private func mouseInsidePresentedIsland() -> Bool {
        let point = NSEvent.mouseLocation
        let frame = panel.frame
        let cap = capSize()
        let capRect = CGRect(
            x: frame.midX - cap.width / 2,
            y: frame.maxY - cap.height,
            width: cap.width,
            height: cap.height
        )
        if NSPointInRect(point, capRect) { return true }

        let progress = state.revealProgress
        let visible = cap.height + max(0, state.expandedHeight - cap.height) * progress
        guard visible > cap.height else { return false }
        let bodyWidth = cap.width + max(0, frame.width - cap.width) * progress
        let bodyRect = CGRect(
            x: frame.midX - bodyWidth / 2,
            y: frame.maxY - visible,
            width: bodyWidth,
            height: visible - cap.height
        )
        return NSPointInRect(point, bodyRect)
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

    private func capSize() -> CGSize {
        let m = screenMetrics ?? Self.metrics(for: targetScreen)
        return NotchView.capSize(
            notchWidth: m.notchWidth,
            notchHeight: m.hasNotch ? m.notchHeight : 0
        )
    }

    /// The measured console height, clamped to what the display can actually
    /// show. There is no scroll view, so a panel taller than the screen would
    /// put Approve/Deny below the bottom edge, out of reach.
    private func expandedPanelSize() -> CGSize {
        let screen = targetScreen
        let m = screenMetrics ?? Self.metrics(for: screen)
        let size = NotchView.expandedSize(
            contentHeight: measuredContentHeight,
            notchWidth: m.notchWidth,
            notchHeight: m.hasNotch ? m.notchHeight : 0
        )
        let ceiling = max(capSize().height, screen.frame.maxY - screen.visibleFrame.minY)
        return CGSize(width: size.width, height: min(size.height, ceiling))
    }

    private func frame(for size: CGSize, on screen: NSScreen) -> CGRect {
        CGRect(
            origin: CGPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height
            ),
            size: size
        )
    }

    private func layout() {
        let screen = targetScreen
        let m = Self.metrics(for: screen)
        if screenMetrics == nil
            || screenMetrics!.notchWidth != m.notchWidth
            || screenMetrics!.notchHeight != m.notchHeight
            || screenMetrics!.hasNotch != m.hasNotch {
            screenMetrics = m
            // The shape derives its cap from these; a display change used to
            // leave the view with the metrics captured at init.
            var root = hosting.rootView
            root.notchWidth = m.notchWidth
            root.notchHeight = m.hasNotch ? m.notchHeight : 0
            hosting.rootView = root
        }

        switch state.phase {
        case .collapsing:
            // Re-hovered mid-close: reverse from wherever the reveal currently
            // is. Bumping the generation retires the closing completion, so it
            // can no longer shrink the window under the reopened panel.
            if state.wantsExpanded { beginExpand() }
            // Otherwise the window must not shrink until the reveal has
            // finished playing, or it would snap shut on the first frame.
            return
        case .collapsed:
            if state.wantsExpanded {
                // Wait for a measurement of the console as it is *now*. The
                // last one belongs to the previous opening: sessions have come
                // and gone since, so opening on it starts at the wrong height
                // and visibly corrects itself a frame later.
                if hasFreshMeasurement { beginExpand() }
            } else {
                applyFrame(capSize(), on: screen)
            }
        case .expanding, .expanded:
            if state.wantsExpanded {
                applyExpandedFrame(on: screen)
            } else {
                beginCollapse()
            }
        }
    }

    private func applyFrame(_ size: CGSize, on screen: NSScreen) {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        let target = frame(for: size, on: screen)
        guard target != panel.frame else { return }
        panel.setFrame(target, display: true)
    }

    private func applyExpandedFrame(on screen: NSScreen) {
        let size = expandedPanelSize()
        applyFrame(size, on: screen)
        guard abs(state.expandedHeight - size.height) > 0.5 else { return }
        // The target moved — content grew or shrank, or a late measurement
        // landed mid-open. Retarget on the same curve; assigning it outright
        // while the reveal is in flight is what made the panel stutter.
        withAnimation(Self.reveal) { state.expandedHeight = size.height }
    }

    private func beginExpand() {
        generation += 1
        let generation = self.generation
        let screen = targetScreen
        let size = expandedPanelSize()

        state.phase = .expanding
        collapseTimer?.invalidate()
        collapseTimer = nil
        state.expandedHeight = size.height
        applyFrame(size, on: screen)
        // Push the resize through the view tree now rather than waiting for the
        // next display cycle to get around to it.
        panel.contentView?.layoutSubtreeIfNeeded()

        startReveal(generation: generation, width: size.width, attempt: 0)
    }

    /// The silhouette derives its width from the view's own bounds, so revealing
    /// before SwiftUI has adopted the resized window animates a narrow island
    /// inside a wide panel for a frame or two — the stutter only ever seen on
    /// the first open, since reopening mid-close never shrank the window and so
    /// has no resize to wait for.
    private func startReveal(generation: Int, width: CGFloat, attempt: Int) {
        guard generation == self.generation, state.wantsExpanded else { return }
        // Bail out rather than stall: a late reveal beats a panel that never
        // opens if the bounds never arrive.
        if hosting.bounds.width + 0.5 < width, attempt < 5 {
            DispatchQueue.main.async { [weak self] in
                self?.startReveal(generation: generation, width: width, attempt: attempt + 1)
            }
            return
        }
        withAnimation(Self.reveal, completionCriteria: .removed) {
            state.revealProgress = 1
        } completion: { [weak self] in
            guard let self,
                  generation == self.generation,
                  self.state.wantsExpanded else { return }
            self.state.phase = .expanded
        }
    }

    private func beginCollapse() {
        generation += 1
        let generation = self.generation
        state.phase = .collapsing

        withAnimation(Self.reveal, completionCriteria: .removed) {
            state.revealProgress = 0
        } completion: { [weak self] in
            guard let self, generation == self.generation else { return }
            // Reopened mid-collapse: the newer transition owns the panel now.
            guard !self.state.wantsExpanded else { return }
            self.state.phase = .collapsed
            // The console unmounts with the phase; its height belongs to a
            // layout that no longer exists.
            self.hasFreshMeasurement = false
            self.applyFrame(self.capSize(), on: self.targetScreen)
            self.settleHoverAfterShrink()
        }
    }

    /// Reconcile hover with the real pointer after the panel shrinks.
    ///
    /// The window just moved out from under the pointer, and AppKit sends no
    /// mouse-exit to a view that was pulled away rather than left: SwiftUI's
    /// last word stays `hovering = true` with nothing able to contradict it,
    /// since the pointer is no longer over the panel at all. The next sync then
    /// reads that stale flag as intent and reopens the console from empty
    /// space. Ask where the pointer actually is instead of trusting the last
    /// event we happened to receive.
    private func settleHoverAfterShrink() {
        let inside = mouseInsidePresentedIsland()
        if state.hovering != inside { state.hovering = inside }
        if !inside {
            hoverConfirmed = false
            hoverIntentTimer?.invalidate()
            hoverIntentTimer = nil
        }
    }

    /// The console reports its true height from SwiftUI layout.
    private func contentHeightChanged(_ raw: CGFloat) {
        guard raw.isFinite, raw > 0 else { return }
        let scale = targetScreen.backingScaleFactor
        let height = (raw * scale).rounded(.up) / scale
        let wasStale = !hasFreshMeasurement
        hasFreshMeasurement = true
        // The staleness check has to come first: remounting to the very same
        // height is common, and skipping it on the epsilon test alone would
        // leave the panel waiting for a measurement that never differs.
        guard wasStale || abs(height - measuredContentHeight) >= 1 / scale else { return }
        measuredContentHeight = height
        // Measurement happens during a view update; resize on the next turn.
        DispatchQueue.main.async { [weak self] in self?.layout() }
    }

    /// Expand when a permission arrives so it's visible without hover.
    func revealPending() {
        state.attention = .list
        state.wantsExpanded = true
    }

    /// Brief auto-expand completion card after a turn finishes.
    func revealCompletion(sessionId: String) {
        guard Preferences.showCompletionCards else { return }
        // Don't interrupt an open permission card.
        if hub.sessions.contains(where: { $0.pending != nil }) { return }
        state.attention = .completion(sessionId: sessionId)
        state.wantsExpanded = true
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
