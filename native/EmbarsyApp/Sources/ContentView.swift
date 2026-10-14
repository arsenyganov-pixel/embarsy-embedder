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
            // Immediately, not on the next 30s tick: someone who just installed an update
            // opens the window to see what changed, and a banner that arrives half a minute
            // later is one they have already concluded was never coming.
            store.checkInstalledBuild()
            if !store.installManager.isInstalled {
                store.selectedTab = .install
                store.processManager.markAllStopped(message: L("Components are not installed. Run Install first."))
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
        TabDescriptor(tab: .status,     title: L("Status"),     icon: "square.grid.2x2"),
        TabDescriptor(tab: .install,    title: L("Install"),    icon: "square.and.arrow.down"),
        // Right after Status: connecting agents is the next step once the stack is up,
        // before anything there is to monitor.
        TabDescriptor(tab: .howto,      title: L("Connections"), icon: "point.3.connected.trianglepath.dotted"),
        // Next to Connections: once agents are connected, this is what they know.
        TabDescriptor(tab: .memory,     title: L("Memory"),     icon: "brain"),
        // One entry for the code index and its search: its own tabs switch between the three.
        TabDescriptor(tab: .content,    title: L("Code search"), icon: "magnifyingglass"),
        TabDescriptor(tab: .settings,   title: L("Settings"),   icon: "gearshape"),
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
        let inCodeSearch = AppTab.codeSearch.contains(store.selectedTab)
        let active = store.selectedTab == descriptor.tab || (descriptor.tab == .content && inCodeSearch)
        return Button {
            if descriptor.tab == .content {
                if !inCodeSearch { store.selectedTab = store.lastCodeSearchTab }
            } else {
                store.selectedTab = descriptor.tab
            }
        } label: {
            VStack(spacing: 3) {
                // Icons differ in height; a fixed box keeps every title on one baseline.
                Group {
                    if descriptor.tab == .memory {
                        MemoryTabIcon(memory: store.memory, systemName: descriptor.icon, active: active)
                    } else {
                        Image(systemName: descriptor.icon)
                            .font(.system(size: 17))
                            .foregroundStyle(active ? Theme.accent : .secondary)
                    }
                }
                .frame(height: 22)
                // One line always; a longer title (Russian "Подключения") widens its tab
                // instead of wrapping. The bold active weight is reserved invisibly, so a tab
                // doesn't change width when it's selected.
                ZStack {
                    Text(verbatim: descriptor.title).font(.system(size: 11, weight: .semibold)).hidden()
                    Text(verbatim: descriptor.title)
                        .font(.system(size: 11))
                        .fontWeight(active ? .semibold : .regular)
                        .foregroundStyle(active ? .primary : .secondary)
                }
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 74)
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
        case .monitoring, .activity, .content: CodeSearchView()
        case .settings:   SettingsView()
        case .howto:      ConnectionsView()
        case .memory:     MemoryView(memory: store.memory)
        }
    }
}

/// The Memory tab's icon. Orange while Health has Problems — something an agent is missing or
/// getting wrong right now — whichever tab is open; otherwise the usual colours. Watches the
/// memory service itself, which the store doesn't republish.
private struct MemoryTabIcon: View {
    @ObservedObject var memory: MemoryService
    let systemName: String
    let active: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17))
            .foregroundStyle(memory.hasProblems ? Color.orange : (active ? Theme.accent : Color.secondary))
            .padding(4)
            .contentShape(Rectangle())
            .chipHelp(verbatim: memory.hasProblems
                       ? L("Memory has \(memory.problemCount) problems: an agent is missing something or getting it wrong right now. See Memory → Health.\n\nOrange — Health has problems. Usual colour — no problems; warnings and notes, if any, are in Memory → Health.")
                       : L("Memory: no problems.\n\nOrange — Health has problems. Usual colour — no problems; warnings and notes, if any, are in Memory → Health."))
            .padding(-4)
    }
}
