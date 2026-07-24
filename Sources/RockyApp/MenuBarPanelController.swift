import AppKit
import Combine
import SwiftUI
import RockyCore

/// Menu-bar-mode home: the same session console as the notch, in a floating
/// black glass card anchored under the status item.
@MainActor
final class MenuBarPanelController {
    private let panel: NSPanel
    private let hub: AgentHub
    private let hosting: NSHostingView<MenuBarCard>
    private var clickMonitor: Any?
    private var storeObservation: AnyCancellable?

    private(set) var isShown = false

    init(hub: AgentHub, onOpenSettings: @escaping () -> Void = {}) {
        self.hub = hub
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        self.panel = panel

        let hosting = NSHostingView(
            rootView: MenuBarCard(hub: hub, onOpenSettings: onOpenSettings)
        )
        self.hosting = hosting
        panel.contentView = hosting
    }

    func toggle(relativeTo button: NSStatusBarButton?) {
        isShown ? hide() : show(relativeTo: button)
    }

    func show(relativeTo button: NSStatusBarButton?) {
        layout(relativeTo: button)
        panel.orderFrontRegardless()
        isShown = true

        // Resize live while visible (sessions come and go).
        storeObservation = hub.$store
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak button] _ in
                DispatchQueue.main.async { self?.layout(relativeTo: button) }
            }
        // Any click outside dismisses.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }
    }

    func hide() {
        panel.orderOut(nil)
        isShown = false
        storeObservation = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    private func layout(relativeTo button: NSStatusBarButton?) {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var origin = CGPoint(x: 100, y: 100)
        if let button, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(
                button.convert(button.bounds, to: nil)
            )
            origin = CGPoint(
                x: min(
                    buttonFrame.midX - size.width / 2,
                    (buttonWindow.screen?.visibleFrame.maxX ?? buttonFrame.maxX) - size.width - 8
                ),
                y: buttonFrame.minY - size.height - 6
            )
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// The floating card: notch language (black, glass rim), menu bar posture.
struct MenuBarCard: View {
    @ObservedObject var hub: AgentHub
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Rocky")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.inkSecondary)
                Spacer(minLength: 8)
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)

            SessionListView(hub: hub)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(width: 430)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.black)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.22), location: 0),
                                .init(color: .white.opacity(0.12), location: 0.5),
                                .init(color: .white.opacity(0.30), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
        )
        .colorScheme(.dark)
    }
}
