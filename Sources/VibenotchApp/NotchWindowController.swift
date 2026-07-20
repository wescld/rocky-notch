import AppKit
import Combine
import SwiftUI
import VibenotchCore

@MainActor
final class NotchUIState: ObservableObject {
    @Published var expanded = false
    @Published var hovering = false
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

        let root = NotchView(hub: hub, state: state)
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
    private var collapseTimer: Timer?

    private func syncAndLayout() {
        let hasPending = hub.sessions.contains { $0.pending != nil }
        if hasPending || state.hovering {
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
                let hasPending = self.hub.sessions.contains { $0.pending != nil }
                if !mouseInside, !hasPending {
                    self.state.expanded = false
                } else if mouseInside {
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
        let size = NotchView.size(
            expanded: state.expanded,
            sessionCount: hub.sessions.count,
            hasPending: hub.sessions.contains { $0.pending != nil },
            notchWidth: m.notchWidth,
            notchHeight: m.notchHeight
        )
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    /// Expand when a permission arrives so it's visible without hover.
    func revealPending() {
        state.expanded = true
    }
}
