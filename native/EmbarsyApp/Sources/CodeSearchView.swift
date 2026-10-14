import SwiftUI

/// The second half of Embarsy next to Memory: the code index agents search by meaning. Its
/// three screens — what's indexed, the searches made, the load on the Mac — are its tabs.
struct CodeSearchView: View {
    @EnvironmentObject private var store: EmbarsyStore

    private struct Item: Identifiable {
        let tab: AppTab
        let title: String
        var id: AppTab { tab }
    }

    private var items: [Item] {
        [Item(tab: .content, title: L("Code index")),
         Item(tab: .activity, title: L("Search requests")),
         Item(tab: .monitoring, title: L("Load"))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                BrandedHeader(title: "Code search", subtitle: "Your projects, indexed so agents find code by meaning")
                HStack(spacing: 2) {
                    ForEach(items) { tabButton($0) }
                }
            }
            .padding(.horizontal, Theme.padScreen)
            .padding(.top, Theme.padScreen)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
            .zIndex(1)

            Group {
                switch store.selectedTab {
                case .activity: ActivityView(activity: store.activity)
                case .monitoring: MonitoringView(monitoring: store.monitoring, contentIndex: store.contentIndex, sysMetrics: store.sysMetrics)
                default: ContentIndexView(contentIndex: store.contentIndex)
                }
            }
            .environment(\.embeddedScreen, true)
        }
        .onChange(of: store.selectedTab) { tab in
            if AppTab.codeSearch.contains(tab) { store.lastCodeSearchTab = tab }
        }
    }

    private func tabButton(_ item: Item) -> some View {
        let selected = store.selectedTab == item.tab
        return Button { store.selectedTab = item.tab } label: {
            Text(item.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                .background {
                    if selected {
                        TabShape(radius: 8, closed: true).fill(Color(nsColor: .windowBackgroundColor)).padding(.bottom, -1)
                    }
                }
                .overlay {
                    if selected { TabShape(radius: 8, closed: false).stroke(Theme.separator, lineWidth: 1) }
                }
        }
        .buttonStyle(.plain)
    }
}
