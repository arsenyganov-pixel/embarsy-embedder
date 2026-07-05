import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: EmbarsyStore
    @Environment(\.openWindow) private var openWindow

    private enum Layout {
        static let popupWidth: CGFloat = 320
        static let dotColumnWidth: CGFloat = 16
        static let statusColumnWidth: CGFloat = 88
    }

    private var displayStatus: ServiceStatus {
        store.installManager.isInstalled ? store.aggregateStatus : .stopped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusRow(title: "Embarsy", status: displayStatus, emphasized: true)

            ForEach(ManagedService.allCases) { service in
                serviceStatusRow(service)
            }

            separator

            MenuBarItem(
                title: store.installManager.isInstalled ? "Open Embarsy" : "Open Install",
                systemImage: "macwindow"
            ) {
                if !store.installManager.isInstalled {
                    store.selectedTab = .install
                }
                openWindow(id: EmbarsyWindowID.main)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            separator

            if store.installManager.isInstalled {
                MenuBarItem(title: "Start All", systemImage: "play") {
                    Task { await store.startAll() }
                }
                MenuBarItem(title: "Stop All", systemImage: "square") {
                    store.processManager.stopAll()
                }
                MenuBarItem(title: "Refresh", systemImage: "arrow.clockwise") {
                    Task { await store.refreshServiceStatuses() }
                }
            } else {
                MenuBarItem(title: "Install", systemImage: "square.and.arrow.down") {
                    store.selectedTab = .install
                    openWindow(id: EmbarsyWindowID.main)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Text("Install components before starting services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            separator

            MenuBarItem(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                store.selectedTab = .settings
                openWindow(id: EmbarsyWindowID.main)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            MenuBarItem(title: "Quit Embarsy", systemImage: "power", shortcut: "⌘Q", danger: true) {
                NSApplication.shared.terminate(nil)
            }

            if !store.preferences.defaultProjectPath.isEmpty {
                separator
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(store.preferences.defaultProjectPath)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(6)
        .frame(width: Layout.popupWidth, alignment: .leading)
        .background {
            ZStack {
                Theme.surface
                BinaryGrainView(active: displayStatus == .running)
            }
            .ignoresSafeArea()
        }
    }

    private func serviceStatusRow(_ service: ManagedService) -> some View {
        statusRow(title: service.title, status: store.serviceStatus(for: service))
    }

    private func statusRow(title: String, status: ServiceStatus, emphasized: Bool = false) -> some View {
        HStack(spacing: 10) {
            statusDot(status)
                .frame(width: Layout.dotColumnWidth, alignment: .center)
            Text(title)
                .font(emphasized ? .callout.weight(.semibold) : .callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(status.title)
                .font(.system(.callout, design: .monospaced).weight(emphasized ? .semibold : .regular))
                .foregroundStyle(Theme.status(status))
                .lineLimit(1)
                .frame(width: Layout.statusColumnWidth, alignment: .trailing)
        }
        .frame(height: emphasized ? 26 : 22)
        .padding(.horizontal, 10)
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }

    private func statusDot(_ status: ServiceStatus) -> some View {
        Circle()
            .fill(Theme.status(status))
            .frame(width: 8, height: 8)
            .overlay(
                Circle().stroke(.white.opacity(0.2), lineWidth: 1)
            )
            .accessibilityLabel(status.title)
    }
}

/// Menu-bar popup row: transparent by default, teal fill + dark ink on hover,
/// matching the design-system hover style. Supports an optional right-aligned
/// mono shortcut and a destructive (red) `danger` style like the mock's `Item`.
private struct MenuBarItem: View {
    let title: String
    var systemImage: String? = nil
    var shortcut: String? = nil
    var isDisabled: Bool = false
    var danger: Bool = false
    let action: () -> Void

    @State private var hovering = false

    private var active: Bool { hovering && !isDisabled }
    private var textColor: Color { active ? Theme.onAccent : (danger ? Color(nsColor: .systemRed) : .primary) }
    private var iconColor: Color { active ? Theme.onAccent : (danger ? Color(nsColor: .systemRed) : .secondary) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 16)
                        .foregroundStyle(iconColor)
                }
                Text(title)
                    .font(.callout)
                    .foregroundStyle(textColor)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(active ? Theme.onAccent.opacity(0.7) : Color(nsColor: .tertiaryLabelColor))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                active ? Theme.accent : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { hovering = $0 }
    }
}
