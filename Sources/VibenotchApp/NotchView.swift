import SwiftUI
import VibenotchCore

/// The black shape that hugs the notch. Collapsed: status dots in "wings"
/// beside the notch. Expanded: session list with the approval card.
struct NotchView: View {
    @ObservedObject var hub: AgentHub
    @ObservedObject var state: NotchUIState

    static let expandedWidth: CGFloat = 400
    static let rowHeight: CGFloat = 44
    static let cardHeight: CGFloat = 96
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
        let rows = CGFloat(max(sessionCount, 1)) * rowHeight
        let card: CGFloat = hasPending ? cardHeight : 0
        let height = notchHeight + rows + card + 16
        return CGSize(
            width: max(expandedWidth, notchWidth + wingWidth * 2),
            height: min(height, 480)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.expanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(shape.fill(Color.black))
        .onHover { hovering in
            // Expansion/collapse authority lives in NotchWindowController;
            // the view only reports raw hover.
            if state.hovering != hovering { state.hovering = hovering }
        }
    }

    private var shape: some Shape {
        UnevenRoundedRectangle(
            cornerRadii: .init(bottomLeading: 14, bottomTrailing: 14),
            style: .continuous
        )
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        HStack {
            Spacer()
            HStack(spacing: 5) {
                if hub.sessions.isEmpty {
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 5, height: 5)
                } else {
                    ForEach(hub.sessions.prefix(6)) { session in
                        StatusDot(status: session.status)
                    }
                }
            }
            .padding(.trailing, 14)
            .frame(width: Self.wingWidth, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 8)
            if hub.sessions.isEmpty {
                Text("nenhuma sessão ativa")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
            } else {
                ForEach(hub.sessions) { session in
                    SessionRow(session: session, hub: hub)
                }
            }
            Color.clear.frame(height: 8)
        }
        .padding(.top, 30)
        .padding(.horizontal, 14)
        .colorScheme(.dark)
    }
}

struct StatusDot: View {
    let status: AgentSession.Status

    var color: Color {
        switch status {
        case .running: .green
        case .waitingPermission: .orange
        case .waitingInput: .yellow
        case .idle: .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.8), radius: 2)
    }
}

struct SessionRow: View {
    let session: AgentSession
    @ObservedObject var hub: AgentHub

    var statusText: String {
        switch session.status {
        case .running: "rodando"
        case .waitingPermission: "pedindo permissão"
        case .waitingInput: "esperando você"
        case .idle: "terminou"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(status: session.status)
                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    TerminalFocus.focus(session: session)
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("ir para o terminal")
            }
            .frame(height: NotchView.rowHeight - 14)

            if let pending = session.pending {
                PermissionCard(pending: pending, hub: hub)
            }
        }
    }
}

struct PermissionCard: View {
    let pending: PendingPermission
    @ObservedObject var hub: AgentHub

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(pending.toolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Text(pending.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                decisionButton("Aprovar", tint: .green, decision: .allow)
                decisionButton("Negar", tint: .red, decision: .deny)
                decisionButton("No terminal", tint: .gray, decision: .ask)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .padding(.bottom, 6)
    }

    private func decisionButton(_ title: String, tint: Color, decision: Decision) -> some View {
        Button {
            hub.decide(requestId: pending.requestId, decision: decision)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.25)))
                .foregroundStyle(tint == .gray ? Color.white.opacity(0.8) : tint)
        }
        .buttonStyle(.plain)
    }
}
