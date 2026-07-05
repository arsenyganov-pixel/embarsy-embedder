import AppKit
import SwiftUI

struct ContentIndexView: View {
    @EnvironmentObject private var store: EmbarsyStore

    private enum Column {
        static let name: CGFloat = 0.20
        static let indexed: CGFloat = 0.30
        static let points: CGFloat = 0.12
        static let preview: CGFloat = 0.38
    }
    private let rowHeight: CGFloat = 104   // fits ~5 lines of the "What seems indexed" summary
    /// Horizontal breathing room inside the scrollable table so the rounded row cards don't
    /// sit flush against the ScrollView's clip edge (which shaved their border/corners) and so
    /// the right edge clears the overlay scrollbar.
    private let tableInset: CGFloat = 12

    @State private var expandedRows: Set<String> = []
    @State private var sortDescending = true
    @State private var refreshInterval: RefreshInterval = .s30
    @State private var refreshOpen = false
    private let refreshMenuWidth: CGFloat = 184

    private var sortedCollections: [ContentIndexCollection] {
        store.contentIndex.snapshot.collections.sorted {
            sortDescending ? $0.pointsCount > $1.pointsCount : $0.pointsCount < $1.pointsCount
        }
    }
    private var maxPoints: Int { max(store.contentIndex.snapshot.collections.map(\.pointsCount).max() ?? 1, 1) }

    var body: some View {
        // No outer ScrollView: the header + footer stay put and the table fills the remaining
        // window height (scrolling happens inside the table), so the list grows with the window.
        VStack(alignment: .leading, spacing: Theme.gapSection) {
            BrandedHeader(title: "Content", subtitle: store.contentIndex.message) {
                Button { refreshOpen.toggle() } label: {
                    RefreshPillLabel(short: refreshInterval.short, busy: store.contentIndex.isRefreshing, open: refreshOpen)
                }
                .buttonStyle(.plain).fixedSize()
                .anchorPreference(key: MenuAnchorsKey.self, value: .bounds) { MenuAnchors(refresh: $0) }
            }

            if store.contentIndex.snapshot.collections.isEmpty {
                emptyState
            } else {
                tableCard
            }

            Text("\(store.contentIndex.snapshot.collections.count) collections · click a row to expand its full preview · slide a row's grip to delete its collection. The overview is built from Qdrant collections plus Watcher cache metadata.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.padScreen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Custom refresh dropdown, right-aligned to its pill so it stays inside the window edge.
        .overlayPreferenceValue(MenuAnchorsKey.self) { anchors in
            if refreshOpen, let a = anchors.refresh {
                GeometryReader { proxy in
                    let r = proxy[a]
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { refreshOpen = false }
                        RefreshDropdownCard(interval: $refreshInterval, options: RefreshInterval.contentOptions,
                                            width: refreshMenuWidth,
                                            onRefreshNow: { Task { await store.refreshContentIndex() } },
                                            onSelect: { refreshOpen = false })
                            .offset(x: max(0, r.maxX - refreshMenuWidth), y: r.maxY + 6)
                    }
                }
            }
        }
        .task(id: refreshInterval) {
            while !Task.isCancelled {
                await store.refreshContentIndex()
                try? await Task.sleep(nanoseconds: UInt64(refreshInterval.seconds * 1_000_000_000))
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No indexed content yet").font(.headline)
            Text("Start Watcher indexing for a workspace, then Refresh. Embarsy will summarize Qdrant collections here.")
                .foregroundStyle(.secondary)
        }
        .padding(Theme.padCard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusXl))
    }

    private var tableCard: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width - tableInset * 2)
            ScrollView {
                LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(sortedCollections.enumerated()), id: \.element.id) { _, collection in
                            card(collection, width: width)
                        }
                    } header: {
                        headerBar(width: width)
                    }
                }
                .padding(.horizontal, tableInset)
            }
        }
        .frame(maxHeight: .infinity)   // grow the list with the window height
    }

    // MARK: Header bar (uppercase labels, sortable Points)

    private func headerBar(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            headerLabel("Collection", width: width * Column.name)
            headerLabel("What seems indexed", width: width * Column.indexed)
            pointsHeader(width: width * Column.points)
            headerLabel("Preview", width: width * Column.preview)
        }
        .padding(.bottom, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func headerLabel(_ text: String, width: CGFloat) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.vertical, 4).padding(.horizontal, 12)
            .frame(width: width, alignment: .leading)
    }

    private func pointsHeader(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text("POINTS").font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(.tertiary)
            Image(systemName: "arrow.down").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .rotationEffect(.degrees(sortDescending ? 0 : 180))
        }
        .padding(.vertical, 4).padding(.horizontal, 12)
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.16)) { sortDescending.toggle() } }
        .onHover { inside in
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    // MARK: Card row

    private func card(_ collection: ContentIndexCollection, width: CGFloat) -> some View {
        let open = expandedRows.contains(collection.id)
        let pct = CGFloat(collection.pointsCount) / CGFloat(maxPoints)
        return HStack(alignment: .top, spacing: 0) {
            cell(width: width * Column.name) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(collection.collectionName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(open ? nil : 2).truncationMode(.tail)
                    SlideToDelete {
                        Task { await store.deleteCollection(collection.collectionName) }
                    }
                }
            }
            cell(width: width * Column.indexed) {
                Text(collection.indexedSummary)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(open ? nil : 5).truncationMode(.tail)
            }
            cell(width: width * Column.points) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(collection.pointsCount.formatted())
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accent.opacity(0.30))
                            .frame(width: max(2, g.size.width * pct))
                    }
                    .frame(height: 4)
                }
            }
            cell(width: width * Column.preview) {
                previewChips(for: collection, open: open, cellWidth: width * Column.preview)
            }
        }
        .frame(height: open ? nil : rowHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(open ? Theme.accent.opacity(0.07) : Theme.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Clip overflowing content to the ROUNDED shape (a plain .clipped() is rectangular and
        // squares the corners); the border overlay goes on top so its stroke stays full width.
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(open ? Theme.accent : Theme.separator))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.16)) {
                if open { expandedRows.remove(collection.id) } else { expandedRows.insert(collection.id) }
            }
        }
    }

    private func cell<C: View>(width: CGFloat, @ViewBuilder content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.vertical, 12).padding(.horizontal, 12)
            .frame(width: width, alignment: .topLeading)
    }

    private static let collapsedChipLimit = 10   // ~3 rows of preview chips before the "+N" overflow

    @ViewBuilder
    private func previewChips(for collection: ContentIndexCollection, open: Bool, cellWidth: CGFloat) -> some View {
        let all = chipModels(for: collection)
        // maxItemWidth is what actually binds a chip's width in FlowLayout (it measures/places
        // with a proposal, so a plain .frame(maxWidth:) alone never truncates the child).
        let chipCap = max(64, min(cellWidth - 24, min(cellWidth * 0.9, 220)))
        let showAll = open || all.count <= Self.collapsedChipLimit
        let visible = showAll ? all : Array(all.prefix(Self.collapsedChipLimit))
        let overflow = showAll ? 0 : all.count - visible.count

        FlowLayout(spacing: 4, lineSpacing: 4, maxItemWidth: chipCap) {
            ForEach(visible) { chip in
                PreviewChipView(chip: chip)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.separator))
                    .accessibilityLabel("\(overflow) more, expand the row to see all")
            }
        }
    }

    /// Structured tags from the API when present; otherwise parse the legacy prose so a
    /// row is never a single overflowing chip (safety net for older api binaries).
    private func chipModels(for collection: ContentIndexCollection) -> [PreviewChipModel] {
        let models: [PreviewChipModel]
        if let tags = collection.previewTags, !tags.isEmpty {
            models = tags.map { PreviewChipModel(kind: $0.kind, label: $0.label, copy: $0.copyPayload) }
        } else {
            let text = collection.preview.isEmpty ? collection.displayName : collection.preview
            models = Self.fallbackChips(preview: text, displayName: collection.displayName)
        }
        var seenIDs = Set<String>()
        return models.filter { seenIDs.insert($0.id).inserted }   // unique ids for ForEach
    }

    // MARK: Fallback prose → chips (used only when preview_tags is absent)

    static func fallbackChips(preview: String, displayName: String) -> [PreviewChipModel] {
        var chips: [PreviewChipModel] = []
        var seen = Set<String>()
        for token in displayName.lowercased().replacingOccurrences(of: "/", with: " ").split(separator: " ") {
            seen.insert(String(token))
        }
        func add(_ kind: String, _ rawLabel: String, copy: String? = nil) {
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return }
            let key = label.lowercased()
            if kind != "sample", seen.contains(key) { return }
            seen.insert(key)
            chips.append(PreviewChipModel(kind: kind, label: label, copy: copy ?? label))
        }

        // Split the raw sample off first — it can contain '.', ',', ':' that would shatter a naive split.
        var head = preview
        var sample: String?
        if let r = preview.range(of: ". Sample: ") {
            sample = String(preview[r.upperBound...])
            head = String(preview[..<r.lowerBound])
        }

        let workspace = head.contains(" workspace: ") && (head.contains(" files, mostly ") || head.contains(" file, mostly "))
        if workspace {
            if let m = head.range(of: #"\d[\d,]* files?"#, options: .regularExpression) {
                add("count", String(head[m]))
            }
            if let langs = between(head, "mostly ", ".") {
                for lang in splitList(langs) where lang.lowercased() != "files" { add("lang", lang) }
            }
            if let areas = between(head, "Areas: ", ".") {
                for area in splitList(areas) { add("area", area) }
            }
        } else {
            // Generic prose: clause-split into small chips so nothing overflows.
            let clauses = head.replacingOccurrences(of: ": ", with: ". ").components(separatedBy: ". ")
            for clause in clauses.prefix(6) {
                for part in clause.components(separatedBy: ", ").prefix(4) { add("term", part) }
            }
        }

        if chips.isEmpty {
            chips.append(PreviewChipModel(kind: "term", label: String(head.prefix(60)), copy: head))
        }
        if let sample, !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chips.append(PreviewChipModel(kind: "sample", label: "Sample", copy: sample))
        }
        return chips
    }

    private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let ra = s.range(of: a) else { return nil }
        let rest = s[ra.upperBound...]
        if let rb = rest.range(of: b) { return String(rest[..<rb.lowerBound]) }
        return String(rest)
    }

    private static func splitList(_ s: String) -> [String] {
        s.replacingOccurrences(of: " and ", with: ", ")
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Preview chip

struct PreviewChipModel: Identifiable {
    let kind: String    // count | lang | area | term | sample
    let label: String
    let copy: String
    var id: String { "\(kind)|\(label)" }
}

/// A copy-on-click preview chip. Clicking copies `chip.copy` to the clipboard and flashes
/// a teal confirmation for 0.9s. Width stays constant during the flash (only colors/glyph
/// swap) so neighbouring chips don't reflow.
private struct PreviewChipView: View {
    let chip: PreviewChipModel
    @State private var copied = false
    @State private var hovering = false

    private var truncation: Text.TruncationMode {
        (chip.kind == "term" || chip.kind == "sample") ? .middle : .tail
    }

    var body: some View {
        // Width is bound by FlowLayout(maxItemWidth:) which proposes a capped width, so the
        // lineLimit(1) label hugs short content and truncates long content — no .frame(maxWidth:)
        // here (that would stretch every chip to the full cap and stack them one-per-row).
        Button(action: copy) {
            HStack(spacing: 4) {
                if chip.kind == "sample" {
                    Image(systemName: copied ? "checkmark" : "doc.text")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(chip.label)
                    .lineLimit(1)
                    .truncationMode(truncation)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(copied ? Theme.onAccent : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(
                copied
                    ? AnyShapeStyle(Theme.accent)
                    : AnyShapeStyle(hovering ? Theme.surfaceRaised : Theme.fillQuaternary),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(copied ? Theme.accent : (hovering ? Theme.accent.opacity(0.5) : Theme.separator)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $copied, arrowEdge: .top) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                Text("Copied to clipboard").font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .help(chip.copy)
        .accessibilityLabel("Copy \(chip.label)")
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chip.copy, forType: .string)
        withAnimation(.easeInOut(duration: 0.12)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeInOut(duration: 0.12)) { copied = false }
        }
    }
}
