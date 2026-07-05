import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var store: EmbarsyStore
    @State private var filterState = ActivityTypeFilterState()
    @State private var onlyErrors = false
    @State private var typeMenuOpen = false
    private let typeMenuWidth: CGFloat = 200   // fits "Embedding request" without truncating

    private let refreshIntervalNanoseconds: UInt64 = 2_000_000_000

    private var filteredEvents: [ActivityEvent] {
        filterState.filteredEvents(from: store.activity.snapshot.events, onlyErrors: onlyErrors)
    }

    var body: some View {
        // No outer ScrollView: header + footer stay put and the "Recent requests" list fills the
        // remaining window height (scrolling happens inside the list), so it grows with the window.
        VStack(alignment: .leading, spacing: 18) {
            BrandedHeader(title: "Request Activity", subtitle: store.activity.message) {
                HStack(spacing: 8) {
                    activityTypeMenu
                    onlyErrorsToggle
                }
                .fixedSize()
            }

            if store.activity.snapshot.events.isEmpty {
                emptyState
            } else {
                EmbarsySection(title: "Recent requests") {
                    if filteredEvents.isEmpty {
                        Text("No request activity matches the selected activity types.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: .infinity)
                            .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(filteredEvents) { event in
                                    ActivityEventRow(event: event)
                                }
                            }
                            .padding(2)
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Text("Use this screen when the index looks suspicious: embedding rows show the current text chunks Watcher sends to Embarsy, while Qdrant write rows show index mutations and read rows show searches.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.padScreen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Custom activity-type dropdown, styled like the monitoring dropdowns.
        .overlayPreferenceValue(ActivityMenuAnchor.self) { anchor in
            if typeMenuOpen, let anchor {
                GeometryReader { proxy in
                    let r = proxy[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { typeMenuOpen = false }
                        typeDropdownCard
                            .offset(x: max(Theme.padScreen, min(r.minX, proxy.size.width - typeMenuWidth - Theme.padScreen)),
                                    y: r.maxY + 6)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refreshActivity()
                try? await Task.sleep(nanoseconds: refreshIntervalNanoseconds)
            }
        }
    }

    private var typeDropdownCard: some View {
        DropdownCard(width: typeMenuWidth) {
            ForEach(ActivityTypeFilter.allCases) { type in
                DropdownRow(label: type.title, selected: filterState.selectedTypes.contains(type)) {
                    filterState.toggle(type)   // multi-select filter: keep the menu open
                }
            }
        }
    }

    private var activityTypeMenu: some View {
        Button { typeMenuOpen.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease").font(.caption).foregroundStyle(.secondary)
                Text("Activity type").font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                if filterState.selectedTypes.count < ActivityTypeFilter.allCases.count {
                    Text("\(filterState.selectedTypes.count)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accent)
                }
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(typeMenuOpen ? 180 : 0))
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.separator))
        }
        .buttonStyle(.plain).fixedSize()
        .anchorPreference(key: ActivityMenuAnchor.self, value: .bounds) { $0 }
    }

    private var onlyErrorsToggle: some View {
        let red = Color(nsColor: .systemRed)
        return Button {
            onlyErrors.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: onlyErrors ? "smallcircle.filled.circle" : "circle")
                    .font(.caption)
                    .foregroundStyle(onlyErrors ? AnyShapeStyle(red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                Text("Only errors").font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(onlyErrors ? red.opacity(0.08) : Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(onlyErrors ? red.opacity(0.5) : Theme.separator))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No requests in the last 24 hours")
                .font(.headline)
            Text("Start Watcher indexing or run a codebase search. Embarsy will show embedding, Qdrant write and Qdrant read events here automatically.")
                .foregroundStyle(.secondary)
        }
        .padding(Theme.padCard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusXl))
    }
}

/// Captures the activity-type pill's bounds so its custom dropdown can be positioned under it.
private struct ActivityMenuAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct ActivityEventRow: View {
    let event: ActivityEvent
    @State private var isExpanded = false

    private let expandedHeight: CGFloat = 184
    private let expandedDetailHeight: CGFloat = 112

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(event.title)
                        .font(.callout.weight(.semibold))
                    if event.error {
                        Text("error")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(nsColor: .systemRed))
                    }
                    Spacer()
                    Text(event.date, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                detailView
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: isExpanded ? expandedHeight : nil, alignment: .top)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if isExpanded {
            ScrollView(.vertical) {
                Text(event.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: expandedDetailHeight)
            .scrollIndicators(.visible)
            .clipped()
        } else {
            Text(event.detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    private var iconName: String {
        switch event.operation {
        case .embedding: "text.magnifyingglass"
        case .read: "arrow.up.circle.fill"      // Qdrant read
        case .write: "arrow.down.circle.fill"   // Qdrant write
        }
    }

    private var color: Color {
        switch event.operation {
        case .embedding: Theme.mVectors    // green
        case .read: Theme.mReads           // cyan
        case .write: Theme.mWrites         // orange
        }
    }
}
