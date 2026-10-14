import AppKit
import SwiftUI

// "Bring existing memory": choose the folder and the sources, hand the task to an agent,
// review its plan, apply it.

// MARK: - Start

struct MigrationStartSheet: View {
    @ObservedObject var memory: MemoryService
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var folderPath = ""
    @State private var sources: [MigrationSource] = []
    @State private var chosen: Set<String> = []
    @State private var agents: Set<MemoryAgent> = []
    @State private var installed: Set<MemoryAgent> = []

    private var folder: URL {
        URL(fileURLWithPath: (folderPath.trimmed as NSString).expandingTildeInPath).standardizedFileURL
    }
    private var folderProblem: String? {
        folderPath.trimmed.isEmpty ? L("Choose a folder.") : VaultCreator.validate(folder)?.errorDescription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Step \(step + 1) of 2").font(.system(size: 11)).foregroundStyle(.tertiary)
                (step == 0 ? Text("Where to keep it") : Text("What to bring in")).font(.system(size: 17, weight: .semibold))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Theme.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if step == 0 { locationStep } else { sourcesStep }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Theme.separator)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if step == 1 { Button("Back") { step = 0 } }
                if step == 0 {
                    Button("Continue") { step = 1 }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(folderProblem != nil)
                } else {
                    Button {
                        Task {
                            let picked = sources.filter { chosen.contains($0.id) }
                            if await memory.startMigration(at: folder, sources: picked,
                                                           agents: MemoryAgent.allCases.filter(agents.contains)) {
                                dismiss()
                            }
                        }
                    } label: {
                        if memory.isWorking { ProgressView().controlSize(.small) } else { Text("Scan") }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || agents.isEmpty || memory.isWorking)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 680, height: 600)
        .onAppear {
            folderPath = MemoryScanner.tilde(memory.defaultVaultFolder)
            sources = memory.migrationSources()
            // Zoo's leftover copies are not read by anything; the rest is what agents use.
            chosen = Set(sources.filter { !$0.path.contains("globalStorage") }.map(\.id))
            installed = memory.installedAgents()
            agents = installed
        }
    }

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A new, empty folder for the memory base. What you bring in is copied here; the originals stay where they are until you've reviewed the result.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("~/EmbarsyMemory", text: $folderPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = L("Use This Folder")
                    if panel.runModal() == .OK, let url = panel.url { folderPath = MemoryScanner.tilde(url) }
                }
            }
            if let problem = folderProblem {
                Text(verbatim: problem).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sourcesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where your agents keep memory today. Embarsy only reads these; it backs them all up before anything changes.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sources) { source in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(source.id) },
                        set: { on in if on { chosen.insert(source.id) } else { chosen.remove(source.id) } }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(verbatim: source.label).font(.system(size: 12.5))
                                Text("\(source.fileCount) files")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                            Text(MemoryScanner.tilde(source.url))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.showsHiddenFiles = true
                panel.prompt = L("Add")
                panel.message = L("A folder where you keep skills or notes for your agents")
                if panel.runModal() == .OK, let url = panel.url {
                    let source = MigrationSources.folder(url)
                    if !sources.contains(where: { $0.id == source.id }) { sources.append(source) }
                    chosen.insert(source.id)
                }
            } label: {
                Label("Add folder…", systemImage: "plus")
            }
            Text("Agents to connect").font(.system(size: 12, weight: .semibold)).padding(.top, 6)
            HStack(spacing: 16) {
                ForEach(MemoryAgent.allCases) { agent in
                    Toggle(agent.label, isOn: Binding(
                        get: { agents.contains(agent) },
                        set: { on in if on { agents.insert(agent) } else { agents.remove(agent) } }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                }
            }
            if let error = memory.lastError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - In progress

struct MigrationCard: View {
    @ObservedObject var memory: MemoryService
    let session: MigrationSession
    @State private var copied = false
    @State private var showReview = false
    @State private var confirmCancel = false

    var body: some View {
        EmbarsySection(title: "Bringing in your existing memory", spacing: 12) {
            let inv = session.inventory
            Text("Embarsy found \(inv.skills.count) skills (\(inv.skills.filter(\.copiesDiffer).count) with copies that differ), \(inv.instructions.count) instruction files, \(inv.claudeMemories.count) Claude Code memories and \(inv.experienceEntries.count) journal entries. Deciding what goes where takes judgement: give it to your agent, or let the local model draft it.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let plan = session.plan {
                planReady(plan)
            } else {
                handOff
            }
            if let error = session.planError ?? memory.lastError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                FinderLink(label: L("Task and inventory"), folder: session.staging.task, font: .system(size: 12))
                Spacer()
                Button("Cancel migration…") { confirmCancel = true }
            }
        }
        .task(id: session.staging.root) {
            while !Task.isCancelled {
                memory.checkForPlan()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .sheet(isPresented: $showReview) {
            if let plan = session.plan {
                MigrationReviewSheet(memory: memory, session: session, plan: plan)
            }
        }
        .confirmationDialog("Cancel bringing in your memory?", isPresented: $confirmCancel) {
            Button("Cancel migration", role: .destructive) { memory.cancelMigration() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("The scan, the task and any plan are deleted. Nothing in your agents' folders was changed.")
        }
    }

    private var handOff: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Give this to Claude Code or Codex")
                .font(.system(size: 12.5, weight: .semibold))
            HStack(alignment: .top, spacing: 8) {
                Text(MigrationTask.prompt(staging: session.staging))
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).stroke(Theme.separator))
                Button(copied ? L("Copied") : L("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MigrationTask.prompt(staging: session.staging), forType: .string)
                    copied = true
                }
            }
            if memory.localPlanProgress == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the agent's plan. It only reads your files; nothing changes until you approve the plan here.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let model = memory.localModel {
                LocalPlanRow(memory: memory, model: model)
            }
        }
    }

    private func planReady(_ plan: MigrationPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The plan is ready").font(.system(size: 12.5, weight: .semibold))
            if let summary = plan.summary, !summary.trimmed.isEmpty {
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Review plan…") { showReview = true }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
    }
}

/// The other way to get a plan: Embarsy's own local model, when one is downloaded.
private struct LocalPlanRow: View {
    @ObservedObject var memory: MemoryService
    @ObservedObject var model: LocalModelService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or let the local model draft it").font(.system(size: 12.5, weight: .semibold))
                .padding(.top, 4)
            if let progress = memory.localPlanProgress {
                HStack(spacing: 10) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(maxWidth: 260)
                    Text("\(progress.done) of \(progress.total) · \(progress.what)")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Stop") { memory.stopLocalPlan() }
                }
                Text("Nothing leaves your Mac. The model leaves memory a few minutes after it's done.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if model.isReady {
                HStack(spacing: 10) {
                    Button("Plan with the local model") { memory.planMigrationLocally() }
                    Text("A few minutes; nothing leaves your Mac. A first draft — check it closely in the review.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 10) {
                    Button("Set up the assistant") { memory.requestedTab = .assistant }
                    Text("The assistant can sort it all into a plan in about ten minutes — no agent, nothing leaves your Mac.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await model.refresh() }
    }
}

// MARK: - Review

struct MigrationReviewSheet: View {
    @ObservedObject var memory: MemoryService
    let session: MigrationSession
    let plan: MigrationPlan
    @Environment(\.dismiss) private var dismiss

    @State private var selection = MigrationSelection()
    @State private var clearSkipped = true
    @State private var prepared = false

    private var validator: MigrationValidator { MigrationValidator(state: session.state, staging: session.staging) }
    private var previewLayout: VaultLayout { VaultLayout(root: URL(fileURLWithPath: session.state.vaultPath)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review the plan").font(.system(size: 17, weight: .semibold))
                if let summary = plan.summary {
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Theme.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let questions = plan.questions, !questions.isEmpty { choicesSection(questions) }
                    coreSection
                    skillsSection
                    notesSection
                    skipSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disclosureGroupStyle(TappableDisclosureStyle())
            Divider().overlay(Theme.separator)
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text(verbatim: selection.useCore
                     ? L("\(selection.skills.count) skills · \(selection.notes.count) notes · core")
                     : L("\(selection.skills.count) skills · \(selection.notes.count) notes"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Button {
                    Task {
                        await memory.applyMigration(selection: selection, clearSkippedCopies: clearSkipped)
                        dismiss()
                    }
                } label: {
                    if memory.isWorking { ProgressView().controlSize(.small) } else { Text("Create memory") }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(memory.isWorking)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 780, height: 680)
        .onAppear(perform: prepare)
    }

    /// Everything valid is in, except that of each set of alternatives only the first is.
    private func prepare() {
        guard !prepared else { return }
        prepared = true
        var seenChoices = Set<String>()
        for s in plan.skills ?? [] where validator.problem(skill: s) == nil {
            if let c = s.choice { guard seenChoices.insert("s" + c).inserted else { continue } }
            selection.skills.insert(s.id)
        }
        for n in plan.notes ?? [] where validator.problem(note: n, vault: previewLayout) == nil {
            if let c = n.choice { guard seenChoices.insert("n" + c).inserted else { continue } }
            selection.notes.insert(n.id)
        }
        selection.useCore = plan.core != nil
    }

    private func header(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13.5, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choicesSection(_ questions: [MigrationPlan.Question]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Your decisions", "Where the agent wasn't sure, it offers alternatives. Pick one, or none.")
            ForEach(questions) { q in
                let skillAlts = (plan.skills ?? []).filter { $0.choice == q.choice }
                let noteAlts = (plan.notes ?? []).filter { $0.choice == q.choice }
                VStack(alignment: .leading, spacing: 4) {
                    Text(q.question).font(.system(size: 12.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(skillAlts) { alt in
                        choiceRow(on: selection.skills.contains(alt.id), title: L("Skill \(alt.name)"), detail: alt.reason ?? alt.from ?? "") {
                            skillAlts.forEach { selection.skills.remove($0.id) }
                            selection.skills.insert(alt.id)
                        }
                    }
                    ForEach(noteAlts) { alt in
                        choiceRow(on: selection.notes.contains(alt.id), title: alt.path, detail: alt.reason ?? "") {
                            noteAlts.forEach { selection.notes.remove($0.id) }
                            selection.notes.insert(alt.id)
                        }
                    }
                    choiceRow(on: !skillAlts.contains { selection.skills.contains($0.id) } && !noteAlts.contains { selection.notes.contains($0.id) },
                              title: L("None of these"), detail: "") {
                        skillAlts.forEach { selection.skills.remove($0.id) }
                        noteAlts.forEach { selection.notes.remove($0.id) }
                    }
                }
            }
        }
    }

    private func choiceRow(on: Bool, title: String, detail: String, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? Theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5))
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var coreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Core", "Loaded by every agent in every session. You can edit it in Memory → Core afterwards.")
            if plan.core != nil {
                Toggle("Use this core", isOn: $selection.useCore).toggleStyle(.checkbox).font(.system(size: 12.5))
                let built = AgentsMdBuilder.build(profile: plan.profile, vaultPath: previewLayout.displayPath(home: memory.home))
                Text(built)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).stroke(Theme.separator))
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(built.utf8.count), countStyle: .file)) of 4 KB")
                    .font(.system(size: 11))
                    .foregroundStyle(built.utf8.count > AgentsMdBuilder.budgetBytes ? Color.orange : Color.secondary)
                if let reason = plan.core?.reason { reasonText(reason) }
                if let sources = plan.core?.sources, !sources.isEmpty {
                    Text(verbatim: L("Taken from: \(sources.map { MemoryScanner.tilde(URL(fileURLWithPath: $0)) }.joined(separator: ", "))"))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("The plan has no core. You'll fill it in Memory → Core.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var skillsSection: some View {
        let skills = (plan.skills ?? []).filter { $0.choice == nil }
        return VStack(alignment: .leading, spacing: 6) {
            header("Skills (\(skills.count))", "Each is copied into the base; the old copies in agents' folders go to the backups and are replaced with links.")
            ForEach(skills) { s in
                let problem = validator.problem(skill: s)
                itemRow(on: Binding(get: { selection.skills.contains(s.id) },
                                    set: { if $0 { selection.skills.insert(s.id) } else { selection.skills.remove(s.id) } }),
                        title: s.name,
                        badge: s.origin ?? "own",
                        badgeHelp: L("Origin. own — yours. adopted — yours to edit, origin unknown. vendor — someone else's, kept as it is."),
                        detail: s.from.map { L("from \(MemoryScanner.tilde(URL(fileURLWithPath: $0)))") } ?? L("new SKILL.md written by the agent"),
                        reason: s.reason, problem: problem,
                        preview: s.skill_md)
            }
        }
    }

    private var notesSection: some View {
        let notes = (plan.notes ?? []).filter { $0.choice == nil }
        return VStack(alignment: .leading, spacing: 6) {
            header("Notes (\(notes.count))", "Knowledge, experience and people. Each becomes a markdown note that agents find with recall.")
            ForEach(notes) { n in
                let problem = validator.problem(note: n, vault: previewLayout)
                itemRow(on: Binding(get: { selection.notes.contains(n.id) },
                                    set: { if $0 { selection.notes.insert(n.id) } else { selection.notes.remove(n.id) } }),
                        title: n.path,
                        badge: n.type ?? "",
                        badgeHelp: L("What kind of note: knowledge — facts on a subject; experience — work done and verified; person — about someone."),
                        detail: n.from.map { L("from \(MemoryScanner.tilde(URL(fileURLWithPath: $0)))") } ?? L("written by the agent"),
                        reason: n.reason, problem: problem,
                        preview: validator.noteText(n))
            }
        }
    }

    private var skipSection: some View {
        let skips = plan.skip ?? []
        return VStack(alignment: .leading, spacing: 6) {
            header("Not brought in (\(skips.count))", "These stay where they are.")
            if skips.contains(where: { skip in MemoryService.agentSkillFolders(home: memory.home).contains { URL(fileURLWithPath: skip.source).deletingLastPathComponent().path == $0 } }) {
                Toggle("Move the ones in agents' skill folders to the backups, so agents stop loading them", isOn: $clearSkipped)
                    .toggleStyle(.checkbox).font(.system(size: 12.5))
            }
            ForEach(skips) { skip in
                VStack(alignment: .leading, spacing: 1) {
                    Text(MemoryScanner.tilde(URL(fileURLWithPath: skip.source)))
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    if let reason = skip.reason { reasonText(reason) }
                }
            }
        }
    }

    private func reasonText(_ reason: String) -> some View {
        Text(reason).font(.system(size: 11.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func itemRow(on: Binding<Bool>, title: String, badge: String, badgeHelp: String, detail: String,
                         reason: String?, problem: String?, preview: String?) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let reason { reasonText(reason) }
                if let preview, !preview.trimmed.isEmpty {
                    Text(String(preview.prefix(1500)) + (preview.count > 1500 ? "\n…" : ""))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                }
            }
            .padding(.leading, 44).padding(.vertical, 4)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden().disabled(problem != nil)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 12.5, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        if !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.fillQuaternary, in: Capsule())
                                .contentShape(Capsule())
                                .chipHelp(verbatim: badgeHelp)
                        }
                    }
                    Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                    if let problem {
                        Text("Can't bring this in: \(problem)").font(.system(size: 11.5)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
