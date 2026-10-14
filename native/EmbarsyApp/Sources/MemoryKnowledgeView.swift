import AppKit
import SwiftUI
import WebKit

// The Knowledge tab: read the memory base without leaving Embarsy — browse it, search it by
// meaning (the same index recall uses), open a note, follow its links and see what links to it.

struct KnowledgeNote: Identifiable, Hashable {
    let url: URL
    let rel: String
    let title: String
    let section: String
    /// Topic folder for knowledge, year for experience; empty for people.
    let group: String
    let verifiedAt: String

    var id: String { rel }
}

enum KnowledgeIndex {
    static let sections: [(key: String, label: String)] = [("knowledge", L("Knowledge")), ("experience", L("Experience")), ("people", L("People"))]

    static func notes(in vault: VaultLayout) -> [KnowledgeNote] {
        var out: [KnowledgeNote] = []
        for (key, _) in sections {
            let root = vault.root.appendingPathComponent(key)
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "md",
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let rel = MemoryScanner.relativePath(of: url, in: vault.root)
                let parts = rel.split(separator: "/").map(String.init)
                let fields = Dictionary(MarkdownRenderer.split(text).fields, uniquingKeysWith: { a, _ in a })
                let heading = text.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
                let title = fields["title"] ?? heading ?? url.deletingPathExtension().lastPathComponent
                out.append(KnowledgeNote(url: url, rel: rel, title: title, section: key,
                                         group: parts.count > 2 ? parts[1] : "",
                                         verifiedAt: fields["verified_at"] ?? ""))
            }
        }
        return out.sorted { a, b in
            if a.section == "experience" && b.section == "experience" { return a.rel > b.rel }   // newest first
            return a.rel.localizedStandardCompare(b.rel) == .orderedAscending
        }
    }

    /// Notes that link to this one, by resolving every relative link in the base.
    static func backlinks(to note: KnowledgeNote, in vault: VaultLayout, among notes: [KnowledgeNote]) -> [KnowledgeNote] {
        let target = note.url.standardizedFileURL.path
        return notes.filter { other in
            guard other.id != note.id, let text = try? String(contentsOf: other.url, encoding: .utf8) else { return false }
            return MemoryScanner.markdownLinkTargets(in: text).contains { link in
                var path = link
                if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
                let decoded = path.removingPercentEncoding ?? path
                let resolved = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded)
                    : other.url.deletingLastPathComponent().appendingPathComponent(decoded)
                return resolved.standardizedFileURL.path == target
            }
        }
    }
}

struct MemoryKnowledgePanel: View {
    @ObservedObject var memory: MemoryService
    @State private var notes: [KnowledgeNote] = []
    @State private var selected: KnowledgeNote?
    @State private var filter = ""
    @State private var results: [MemorySearch.Hit]?
    @State private var searching = false
    @State private var backlinks: [KnowledgeNote] = []

    var body: some View {
        if let vault = memory.vault {
            HStack(alignment: .top, spacing: 14) {
                sidebar(vault)
                    .frame(width: 270)
                Divider().overlay(Theme.separator)
                reader(vault)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 620)
            .task(id: memory.snapshot?.scannedAt) { reload(vault) }
        }
    }

    // MARK: Sidebar

    private func sidebar(_ vault: VaultLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Filter, or ⏎ to search by meaning", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { Task { await search() } }
                if searching { ProgressView().controlSize(.small) }
            }
            .onChange(of: filter) { if $0.isEmpty { results = nil } }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let results {
                        searchResults(results, vault: vault)
                    } else {
                        tree
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var visibleNotes: [KnowledgeNote] {
        let q = filter.trimmed.lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.title.lowercased().contains(q) || $0.rel.lowercased().contains(q) }
    }

    private var tree: some View {
        ForEach(KnowledgeIndex.sections, id: \.key) { section in
            let inSection = visibleNotes.filter { $0.section == section.key }
            if !inSection.isEmpty {
                // Three levels, each set apart: the section (small caps over a rule), the topic
                // (full-colour, bold, with its count), the notes (indented under their topic).
                VStack(alignment: .leading, spacing: 6) {
                    Divider().overlay(Theme.separator)
                    HStack {
                        Text(verbatim: section.label.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(verbatim: "\(inSection.count)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 10)
                let groups = Dictionary(grouping: inSection, by: \.group)
                ForEach(groups.keys.sorted(by: section.key == "experience" ? { $0 > $1 } : { $0 < $1 }), id: \.self) { group in
                    if !group.isEmpty {
                        HStack {
                            Text(verbatim: Self.topicTitle(group))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            Text(verbatim: "\(groups[group]?.count ?? 0)")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 8)
                        .padding(.horizontal, 6)
                    }
                    ForEach(groups[group] ?? []) { note in
                        noteRow(note).padding(.leading, group.isEmpty ? 0 : 8)
                    }
                }
            }
        }
    }

    /// A topic folder's name as a heading: "billing-api" → "Billing api". Years stay as is.
    static func topicTitle(_ folder: String) -> String {
        let spaced = folder.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private func noteRow(_ note: KnowledgeNote) -> some View {
        Button { open(note) } label: {
            Text(note.title)
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundStyle(selected?.id == note.id ? Theme.accent : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(selected?.id == note.id ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func searchResults(_ hits: [MemorySearch.Hit], vault: VaultLayout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hits.isEmpty ? L("Nothing in memory reads like this.") : L("By meaning · \(hits.count)"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
            ForEach(hits) { hit in
                Button {
                    // Skills and the core are found too; they open in the reader like any note.
                    open(notes.first(where: { $0.rel == hit.path })
                         ?? KnowledgeNote(url: vault.root.appendingPathComponent(hit.path), rel: hit.path, title: hit.title,
                                          section: String(hit.path.split(separator: "/").first ?? ""), group: "", verifiedAt: ""))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.heading.isEmpty ? hit.title : "\(hit.title) › \(hit.heading)")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                        Text(hit.snippet)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Text(hit.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Reader

    @ViewBuilder
    private func reader(_ vault: VaultLayout) -> some View {
        if let note = selected, let text = try? String(contentsOf: note.url, encoding: .utf8) {
            let parts = MarkdownRenderer.split(text)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(note.rel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Open in editor") { NSWorkspace.shared.open(note.url) }
                        .controlSize(.small)
                    FinderLink(label: "Finder", folder: note.url, font: .system(size: 11.5))
                }
                HStack(alignment: .center, spacing: 8) {
                    metadata(parts.fields)
                    Spacer(minLength: 8)
                    if note.section == "knowledge" || note.section == "people" {
                        Button("I've checked it — mark verified today") {
                            Task { await memory.markVerified(note.url) }
                        }
                        .controlSize(.small)
                        .disabled(memory.isWorking)
                        .chipHelp("Use after you have compared the note with how things are now. Agents treat recently verified notes as more reliable; Health flags notes verified over six months ago.")
                    }
                }
                NoteWebView(html: MarkdownRenderer.page(body: MarkdownRenderer.html(parts.body)),
                            baseURL: note.url.deletingLastPathComponent(),
                            onOpenNote: { url in
                                let inBase = url.standardizedFileURL.path.hasPrefix(vault.root.standardizedFileURL.path + "/")
                                if let target = notes.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
                                    open(target)
                                } else if inBase, url.pathExtension.lowercased() == "md", FileManager.default.fileExists(atPath: url.path) {
                                    open(KnowledgeNote(url: url, rel: MemoryScanner.relativePath(of: url, in: vault.root),
                                                       title: url.deletingPathExtension().lastPathComponent, section: "", group: "", verifiedAt: ""))
                                } else if FileManager.default.fileExists(atPath: url.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            })
                if !backlinks.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Linked from")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                        FlowLayout(spacing: 4) {
                            ForEach(backlinks) { link in
                                Button(link.title) { open(link) }
                                    .buttonStyle(.link)
                                    .font(.system(size: 11.5))
                            }
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(notes.count) notes")
                    .font(.system(size: 13, weight: .semibold))
                Text("Pick a note on the left, or type what you're looking for and press Return to search by meaning — the same way your agents' recall does.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 8)
        }
    }

    private func metadata(_ fields: [(String, String)]) -> some View {
        let shown = fields.filter { ["type", "created", "updated", "verified_at", "confidence", "status"].contains($0.0) }
        return FlowLayout(spacing: 6) {
            ForEach(shown, id: \.0) { key, value in
                Text(verbatim: "\(key.replacingOccurrences(of: "_", with: " ")): \(value)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.fillQuaternary, in: Capsule())
            }
        }
    }

    // MARK: Actions

    private func reload(_ vault: VaultLayout) {
        notes = KnowledgeIndex.notes(in: vault)
        if let current = selected { selected = notes.first { $0.id == current.id } }
        if let selected { backlinks = KnowledgeIndex.backlinks(to: selected, in: vault, among: notes) }
    }

    private func open(_ note: KnowledgeNote) {
        selected = note
        if let vault = memory.vault { backlinks = KnowledgeIndex.backlinks(to: note, in: vault, among: notes) }
    }

    private func search() async {
        let query = filter.trimmed
        guard !query.isEmpty, let config = memory.searchConfig?() else { return }
        searching = true
        results = await MemorySearch.search(query, config: config)
        searching = false
    }
}

/// A rendered note. Links to other notes open in the reader; web links in the browser;
/// other files in Finder. Nothing in the note runs as script.
private struct NoteWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    let onOpenNote: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpenNote: onOpenNote) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onOpenNote = onOpenNote
        guard context.coordinator.loaded != html + baseURL.path else { return }
        context.coordinator.loaded = html + baseURL.path
        view.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onOpenNote: (URL) -> Void
        var loaded = ""

        init(onOpenNote: @escaping (URL) -> Void) { self.onOpenNote = onOpenNote }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if url.isFileURL {
                var path = url.path
                // A leftover ":12" line number from an old link points at the file all the same.
                if let range = path.range(of: #":\d+$"#, options: .regularExpression) { path.removeSubrange(range) }
                onOpenNote(URL(fileURLWithPath: path))
            } else if ["http", "https"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
