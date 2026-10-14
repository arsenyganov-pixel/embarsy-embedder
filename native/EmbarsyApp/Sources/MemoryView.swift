import AppKit
import SwiftUI

/// What each coding agent can actually see of the user's skills and standing instructions.
///
/// Read-only: the screen reports, it never changes a file. Skills and Health are tabs of one
/// panel (as on Connections) because they are two views of the same scan; the scanned
/// folders sit outside the panel because they feed both.
struct MemoryView: View {
    @ObservedObject var memory: MemoryService
    @State private var tab: MemoryTab

    init(memory: MemoryService, initialTab: MemoryTab = .skills) {
        self.memory = memory
        _tab = State(initialValue: initialTab)
    }
    @State private var showOnboarding = false
    @State private var showMigration = false

    /// Core comes first once there is a base; before that only the scan exists.
    private var tabs: [MemoryTab] {
        let assistant: [MemoryTab] = memory.localModel == nil ? [] : [.assistant]
        return (memory.vault == nil ? [.skills, .health] : [.core, .inbox, .knowledge, .skills, .health]) + assistant
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapSection) {
                BrandedHeader(title: "Memory", subtitle: "What Claude Code, Codex and Zoo / Roo can see of your skills and instructions") {
                    rescanButton
                }

                if memory.vault == nil {
                    if let session = memory.migration {
                        MigrationCard(memory: memory, session: session)
                    } else {
                        MemorySetupCard(startFresh: { showOnboarding = true }, bringExisting: { showMigration = true })
                    }
                    if let notice = memory.lastNotice {
                        HelpNote(verbatim: notice)
                    }
                }

                if let snapshot = memory.snapshot {
                    tabbedPanel(snapshot)
                    ScannedFoldersSection(memory: memory, snapshot: snapshot)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading your agents' folders…")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(Theme.padScreen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disclosureGroupStyle(TappableDisclosureStyle())
        .task {
            if memory.vault != nil, memory.snapshot == nil { tab = .core }
            await memory.rescan()
        }
        .onReceive(memory.$requestedTab) { requested in
            guard let requested else { return }
            tab = requested
            memory.requestedTab = nil
        }
        .onChange(of: memory.vault) { vault in
            if vault == nil, tab == .core { tab = .skills }
        }
        .sheet(isPresented: $showOnboarding) {
            MemoryOnboardingSheet(memory: memory) { tab = .core }
        }
        .sheet(isPresented: $showMigration) {
            MigrationStartSheet(memory: memory)
        }
        .onChange(of: memory.vault) { vault in
            if vault != nil, memory.migration == nil { tab = .core }
        }
    }

    private var rescanButton: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                Task { await memory.rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(memory.isScanning)
            Text("Rescanning only reads — it changes nothing")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Tabs

    private func tabbedPanel(_ snapshot: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                ForEach(tabs) { item in
                    tabButton(item, snapshot: snapshot)
                }
            }
            .zIndex(1)

            Group {
                switch tab {
                case .core: MemoryCorePanel(memory: memory)
                case .inbox: MemoryInboxPanel(memory: memory)
                case .knowledge: MemoryKnowledgePanel(memory: memory)
                case .skills: SkillsPanel(snapshot: snapshot)
                case .health: HealthPanel(snapshot: snapshot, memory: memory)
                case .assistant:
                    if let model = memory.localModel { AssistantPanel(memory: memory, model: model) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelShape(radius: Theme.radiusLg, squareTopLeft: tab == tabs.first).fill(Theme.surface))
            .overlay(PanelShape(radius: Theme.radiusLg, squareTopLeft: tab == tabs.first).stroke(Theme.separator, lineWidth: 1))
        }
    }

    /// Waiting proposals are work for the user, not a fault: grey, never orange.
    private var inboxBadge: CountBadge.Badge? {
        let count = memory.inbox.count
        guard count > 0 else { return nil }
        return CountBadge.Badge(count: count, isFailure: false,
                                help: L("\(count) proposals from your agents waiting for review. Grey — nothing is wrong; it only becomes memory once you accept it."))
    }

    private func tabButton(_ item: MemoryTab, snapshot: MemorySnapshot) -> some View {
        let selected = tab == item
        return Button { tab = item } label: {
            HStack(spacing: 7) {
                Text(item.label)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                CountBadge(badge: item == .inbox ? inboxBadge : item.badge(snapshot))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background {
                if selected {
                    TabShape(radius: 8, closed: true).fill(Theme.surface).padding(.bottom, -1)
                }
            }
            .overlay {
                if selected { TabShape(radius: 8, closed: false).stroke(Theme.separator, lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
    }
}

enum MemoryTab: String, CaseIterable, Identifiable {
    case core, inbox, knowledge, skills, health, assistant

    var id: String { rawValue }

    var label: String {
        switch self {
        case .core: return L("Core")
        case .inbox: return L("Inbox")
        case .knowledge: return L("Knowledge")
        case .skills: return L("Skills")
        case .health: return L("Health")
        case .assistant: return L("Assistant")
        }
    }

    func badge(_ snapshot: MemorySnapshot) -> CountBadge.Badge? {
        switch self {
        case .core, .inbox, .knowledge, .assistant:
            return nil
        case .skills:
            let skipped = snapshot.groups.filter(\.hasAgentProblem).count
            let drifted = snapshot.groups.filter(\.hasDrift).count
            let unseen = snapshot.groups.filter { $0.isSeenByNoAgent && !$0.hasAgentProblem }.count
            let total = snapshot.groups.filter(\.hasProblem).count
            guard total > 0 else { return nil }
            return CountBadge.Badge(
                count: total,
                isFailure: skipped + drifted > 0,
                help: L("\(total) skills have a problem: \(skipped) skipped by an agent that reads their folder, \(drifted) with copies that differ, \(unseen) that no agent sees. Orange — at least one agent is missing or mis-reading a skill. Grey — nothing is broken, but some skills reach no agent.")
            )
        case .health:
            let errors = snapshot.findings.filter { $0.severity == .error }.count
            let warnings = snapshot.findings.filter { $0.severity == .warning }.count
            guard errors + warnings > 0 else { return nil }
            return CountBadge.Badge(
                count: errors > 0 ? errors : warnings,
                isFailure: errors > 0,
                help: errors > 0
                    ? L("\(errors) problems and \(warnings) warnings. Orange counts problems — things an agent gets wrong right now. Grey would count warnings only.")
                    : L("\(warnings) warnings, no problems. Grey counts warnings; it turns orange and counts problems when an agent gets something wrong.")
            )
        }
    }
}

/// The number on a tab. Orange only when something is actually broken.
struct CountBadge: View {
    struct Badge {
        let count: Int
        let isFailure: Bool
        let help: String
    }

    let badge: Badge?

    var body: some View {
        if let badge {
            Text("\(badge.count)")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(badge.isFailure ? Color.white : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(badge.isFailure ? Color.orange : Theme.fillQuaternary, in: Capsule())
                .overlay(Capsule().stroke(badge.isFailure ? Color.clear : Theme.separator))
                .contentShape(Capsule())
                .chipHelp(verbatim: badge.help)
        }
    }
}

// MARK: - Skills

private struct SkillsPanel: View {
    let snapshot: MemorySnapshot
    @State private var onlyProblems = false

    private var groups: [SkillGroup] {
        onlyProblems ? snapshot.groups.filter(\.hasProblem) : snapshot.groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Each skill and whether each agent loads it. A skill counts once however many copies of it exist; open it to see them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Picker("", selection: $onlyProblems) {
                    Text("All \(snapshot.groups.count)").tag(false)
                    Text("With problems \(snapshot.groups.filter(\.hasProblem).count)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if snapshot.groups.isEmpty {
                Text("No skills found in any folder Claude Code, Codex or Zoo / Roo reads.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                columnHeader
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        SkillRow(group: group)
                        if group.id != groups.last?.id {
                            Divider().overlay(Theme.separator)
                        }
                    }
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Skill")
                .padding(.leading, 16)
            Spacer(minLength: 8)
            ForEach(MemoryAgent.allCases) { agent in
                Text(agent.label).frame(width: SkillRow.columnWidth)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.tertiary)
    }
}

private struct SkillRow: View {
    static let columnWidth: CGFloat = 86
    let group: SkillGroup
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            details
                .padding(.leading, 16)
                .padding(.top, 6)
                .padding(.bottom, 10)
        } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    subtitle
                }
                Spacer(minLength: 8)
                ForEach(MemoryAgent.allCases) { agent in
                    VisibilityGlyph(agent: agent, visibility: group.visibility(for: agent))
                        .frame(width: Self.columnWidth)
                }
            }
            .padding(.vertical, 7)
        }
    }

    private var subtitle: some View {
        var parts: [Text] = []
        if let author = group.author { parts.append(Text("by \(author)")) }
        let copies = group.distinctCopies.count
        if copies > 1 { parts.append(Text("\(copies) copies")) }
        if group.hasDrift { parts.append(Text("copies differ").foregroundColor(.orange)) }
        if group.isSeenByNoAgent && !group.hasAgentProblem { parts.append(Text("no agent sees it")) }
        let joined = parts.enumerated().reduce(Text("")) { result, item in
            item.offset == 0 ? item.element : result + Text(" · ") + item.element
        }
        return joined
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let description = group.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(MemoryAgent.allCases) { agent in
                if case .rejected(let reason) = group.visibility(for: agent) {
                    Text("**\(agent.label) skips it.** \(reason)")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.entries) { entry in
                    CopyRow(entry: entry, version: versionLetter(for: entry))
                }
            }
        }
    }

    /// Copies with identical contents share a letter, so drift is visible at a glance.
    private func versionLetter(for entry: SkillEntry) -> String? {
        guard group.hasDrift else { return nil }
        var hashes: [String] = []
        for copy in group.distinctCopies where !hashes.contains(copy.contentHash) {
            hashes.append(copy.contentHash)
        }
        guard let index = hashes.firstIndex(of: entry.contentHash) else { return nil }
        return String(UnicodeScalar(UInt8(65 + index % 26)))
    }
}

private struct CopyRow: View {
    let entry: SkillEntry
    let version: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let version {
                    Text(version)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 18, height: 18)
                        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.separator))
                        .contentShape(Rectangle())
                        .chipHelp("Version \(version). Copies marked with the same letter have identical contents; different letters mean the copies differ.")
                }
                FinderLink(label: MemoryScanner.tilde(entry.url), folder: entry.url,
                           font: .system(size: 11.5, design: .monospaced))
            }
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.leading, version == nil ? 8 : 32)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var caption: String {
        var parts: [String] = []
        if entry.isSymlink { parts.append(L("link to \(MemoryScanner.tilde(entry.resolvedURL))")) }
        parts.append(entry.root.summary)
        if let modified = entry.modified {
            parts.append(L("changed \(MemoryScanner.dateFormatter.string(from: modified))"))
        }
        return parts.joined(separator: " · ")
    }
}

/// One cell of the skills table. Three shapes, so the state reads without colour too; the
/// hover gives this cell's reason and the legend for all three.
private struct VisibilityGlyph: View {
    let agent: MemoryAgent
    let visibility: SkillVisibility

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: visibility == .absent ? .regular : .medium))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .chipHelp(verbatim: L("\(meaning)\n\nGreen check — \(agent.label) loads the skill. Orange mark — the skill is in a folder \(agent.label) reads, but \(agent.label) skips it. Dash — the skill isn't in any folder \(agent.label) reads."))
    }

    private var symbol: String {
        switch visibility {
        case .visible: return "checkmark.circle"
        case .rejected: return "exclamationmark.circle"
        case .absent: return "minus"
        }
    }

    private var color: Color {
        switch visibility {
        case .visible: return Color(nsColor: .systemGreen)
        case .rejected: return .orange
        case .absent: return .secondary
        }
    }

    private var meaning: String {
        switch visibility {
        case .visible(let note):
            return note.map { L("\(agent.label) loads this skill. \($0)") } ?? L("\(agent.label) loads this skill.")
        case .rejected(let reason):
            return L("\(agent.label) skips this skill. \(reason)")
        case .absent:
            return L("Not in any folder \(agent.label) reads.")
        }
    }
}

// MARK: - Health

private struct HealthPanel: View {
    let snapshot: MemorySnapshot
    @ObservedObject var memory: MemoryService
    @State private var showFixAll = false

    private var fixes: [HealthFix] { snapshot.findings.compactMap(\.fix) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if snapshot.findings.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Color(nsColor: .systemGreen))
                    Text("Nothing to fix. Every agent sees the same, intact skills.")
                        .font(.system(size: 12.5))
                }
            }
            if !fixes.isEmpty || memory.lastNotice != nil || memory.lastError != nil {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let error = memory.lastError {
                            Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let notice = memory.lastNotice {
                            Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !fixes.isEmpty {
                            Text("Embarsy can fix \(fixes.count) of these by itself — inside your memory base only, with every change shown first.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if !fixes.isEmpty {
                        Button("Fix \(fixes.count) issues…") { showFixAll = true }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(memory.isWorking)
                    }
                }
            }
            if let model = memory.localModel {
                ContradictionCheck(memory: memory, model: model)
            }
            ForEach(HealthFinding.Severity.allCases, id: \.self) { severity in
                let findings = snapshot.findings.filter { $0.severity == severity }
                if !findings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(severity.title) · \(findings.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                        VStack(spacing: 0) {
                            ForEach(findings) { finding in
                                FindingRow(finding: finding, memory: memory)
                                if finding.id != findings.last?.id {
                                    Divider().overlay(Theme.separator)
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showFixAll) {
            FixAllSheet(findings: snapshot.findings.filter { $0.fix != nil }, memory: memory)
        }
    }
}

private struct FindingRow: View {
    let finding: HealthFinding
    @ObservedObject var memory: MemoryService
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(finding.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !finding.paths.isEmpty {
                    FlowLayout(spacing: 4, maxItemWidth: 560) {
                        ForEach(finding.paths, id: \.path) { url in
                            FinderLink(label: MemoryScanner.tilde(url), folder: url,
                                       font: .system(size: 11.5, design: .monospaced))
                        }
                    }
                }
                if let record = finding.contradiction {
                    ContradictionDecision(record: record, memory: memory)
                }
                if let fix = finding.fix {
                    FixPreview(fix: fix)
                    Button(fix.buttonTitle) { Task { await memory.applyFixes([fix]) } }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(memory.isWorking)
                }
                if let action = finding.action {
                    Button(action.title) { memory.requestedTab = action.tab }
                }
                if finding.assist != nil {
                    AssistPanel(finding: finding, memory: memory)
                }
            }
            .padding(.leading, 40)
            .padding(.top, 2)
            .padding(.bottom, 10)
        } label: {
            HStack(spacing: 8) {
                SeverityGlyph(finding: finding)
                Text(finding.title)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if finding.fix != nil {
                    Text("can fix")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.fillQuaternary, in: Capsule())
                        .contentShape(Capsule())
                        .chipHelp("Embarsy can fix this itself. Open the row to see exactly what would change before you apply it.")
                }
            }
            .padding(.vertical, 7)
        }
    }
}

/// H11: the two statements side by side and the person's three answers.
private struct ContradictionDecision: View {
    let record: ContradictionRecord
    @ObservedObject var memory: MemoryService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statement(record.aPath, record.aSays)
            statement(record.bPath, record.bSays)
            Text("Which one is right? The other note gets a short “outdated” line under that sentence.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("\(name(record.aPath)) is right") { Task { await memory.resolveContradiction(record, rightIsA: true) } }
                Button("\(name(record.bPath)) is right") { Task { await memory.resolveContradiction(record, rightIsA: false) } }
                Button("They don't disagree") { Task { await memory.resolveContradiction(record, rightIsA: nil) } }
            }
            .disabled(memory.isWorking)
        }
    }

    private func name(_ path: String) -> String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }

    private func statement(_ path: String, _ says: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            Text("«\(says)»").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// H11 runs on request: it needs the local model and takes a while. One line — what it finds,
/// when it last ran, and the button.
private struct ContradictionCheck: View {
    @ObservedObject var memory: MemoryService
    @ObservedObject var model: LocalModelService

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notes that disagree").font(.system(size: 12.5, weight: .medium))
                Text("Two notes that state different facts mislead your agents; the assistant finds them so you can keep the right one.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = memory.contradictionProgress {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            .frame(maxWidth: 160)
                        Text("\(progress.done) of \(progress.total)")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if memory.contradictionProgress != nil {
                Button("Stop") { memory.stopContradictions() }
            } else if model.isReady {
                Button("Find") { memory.checkContradictions() }
                    .disabled(memory.isWorking)
            } else {
                Button("Set up the assistant") { memory.requestedTab = .assistant }
            }
        }
        .task { await model.refresh() }
    }

    private var status: String {
        guard model.isReady else { return L("Needs the local model") }
        guard let stamp = memory.contradictionsCheckedAt, let date = ISO8601DateFormatter().date(from: stamp) else {
            return L("Not checked yet · takes about 20 min, on your Mac")
        }
        return L("Last checked \(date.formatted(date: .abbreviated, time: .shortened)) · next time only what changed")
    }
}

/// The local model's help with one finding: ask, read the draft, apply it or not.
private struct AssistPanel: View {
    let finding: HealthFinding
    @ObservedObject var memory: MemoryService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch memory.assistStates[finding.id] {
            case nil:
                if memory.localModel?.isReady == true {
                    HStack(spacing: 10) {
                        Button("Ask the assistant") { memory.assist(finding) }
                            .disabled(memory.isWorking)
                        Text("The local model drafts it; nothing changes until you apply it.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        Button("Set up the assistant") { memory.requestedTab = .assistant }
                        Text("The assistant can draft this fix for you — a local model, free and offline.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("The assistant is working on it — usually under a minute.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            case .failed(let why):
                Text(why).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { memory.clearAssist(finding); memory.assist(finding) }
            case .done(let draft):
                resultView(draft)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
    }

    @ViewBuilder
    private func resultView(_ result: AssistResult) -> some View {
        Text(verbatim: result.text)
            .font(.system(size: 12))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        if let profile = result.profile, let vault = memory.vault {
            ScrollView {
                Text(verbatim: AgentsMdBuilder.build(profile: profile, vaultPath: vault.root.path))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Button("Use this profile") {
                    Task { await memory.saveCore(profile); memory.clearAssist(finding) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Discard") { memory.clearAssist(finding) }
            }
        } else if let fix = result.fix {
            FixPreview(fix: fix)
            HStack {
                Button(fix.buttonTitle) {
                    Task { await memory.applyFixes([fix]); memory.clearAssist(finding) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(memory.isWorking)
                Button("Discard") { memory.clearAssist(finding) }
            }
        } else if !result.choices.isEmpty {
            HStack {
                ForEach(Array(result.choices.enumerated()), id: \.offset) { _, choice in
                    Button(choice.label) {
                        Task { await memory.applyFixes([choice.fix]); memory.clearAssist(finding) }
                    }
                    .disabled(memory.isWorking)
                    .chipHelp(verbatim: choice.fix.summary)
                }
                Button("Discard") { memory.clearAssist(finding) }
            }
        } else {
            Button("Done") { memory.clearAssist(finding) }
        }
    }
}

/// Exactly what a fix would change.
private struct FixPreview: View {
    let fix: HealthFix

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fix.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .mergeNotes(let keep, let absorb) = fix {
                Text("keeps → \(keep.lastPathComponent)\nmoves to archive/ → \(absorb.lastPathComponent)")
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .repairLinks(_, let repairs) = fix {
                ForEach(repairs, id: \.original) { repair in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repair.original)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .strikethrough()
                            .lineLimit(1).truncationMode(.middle)
                        Text(verbatim: repair.replacement.map { "→ \($0)" } ?? L("→ link removed, text kept"))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Text(repair.how)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
    }
}

private struct FixAllSheet: View {
    let findings: [HealthFinding]
    @ObservedObject var memory: MemoryService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fix \(findings.count) issues")
                .font(.system(size: 16, weight: .semibold))
            Text("Only files inside your memory base are edited, and their earlier versions stay in its history. Copies outside it are moved to Embarsy's backups, never deleted.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(findings) { finding in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(finding.title).font(.system(size: 12.5, weight: .medium))
                            if let fix = finding.fix { FixPreview(fix: fix) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Fix all") {
                    let fixes = findings.compactMap(\.fix)
                    dismiss()
                    Task { await memory.applyFixes(fixes) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 560)
    }
}

/// The finding's severity, with a hover that says what this particular finding means for the
/// agents — not a legend of all three glyphs.
private struct SeverityGlyph: View {
    let finding: HealthFinding

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(finding.severity == .error ? Color.orange : Color.secondary)
            .frame(width: 18)
            .contentShape(Rectangle())
            .chipHelp(verbatim: Self.help(finding))
    }

    private var symbol: String {
        switch finding.severity {
        case .error: return "exclamationmark.octagon"
        case .warning: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }

    static func help(_ finding: HealthFinding) -> String {
        let kind: String
        switch finding.severity {
        case .error: kind = L("Problem — wrong right now.")
        case .warning: kind = L("Warning — works today, but misleads or breaks later.")
        case .info: kind = L("Note — nothing is broken.")
        }
        guard let why = reasons[finding.code] else { return kind }
        return kind + "\n\n" + why
    }

    /// Why each kind of finding matters, in the terms of what an agent does with the memory.
    private static let reasons: [String: String] = [
        "H01": L("An agent skips this skill without saying so: its name, format or folder depth doesn't fit what the agent accepts."),
        "H02": L("Agents read different versions of the same skill, so they follow different instructions."),
        "H03": L("Two skills share a name where an agent loads them; it picks one, and you can't tell which."),
        "H04": L("An agent following this link finds nothing."),
        "H05": L("The link points at a line number; after any edit it lands on the wrong line."),
        "H06": L("The core is over its budget; every agent pays for each extra line in every session."),
        "H07": L("Someone else's skill was changed in the base; an update would overwrite or conflict with the change."),
        "H08": L("The folder this skill came from has a newer version; nothing is wrong with the one you have."),
        "H09": L("Nobody has re-checked this knowledge in half a year; an agent will trust it as current."),
        "H10": L("Two notes say nearly the same. They'll drift apart, and an agent may recall the older one."),
        "H11": L("Two notes state different facts about the same thing. An agent may trust the outdated one."),
        "H12": L("Something that looks like a password, token or key — every agent that reads the file sees it."),
        "H13": L("Nothing links to this note, so an agent only finds it by search."),
        "H14": L("Someone else's folder sits among an agent's skills and may override yours."),
        "H15": L("There are more skills than the agent's listing has room for; some won't be offered."),
        "H16": L("This agent doesn't load the core, so it doesn't know who you are or your rules."),
        "H17": L("A proposal has been waiting in the inbox a long time; agents can't use it until you decide."),
        "H18": L("This skill is only in folders no agent reads, so no agent uses it."),
        "H19": L("Other agents see skills this one doesn't."),
        "H20": L("Leftover copies in a folder no agent reads; they only confuse a later migration."),
        "H21": L("The link leads to an old copy the migration left behind, not to the note it became; an agent reads stale text."),
    ]
}

// MARK: - Scanned folders

private struct ScannedFoldersSection: View {
    @ObservedObject var memory: MemoryService
    let snapshot: MemorySnapshot

    var body: some View {
        EmbarsySection(title: "Scanned folders", spacing: 10) {
            Text("Where agents load skills and standing instructions from, plus folders you added to compare with — for example the folder where you keep your own copies.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The base's empty skill folders (adopted/, vendor/ before anything is in them) add nothing here.
            ForEach(snapshot.roots.filter { $0.kind != .codexSystem && !($0.kind == .vault && (snapshot.skillCounts[$0.id] ?? 0) == 0) }) { root in
                row(url: root.url, caption: root.summary,
                    trailing: L("\(snapshot.skillCounts[root.id] ?? 0) skills"),
                    removable: root.kind == .extra)
            }
            ForEach(snapshot.instructions) { source in
                row(url: source.exists ? source.url : source.url.deletingLastPathComponent(),
                    label: MemoryScanner.tilde(source.url),
                    caption: L("\(source.agent.label) loads this into every session"),
                    trailing: !source.exists ? L("missing") : source.bytes == 0 ? L("empty") : ByteCountFormatter.string(fromByteCount: Int64(source.bytes), countStyle: .file),
                    removable: false)
            }

            Button {
                pickFolder()
            } label: {
                Label("Add folder…", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
    }

    private func row(url: URL, label: String? = nil, caption: String, trailing: String, removable: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                FinderLink(label: label ?? MemoryScanner.tilde(url), folder: url,
                           font: .system(size: 12, design: .monospaced))
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 8)
            Text(trailing)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if removable {
                Button {
                    memory.removeFolder(url)
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .chipHelp("Stop comparing with this folder. Nothing in it is deleted.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).stroke(Theme.separator))
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = L("Compare")
        panel.message = L("Choose a folder that holds skills, such as a project's .agents/skills, to compare with what your agents see")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        memory.addFolder(url)
    }
}

