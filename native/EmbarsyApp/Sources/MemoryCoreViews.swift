import AppKit
import SwiftUI

// The memory base's own screens: the card offering to set one up, the Start fresh wizard,
// the Core tab, and the list of changes shown before anything outside the base is touched.

// MARK: - Setup card

struct MemorySetupCard: View {
    let startFresh: () -> Void
    let bringExisting: () -> Void

    var body: some View {
        EmbarsySection(title: "Give your agents one memory", spacing: 12) {
            Text("A folder that Claude Code, Codex and Zoo / Roo all read: who you are, how they should work with you, and the skills they share. Plain markdown files — they keep working even without Embarsy.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                option(title: "Start fresh",
                       detail: "Answer a few questions about you and your agent. Takes a couple of minutes.",
                       enabled: true, action: startFresh)
                option(title: "Bring existing memory",
                       detail: "Collect the skills, instructions and notes your agents already have. Your agent sorts them; you review before anything changes.",
                       enabled: true, action: bringExisting)
            }
        }
    }

    private func option(title: LocalizedStringKey, detail: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(enabled ? .primary : .secondary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd)
                .stroke(enabled ? Theme.accent.opacity(0.5) : Theme.separator))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Start fresh wizard

struct MemoryOnboardingSheet: View {
    @ObservedObject var memory: MemoryService
    let onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable {
        case location, me, agent, connect

        var title: String {
            switch self {
            case .location: return L("Where to keep it")
            case .me: return L("Who you are")
            case .agent: return L("Who your agent is")
            case .connect: return L("Connect your agents")
            }
        }
    }

    @State private var step: Step = .location
    @State private var folderPath = ""
    @State private var profile = CoreProfile()
    @State private var agents: Set<MemoryAgent> = []
    @State private var installed: Set<MemoryAgent> = []
    @State private var preview: [MemoryPublisher.Step] = []

    private var folder: URL {
        let expanded = (folderPath.trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private var folderProblem: String? {
        guard !folderPath.trimmed.isEmpty else { return L("Choose a folder.") }
        return VaultCreator.validate(folder)?.errorDescription
    }

    private var canContinue: Bool {
        switch step {
        case .location: return folderProblem == nil
        case .me: return !profile.userName.trimmed.isEmpty
        case .agent: return !profile.agentName.trimmed.isEmpty
        case .connect: return !agents.isEmpty && !memory.isWorking
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch step {
                    case .location: locationStep
                    case .me: CoreMeFields(profile: $profile)
                    case .agent: CoreAgentFields(profile: $profile)
                    case .connect: connectStep
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Theme.separator)
            footer
        }
        .frame(width: 640, height: 600)
        .onAppear {
            folderPath = MemoryScanner.tilde(memory.defaultVaultFolder)
            installed = memory.installedAgents()
            agents = installed
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(step.title)
                .font(.system(size: 17, weight: .semibold))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if step != .location {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .location }
            }
            if step == .connect {
                Button {
                    Task {
                        let ok = await memory.createVault(at: folder, profile: profile,
                                                          agents: MemoryAgent.allCases.filter(agents.contains))
                        if ok {
                            dismiss()
                            onFinished()
                        }
                    }
                } label: {
                    if memory.isWorking { ProgressView().controlSize(.small) } else { Text("Create memory") }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            } else {
                Button("Continue") {
                    step = Step(rawValue: step.rawValue + 1) ?? .connect
                    if step == .connect { refreshPreview() }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A new, empty folder. Everything your agents remember lives here as plain markdown — you can open, read and back it up like any other folder.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("~/EmbarsyMemory", text: $folderPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                Button("Choose…") { chooseFolder() }
            }
            if let problem = folderProblem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                bullet("core/ — who you are and how your agents should work with you. All agents load it in every session.")
                bullet("skills/ — skills every agent shares. Starts with one that teaches agents to use this memory.")
                bullet("knowledge/, experience/, people/ — what agents learn, after you approve it.")
                bullet("inbox/ — where agents propose new memories for you to review.")
            }
            .padding(.top, 4)
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Embarsy points each agent at the memory and connects its recall / remember tools. Their own files stay as they are: it adds links and one import line, and Undo in Memory → Core takes them back out. The tools are disconnected in Connections.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(MemoryAgent.allCases) { agent in
                    Toggle(isOn: Binding(
                        get: { agents.contains(agent) },
                        set: { on in
                            if on { agents.insert(agent) } else { agents.remove(agent) }
                            refreshPreview()
                        }
                    )) {
                        HStack(spacing: 6) {
                            Text(agent.label).font(.system(size: 12.5))
                            (installed.contains(agent) ? Text("found on this Mac") : Text("not found on this Mac"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            if !preview.isEmpty {
                Text("What will change")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.top, 4)
                MemoryPlanList(steps: preview, home: memory.home)
            }

            if let error = memory.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshPreview() {
        preview = memory.previewPlan(profile: profile, agents: MemoryAgent.allCases.filter(agents.contains), at: folder)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Use This Folder")
        panel.message = L("Choose an empty folder for your agents' memory, or create a new one")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderPath = MemoryScanner.tilde(url)
    }
}

// MARK: - Profile fields (shared by the wizard and the Core tab)

struct CoreMeFields: View {
    @Binding var profile: CoreProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your agents read this at the start of every session.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            LabeledField("Name", text: $profile.userName, prompt: "Required — e.g. Jordan")
            LabeledField("Role", text: $profile.role, prompt: "e.g. Product manager and QA engineer")
            LabeledField("Languages", text: $profile.languages, prompt: "e.g. Russian and English")
            LabeledField("Address me as", text: $profile.addressAs, prompt: "e.g. by first name, informally")
            LabeledField("Answer style", text: $profile.answerStyle, prompt: "e.g. short, examples over theory")
            NotesEditor(title: "Anything else about you", text: $profile.aboutMe,
                        prompt: "Context your agents should always have.")
        }
    }
}

struct CoreAgentFields: View {
    @Binding var profile: CoreProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField("Agent's name", text: $profile.agentName, prompt: "Required — e.g. Atlas")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Tone")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Picker("", selection: $profile.tone) {
                    ForEach(CoreProfile.Tone.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            NotesEditor(title: "Character", text: $profile.aboutAgent,
                        prompt: "How your agent should behave beyond tone.")

            Text("Rules")
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 6)
            Toggle("Ask before changing anything — reading needs no permission", isOn: $profile.askBeforeChanges)
            Toggle("Use the browser or the Mac's interface only when asked in the current task", isOn: $profile.browserOnlyOnRequest)
            Toggle("Never store or repeat passwords, tokens or keys", isOn: $profile.noSecrets)
            Toggle("Keep what you said, what was verified and what is inferred apart", isOn: $profile.separateFacts)
            NotesEditor(title: "Your own rules, one per line", text: $profile.customRules,
                        prompt: "e.g. Write skills in Russian")
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12.5))
    }
}

private struct LabeledField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    let prompt: LocalizedStringKey

    init(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey) {
        self.label = label
        self._text = text
        self.prompt = prompt
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
        }
    }
}

private struct NotesEditor: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let prompt: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if text.isEmpty {
                    Text(prompt)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 64)
            .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).stroke(Theme.separator))
        }
    }
}

// MARK: - Plan list

/// Every change publishing would make, and every place it deliberately leaves alone.
struct MemoryPlanList: View {
    let steps: [MemoryPublisher.Step]
    let home: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 8) {
                    PlanGlyph(action: step.action)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(step.what).font(.system(size: 12.5))
                            Text(tilde(step.path))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(Self.describe(step.action, path: step.path))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func tilde(_ url: URL) -> String {
        url.path.hasPrefix(home.path + "/") ? "~" + url.path.dropFirst(home.path.count) : url.path
    }

    static func describe(_ action: MemoryPublisher.Step.Action, path: URL) -> String {
        switch action {
        case .link: return L("Adds a link to the memory base.")
        case .replaceEmptyWithLink: return L("The file is empty; it becomes a link to the memory base. A copy is kept.")
        case .appendBlock:
            return FileManager.default.fileExists(atPath: path.path)
                ? L("Adds an import line at the end. Your text stays as it is; a copy is kept.")
                : L("Creates it with one import line.")
        case .editJSON(let edit):
            switch edit.mode {
            case .set: return L("Sets \(edit.keyPath.joined(separator: ".")) to the inbox, so what Claude Code remembers waits for your review. A copy is kept.")
            case .addToArray: return L("Adds the memory base to \(edit.keyPath.joined(separator: ".")), so Claude Code can read it without asking each time. A copy is kept.")
            }
        case .replaceWithLink:
            return L("The old copy here goes to Embarsy's backups and a link to the base takes its place. Undo puts it back.")
        case .replaceContent:
            return L("Its old content is now in the core: it goes to Embarsy's backups and the file keeps only the import line. Undo puts it back.")
        case .moveAside:
            return L("Moved to Embarsy's backups — agents stop loading it. Undo puts it back.")
        case .removeLink: return L("Removes the link Embarsy made — the skill is no longer in the base.")
        case .alreadyDone: return L("Already set up.")
        case .skip(let reason): return L("Left as it is. \(reason)")
        }
    }
}

private struct PlanGlyph: View {
    let action: MemoryPublisher.Step.Action

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(color)
            .frame(width: 18)
            .contentShape(Rectangle())
            .chipHelp("\(meaning)\n\nTeal arrow — Embarsy will change this. Green check — already set up, nothing to do. Grey dash — left as it is on purpose; the line below says why.")
    }

    private var symbol: String {
        switch action {
        case .link, .replaceEmptyWithLink, .appendBlock, .editJSON, .removeLink, .replaceWithLink, .replaceContent, .moveAside: return "arrow.right.circle"
        case .alreadyDone: return "checkmark.circle"
        case .skip: return "minus.circle"
        }
    }

    private var color: Color {
        switch action {
        case .link, .replaceEmptyWithLink, .appendBlock, .editJSON, .removeLink, .replaceWithLink, .replaceContent, .moveAside: return Theme.accent
        case .alreadyDone: return Color(nsColor: .systemGreen)
        case .skip: return .secondary
        }
    }

    private var meaning: String {
        switch action {
        case .link, .replaceEmptyWithLink, .appendBlock, .editJSON, .removeLink, .replaceWithLink, .replaceContent, .moveAside: return L("Will change.")
        case .alreadyDone: return L("Already set up.")
        case .skip: return L("Left as it is.")
        }
    }
}

/// One "is it connected" mark. Two shapes, so it reads without colour; the hover says what
/// this mark is about and what both shapes mean.
private struct LinkStateGlyph: View {
    let on: Bool
    let label: String
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: on ? "checkmark.circle" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(on ? Color(nsColor: .systemGreen) : Color.secondary)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .chipHelp(verbatim: help)
    }
}

// MARK: - Core tab

struct MemoryCorePanel: View {
    @ObservedObject var memory: MemoryService
    @State private var draft = CoreProfile()
    @State private var loaded = false
    @State private var showPublish = false
    @State private var confirmUndo = false

    private var vault: VaultLayout? { memory.vault }
    private var pendingChanges: [MemoryPublisher.Step] { memory.plan.filter(\.changesSomething) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let vault {
                baseRow(vault)
                agentsRow
                messages
                Divider().overlay(Theme.separator)
                CoreMeFields(profile: $draft)
                Divider().overlay(Theme.separator)
                CoreAgentFields(profile: $draft)
                HStack {
                    Button("Revert") { draft = memory.profile }
                        .disabled(draft == memory.profile)
                    Spacer()
                    Button("Save") { Task { await memory.saveCore(draft) } }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(draft == memory.profile || !draft.isComplete || memory.isWorking)
                }
                Divider().overlay(Theme.separator)
                undoRow(vault)
            }
        }
        .onAppear {
            if !loaded { draft = memory.profile; loaded = true }
        }
        .onChange(of: memory.profile) { draft = $0 }
        .sheet(isPresented: $showPublish) { publishSheet }
    }

    private func baseRow(_ vault: VaultLayout) -> some View {
        let size = (try? Data(contentsOf: vault.agentsMd).count) ?? 0
        let over = size > AgentsMdBuilder.budgetBytes
        return HStack(spacing: 10) {
            FinderLink(label: vault.displayPath(home: memory.home), folder: vault.root,
                       font: .system(size: 12, design: .monospaced))
            Spacer(minLength: 8)
            FinderLink(label: "AGENTS.md", folder: vault.agentsMd, font: .system(size: 12, design: .monospaced))
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) of 4 KB")
                .font(.system(size: 11.5))
                .foregroundStyle(over ? Color.orange : Color.secondary)
                .chipHelp("Every agent loads AGENTS.md into every session, so it is kept under 4 KB. It's built from the fields below — edit them, not the file.")
        }
    }

    private var agentsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Agents")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Button(pendingChanges.isEmpty ? L("Up to date") : L("Publish \(pendingChanges.count) changes…")) {
                    showPublish = true
                }
                .disabled(pendingChanges.isEmpty || memory.isWorking)
            }
            ForEach(memory.manifest.agents) { agent in
                HStack(spacing: 14) {
                    Text(agent.label)
                        .font(.system(size: 12))
                        .frame(width: 100, alignment: .leading)
                    LinkStateGlyph(on: memory.publisher?.coreConnected(for: agent) ?? false,
                                   label: L("core"),
                                   help: L("Core — \(agent.label) loads your AGENTS.md in every session. Green check — it does. Empty circle — not yet; publish to connect it."))
                    if let tools = memory.toolsConnected {
                        let on = tools(agent)
                        LinkStateGlyph(on: on, label: L("recall & remember"),
                                       help: L("Tools — \(agent.label) can search your memory (recall) and propose to it (remember). Green check — connected. Empty circle — not connected; it can still read the folder, but slower and less reliably."))
                        if !on, memory.connectTools != nil {
                            Button("Connect tools") { memory.connectToolsNow(agent) }
                                .controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder private var messages: some View {
        if let error = memory.lastError {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let notice = memory.lastNotice {
            Text(notice)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func undoRow(_ vault: VaultLayout) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Undo setup")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Removes the links and import lines Embarsy added, puts back the files it replaced, and moves \(vault.displayPath(home: memory.home)) to the Trash.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Undo setup…") { confirmUndo = true }
                .disabled(memory.isWorking)
        }
        .confirmationDialog("Undo the memory setup?", isPresented: $confirmUndo) {
            Button("Undo setup", role: .destructive) { Task { await memory.undoSetup() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Agents stop loading this memory. The folder goes to the Trash, so you can still get it back from there.")
        }
    }

    private var publishSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Publish to your agents")
                .font(.system(size: 16, weight: .semibold))
            ScrollView {
                MemoryPlanList(steps: memory.plan, home: memory.home)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel") { showPublish = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Publish") {
                    showPublish = false
                    Task { await memory.publish() }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 440)
    }
}
