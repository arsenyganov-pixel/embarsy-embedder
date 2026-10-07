import AppKit
import SwiftUI

/// Connects coding agents to Embarsy and manages the folders they search.
///
/// One tab per agent, because all three can be in use at once — a picker would imply
/// choosing one. The indexed folders sit OUTSIDE the tab panel on purpose: they are not
/// per-agent, Claude Code and Codex search the very same indexes.
struct ConnectionsView: View {
    @EnvironmentObject private var store: EmbarsyStore
    @State private var tab: ConnectionTab = .claude

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapSection) {
                BrandedHeader(title: "Connections", subtitle: "Give your coding agents search by meaning")

                tabbedPanel

                IndexedFoldersSection(indexing: store.indexing, contentIndex: store.contentIndex)

                EmbarsySection(title: "If something goes wrong") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Self.trouble, id: \.0) { title, detail in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                Text("**\(title)** \(detail)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                EmbarsySection(title: "App Support") {
                    SupportChip()
                }
            }
            .padding(Theme.padScreen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            store.refreshEditorConnections()
            // Keeps polling while the screen is open. Right after launch the secrets may not be
            // loaded or the API may still be warming up, and a single attempt that lands then
            // would leave the list empty for as long as the tab stays open; later polls also
            // pick up a folder re-indexed from the command line.
            while !Task.isCancelled {
                await store.refreshContentIndex(maxAge: 5)
                let seconds: UInt64 = store.contentIndex.hasLoaded ? 30 : 3
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    // MARK: Tabs

    /// The selected tab and its panel read as ONE shape: the tab's outline opens into the
    /// panel's top edge, and both share a fill a step lighter than the window, so the
    /// boundary of "this agent's settings" is unmistakable.
    private var tabbedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                ForEach(ConnectionTab.allCases) { item in
                    tabButton(item)
                }
            }
            .zIndex(1)

            Group {
                switch tab {
                case .claude: AgentPanel(agent: .claude)
                case .codex: AgentPanel(agent: .codex)
                case .roo: RooPanel()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelShape(radius: Theme.radiusLg, squareTopLeft: tab == .claude).fill(Theme.surface))
            .overlay(PanelShape(radius: Theme.radiusLg, squareTopLeft: tab == .claude).stroke(Theme.separator, lineWidth: 1))
        }
    }

    private func tabButton(_ item: ConnectionTab) -> some View {
        let selected = tab == item
        return Button { tab = item } label: {
            HStack(spacing: 7) {
                if let agent = item.agent {
                    StateGlyph(agent: agent, state: store.editorStates[agent] ?? .notConnected)
                }
                Text(item.label)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background {
                if selected {
                    // Extends 1pt below the tab to paint over the panel's top border beneath
                    // it — that is what opens the tab into the panel.
                    TabShape(radius: 8, closed: true).fill(Theme.surface).padding(.bottom, -1)
                }
            }
            .overlay {
                if selected { TabShape(radius: 8, closed: false).stroke(Theme.separator, lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    static let trouble: [(String, String)] = [
        ("Search finds nothing.", "Make sure the folder is listed under Indexed folders, and re-index it after large changes. For Zoo / Roo the dimension must be 1024 — Clear Index Data in Zoo / Roo and run indexing again."),
        ("Claude Code or Codex doesn't see Embarsy.", "Restart the editor after connecting — editors read their MCP config only at launch."),
        ("401 error / no access.", "Keys change after a reinstall. Press Reconnect here for Claude Code and Codex; paste the current keys into Zoo / Roo."),
        ("Everything reads zero in Monitoring.", "The client must call http://localhost:8000/qdrant, not :6333 directly."),
        ("Nothing starts up.", "Make sure every status row on Status is green (Install and Start)."),
    ]
}

enum ConnectionTab: String, CaseIterable, Identifiable {
    case claude, codex, roo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .roo: return "Zoo / Roo Code"
        }
    }

    /// Zoo / Roo has no agent: Embarsy cannot connect it, only supply values to paste — so it
    /// gets no state glyph, which would otherwise claim something we cannot know.
    var agent: EditorAgent? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .roo: return nil
        }
    }
}

// MARK: - State glyph

/// The tab's connection state. Every state has a distinct shape as well as a colour, and the
/// hover explains all three — the glyph is the only place on the tab strip the state appears.
private struct StateGlyph: View {
    let agent: EditorAgent
    let state: EditorConnectionState

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(color)
            .contentShape(Rectangle())
            .chipHelp("\(agent.label): \(meaning). Green check — connected and working. Empty circle — not connected. Orange mark — set up for a copy of Embarsy that was moved or replaced, so it can't start; reconnect it.")
    }

    private var symbol: String {
        switch state {
        case .connected: return "checkmark.circle"
        case .notConnected: return "circle"
        case .connectedViaExternalBridge: return "checkmark.circle"
        case .connectedToMissingBuild: return "exclamationmark.circle"
        }
    }

    private var color: Color {
        switch state {
        case .connected: return Color(nsColor: .systemGreen)
        case .notConnected: return .secondary
        case .connectedViaExternalBridge: return Color(nsColor: .systemGreen)
        case .connectedToMissingBuild: return .orange
        }
    }

    private var meaning: String {
        switch state {
        case .connected: return "connected"
        case .notConnected: return "not connected"
        case .connectedViaExternalBridge: return "connected through a separately installed bridge"
        case .connectedToMissingBuild: return "set up for a copy of Embarsy that no longer exists"
        }
    }
}

// MARK: - Agent panel

private struct AgentPanel: View {
    @EnvironmentObject private var store: EmbarsyStore
    let agent: EditorAgent

    private var state: EditorConnectionState { store.editorStates[agent] ?? .notConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(titleColor)
                Spacer(minLength: 8)
                action
            }
            if state == .notConnected {
                // The file Connect will write is a place on disk, so it is shown as one.
                HStack(spacing: 2) {
                    Text("Writes")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    FinderLink(label: configDisplayPath, folder: configRevealTarget,
                               font: .system(size: 12, design: .monospaced))
                }
                .padding(.leading, -1)
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.editorConnectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        switch state {
        case .connected: return "Connected"
        case .notConnected: return "Not connected"
        case .connectedViaExternalBridge: return "Connected"
        case .connectedToMissingBuild: return "Can't start"
        }
    }

    private var titleColor: Color {
        switch state {
        case .connected: return Color(nsColor: .systemGreen)
        case .notConnected: return .primary
        case .connectedViaExternalBridge: return Color(nsColor: .systemGreen)
        case .connectedToMissingBuild: return .orange
        }
    }

    private var detail: String {
        switch state {
        case .connected:
            return "Bridge \(bridgeVersion), bundled · works in every indexed folder · \(agent.activationHint)"
        case .notConnected:
            return "Works in every indexed folder — no npm, no Node, nothing to approve."
        case .connectedViaExternalBridge:
            return "Through a bridge installed separately from Embarsy. It works, but it updates on its own — switch to the one bundled with Embarsy so the two always match."
        case .connectedToMissingBuild:
            return "\(agent.label) is set up to start Embarsy from a copy that was moved or replaced, so it fails to start. Reconnect to point it at this one."
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .connected:
            Button("Disconnect") { store.disconnectEditor(agent) }
                .buttonStyle(.bordered)
        case .notConnected:
            Button("Connect") { store.connectEditor(agent) }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        case .connectedViaExternalBridge:
            // A recommendation, not a repair: nothing is broken, so it stays a plain button.
            Button("Use bundled bridge") { store.connectEditor(agent) }
                .buttonStyle(.bordered)
        case .connectedToMissingBuild:
            Button("Reconnect") { store.connectEditor(agent) }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
    }

    private var configDisplayPath: String {
        agent.configURL().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// The config file itself when it exists; before the first Connect there is nothing to
    /// select yet, so Finder opens the folder it will be written to (or home, for Codex's
    /// `~/.codex` that may not exist either).
    private var configRevealTarget: URL {
        let file = agent.configURL()
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) { return file }
        let folder = file.deletingLastPathComponent()
        return fm.fileExists(atPath: folder.path) ? folder : fm.homeDirectoryForCurrentUser
    }

    /// Read from the VERSION file the packaging step writes beside the bundled bridge, so the
    /// number shown is the one actually shipped rather than a constant that can drift.
    private var bridgeVersion: String {
        let file = store.paths.bundledBridgeMCP.deletingLastPathComponent().appendingPathComponent("VERSION")
        return (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
    }
}

// MARK: - Zoo / Roo panel

private struct RooPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Zoo / Roo Code indexes your code itself — it only needs Embarsy's values. In VS Code, open the Zoo / Roo chat, click the **Codebase Indexing** icon at the bottom right, paste the values below, press **Save**, then **Start Indexing**.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RooConnectionParameters()
        }
    }
}

// MARK: - Indexed folders

private struct IndexedFoldersSection: View {
    @EnvironmentObject private var store: EmbarsyStore
    @ObservedObject var indexing: IndexingService
    @ObservedObject var contentIndex: ContentIndexService

    /// Only folders Embarsy's bridge indexed. Zoo / Roo keeps its own indexes in a different
    /// shape — re-indexing those with the bridge would corrupt them, so they are not offered.
    private var folders: [ContentIndexCollection] {
        contentIndex.snapshot.collections
            .filter(\.isBridgeIndexed)
            .sorted { ($0.workspacePath ?? "") < ($1.workspacePath ?? "") }
    }

    /// Runs for folders that have no index yet — a freshly added folder shows its progress
    /// here until the first run finishes and it joins the list above.
    private var pendingFolders: [String] {
        let known = Set(folders.compactMap(\.workspacePath))
        return indexing.runs.keys.filter { !known.contains($0) }.sorted()
    }

    var body: some View {
        EmbarsySection(title: "Indexed folders", spacing: 10) {
            Text("Used by Claude Code and Codex. The index covering your editor's folder is picked automatically. A folder's index includes its subfolders, skipping whatever their .gitignore files exclude; an agent working in a subfolder searches that subfolder first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !contentIndex.hasLoaded && folders.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading indexed folders…")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            } else if folders.isEmpty && pendingFolders.isEmpty {
                Text("No folders indexed yet. Add a project folder so Claude Code and Codex have something to search.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }

            ForEach(folders) { collection in
                if let folder = collection.revealableFolder {
                    row(folder: folder, collection: collection.collectionName,
                        stats: stats(for: collection))
                }
            }
            ForEach(pendingFolders, id: \.self) { path in
                row(folder: URL(fileURLWithPath: path), collection: nil, stats: nil)
            }

            Button {
                pickFolder()
            } label: {
                Label("Add folder…", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(indexing.isBusy)
        }
    }

    private func row(folder: URL, collection: String?, stats: String?) -> some View {
        let key = folder.standardizedFileURL.path
        let run = indexing.runs[key]
        return HStack(spacing: 10) {
            FinderLink(label: key.replacingOccurrences(of: NSHomeDirectory(), with: "~"), folder: folder,
                       font: .system(size: 12, design: .monospaced))
            Spacer(minLength: 8)
            status(run: run, stats: stats)
            if let collection {
                Button("Re-index") {
                    Task { await store.indexFolder(folder, collection: collection) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(indexing.isBusy)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).stroke(Theme.separator))
    }

    @ViewBuilder
    private func status(run: IndexingService.Run?, stats: String?) -> some View {
        switch run {
        case .running(let progress):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(progress).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help(message)
        case .finished(let summary):
            Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        case .none:
            if let stats {
                Text(stats).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
    }

    private func stats(for collection: ContentIndexCollection) -> String {
        let chunks = "\(collection.pointsCount.formatted()) chunks"
        guard let date = collection.lastIndexedDate else { return chunks }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        return "\(chunks) · \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Index"
        panel.message = "Choose a project folder to index for Claude Code and Codex"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Re-adding an indexed folder refreshes its existing index rather than starting a
        // second one beside it.
        let path = url.standardizedFileURL.path
        let existing = folders.first { $0.workspacePath == path }
        let collection = existing?.collectionName ?? IndexingService.collectionName(for: url)
        Task { await store.indexFolder(url, collection: collection) }
    }
}

// MARK: - Shapes

/// The selected tab: rounded top corners, square bottom. Open (no bottom edge) when stroked,
/// so its outline flows into the panel instead of drawing a line between them.
private struct TabShape: Shape {
    var radius: CGFloat
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        if closed { path.closeSubpath() }
        return path
    }
}

/// The tab panel. Its top-left corner is square while the first tab is selected, so that tab
/// sits flush on the panel's edge instead of floating above a rounded corner.
private struct PanelShape: Shape {
    var radius: CGFloat
    var squareTopLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if squareTopLeft {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
        }
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}
