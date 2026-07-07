import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: EmbarsyStore

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            selectedScreen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            store.refreshInstalledState()
            if !store.installManager.isInstalled {
                store.selectedTab = .install
                store.processManager.markAllStopped(message: "Components are not installed. Run Install first.")
            } else {
                await store.processManager.refreshAll()
                // Detect an orphaned pre-update API still serving :8000 right at launch,
                // so the Status row offers "Update" without a manual Refresh.
                await store.checkAPIVersion()
            }
        }
        .onChange(of: store.installManager.isInstalled) { isInstalled in
            if isInstalled && store.selectedTab == .install && !store.installManager.isInstalling {
                store.selectedTab = .status
            } else if !isInstalled {
                store.selectedTab = .install
            }
        }
        .alert("Repair Embarsy local secrets?", isPresented: $store.localSecretsNeedsRemediation) {
            Button("Recreate secrets") {
                Task { await store.repairLocalSecrets() }
            }
            Button("Not now", role: .cancel) {
                store.dismissLocalSecretsRemediation()
            }
        } message: {
            Text(store.localSecretsMessage)
        }
    }

    // MARK: Custom tab bar (design: icon over label, active pill, binary grain behind)

    private struct TabDescriptor: Hashable {
        let tab: AppTab
        let title: String
        let icon: String
    }

    private let allTabs: [TabDescriptor] = [
        TabDescriptor(tab: .status,     title: "Status",     icon: "square.grid.2x2"),
        TabDescriptor(tab: .install,    title: "Install",    icon: "square.and.arrow.down"),
        TabDescriptor(tab: .monitoring, title: "Monitoring", icon: "chart.line.uptrend.xyaxis"),
        TabDescriptor(tab: .activity,   title: "Activity",   icon: "list.bullet"),
        TabDescriptor(tab: .content,    title: "Content",    icon: "tablecells"),
        TabDescriptor(tab: .settings,   title: "Settings",   icon: "gearshape"),
        TabDescriptor(tab: .howto,      title: "How To",     icon: "questionmark.circle"),
    ]

    // Install is only offered while the stack isn't installed (matches the old TabView).
    private var visibleTabs: [TabDescriptor] {
        allTabs.filter { $0.tab != .install || !store.installManager.isInstalled }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(visibleTabs, id: \.self) { descriptor in
                tabButton(descriptor)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background {
            BinaryGrainView(active: store.aggregateStatus == .running)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }

    private func tabButton(_ descriptor: TabDescriptor) -> some View {
        let active = store.selectedTab == descriptor.tab
        return Button {
            store.selectedTab = descriptor.tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: descriptor.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(active ? Theme.accent : .secondary)
                Text(descriptor.title)
                    .font(.system(size: 11))
                    .fontWeight(active ? .semibold : .regular)
                    .foregroundStyle(active ? .primary : .secondary)
            }
            .frame(width: 74)
            .padding(.vertical, 5)
            .background(
                active ? Color.white.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectedScreen: some View {
        switch store.selectedTab {
        case .status:     StatusView()
        case .install:    InstallView()
        case .monitoring: MonitoringView(monitoring: store.monitoring, contentIndex: store.contentIndex, sysMetrics: store.sysMetrics)
        case .activity:   ActivityView(activity: store.activity)
        case .content:    ContentIndexView(contentIndex: store.contentIndex)
        case .settings:   SettingsView()
        case .howto:      HowToView()
        }
    }
}
