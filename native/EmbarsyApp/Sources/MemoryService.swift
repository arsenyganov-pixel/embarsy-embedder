import Foundation

/// A migration from its scan until it is applied (docs/memory-spec.md §9.2).
struct MigrationSession: Equatable {
    let staging: MigrationStaging
    let state: MigrationState
    let inventory: MigrationInventory
    var plan: MigrationPlan?
    var planError: String?
    var planModified: Date?

    static func == (a: MigrationSession, b: MigrationSession) -> Bool {
        a.staging == b.staging && a.plan == b.plan && a.planError == b.planError && a.planModified == b.planModified
    }
}

/// Owns the Memory screen: the read-only scan of what agents see, and — once the user sets
/// one up — the memory base, its core profile and its publication to agents.
///
/// Kept between launches in UserDefaults (not on the user's disk): the extra folders to
/// compare with and where the base is.
@MainActor
final class MemoryService: ObservableObject {
    @Published private(set) var snapshot: MemorySnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var extraFolders: [URL]

    @Published private(set) var vault: VaultLayout?
    @Published private(set) var manifest = MemoryManifest()
    @Published private(set) var profile = CoreProfile()
    /// What publishing would change right now; recomputed after every scan.
    @Published private(set) var plan: [MemoryPublisher.Step] = []
    @Published private(set) var isWorking = false
    /// The last thing that went wrong, in words for the user. Cleared by the next success.
    @Published var lastError: String?
    /// The last thing that went right and needs the user to act (e.g. restart agents).
    @Published var lastNotice: String?
    /// Proposals waiting for the user, newest first.
    @Published private(set) var inbox: [InboxItem] = []
    /// A "Bring existing memory" in progress: from the scan until it is applied or cancelled.
    @Published private(set) var migration: MigrationSession?

    /// Set by the app: whether an agent has Embarsy's MCP tools (recall / remember), and how
    /// to connect them. Left nil where there is no app around (tests, previews).
    var toolsConnected: ((MemoryAgent) -> Bool)?
    var connectTools: ((MemoryAgent) -> Void)?
    /// Set by the app: where the Embarsy API is, for finding notes similar to a proposal.
    var searchConfig: (() -> MemorySearchConfig?)?
    /// Set by the app: refresh the index recall searches after the base changed.
    var reindex: (() -> Void)?
    /// Set by the app: the optional local model, for planning a migration without an agent.
    var localModel: LocalModelService?

    struct LocalPlanProgress: Equatable {
        var done: Int
        var total: Int
        var what: String
    }
    /// While the local model plans the migration.
    @Published private(set) var localPlanProgress: LocalPlanProgress?
    private var localPlanTask: Task<Void, Never>?

    let home: URL
    private let defaults: UserDefaults
    private static let extraFoldersKey = "memoryExtraSkillFolders"
    private static let vaultPathKey = "memoryVaultPath"

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard) {
        self.home = home
        self.defaults = defaults
        self.extraFolders = (defaults.stringArray(forKey: Self.extraFoldersKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        if let path = defaults.string(forKey: Self.vaultPathKey) {
            loadVault(at: URL(fileURLWithPath: path))
        }
        if vault == nil { resumeMigration() }
    }

    var defaultVaultFolder: URL { home.appendingPathComponent("EmbarsyMemory") }

    /// Health has Problems — an agent is missing something or getting it wrong right now.
    /// Warnings and notes don't count: orange is kept for real failures.
    var hasProblems: Bool { snapshot?.findings.contains { $0.severity == .error } ?? false }

    /// Problems in Health, newest scan, for the navigation's hover.
    var problemCount: Int { snapshot?.findings.filter { $0.severity == .error }.count ?? 0 }

    var publisher: MemoryPublisher? {
        vault.map { MemoryPublisher(layout: $0, home: home) }
    }

    // MARK: Scan

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        let folders = extraFolders
        let vault = self.vault
        let home = self.home
        let agents = manifest.agents
        // A few hundred files are hashed; keep that off the main thread.
        let (result, plan) = await Task.detached(priority: .userInitiated) {
            let snapshot = MemoryScanner(home: home, extraFolders: folders, vault: vault).scan()
            let plan = vault.map { MemoryPublisher(layout: $0, home: home).plan(agents: agents) } ?? []
            return (snapshot, plan)
        }.value
        snapshot = result
        self.plan = plan
        inbox = vault.map { MemoryInbox(layout: $0).items() } ?? []
        isScanning = false
        // H11 verdicts are already on disk; only open ones whose passages are unchanged show.
        if let vault, var current = snapshot {
            let contradictions = Contradictions.findings(vault)
            if !contradictions.isEmpty {
                current.findings += contradictions
                current.findings.sort { ($0.severity, $0.code, -$0.weight, $0.title) < ($1.severity, $1.code, -$1.weight, $1.title) }
                snapshot = current
            }
        }
        // H10 needs the index's vectors, so it comes from the API, after the file checks.
        if let vault, let config = searchConfig?() {
            let duplicates = await NearDuplicates.find(config: config, vault: vault)
            if !duplicates.isEmpty, var current = snapshot {
                current.findings += duplicates
                current.findings.sort { ($0.severity, $0.code, -$0.weight, $0.title) < ($1.severity, $1.code, -$1.weight, $1.title) }
                snapshot = current
            }
        }
    }

    func addFolder(_ url: URL) {
        let folder = url.standardizedFileURL
        guard !extraFolders.contains(where: { $0.path == folder.path }) else { return }
        extraFolders.append(folder)
        persistFolders()
        Task { await rescan() }
    }

    func removeFolder(_ url: URL) {
        extraFolders.removeAll { $0.path == url.path }
        persistFolders()
        Task { await rescan() }
    }

    private func persistFolders() {
        defaults.set(extraFolders.map(\.path), forKey: Self.extraFoldersKey)
    }

    // MARK: Agents on this Mac

    /// Agents that look installed: their app, their settings folder or, for Zoo / Roo, the
    /// VS Code extension.
    func installedAgents() -> Set<MemoryAgent> {
        let fm = FileManager.default
        var found = Set<MemoryAgent>()
        if fm.fileExists(atPath: home.appendingPathComponent(".claude").path)
            || fm.fileExists(atPath: "/Applications/Claude.app") { found.insert(.claude) }
        if fm.fileExists(atPath: home.appendingPathComponent(".codex").path)
            || fm.fileExists(atPath: "/Applications/Codex.app") { found.insert(.codex) }
        let extensions = (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(".vscode/extensions").path)) ?? []
        if fm.fileExists(atPath: home.appendingPathComponent(".roo").path)
            || extensions.contains(where: { $0.contains("zoo-code") || $0.contains("roo-cline") }) { found.insert(.zoo) }
        return found
    }

    // MARK: Creating the base

    /// What connecting would change, worked out on a throwaway copy of the base so nothing
    /// is written to the real location before the user confirms.
    func previewPlan(profile: CoreProfile, agents: [MemoryAgent], at root: URL) -> [MemoryPublisher.Step] {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("embarsy-memory-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let layout = try? VaultCreator.create(at: scratch.appendingPathComponent(root.lastPathComponent),
                                                    profile: profile, agents: agents, home: home) else { return [] }
        let real = VaultLayout(root: root)
        return MemoryPublisher(layout: layout, home: home).plan(agents: agents).map { step in
            // Show the real base's paths, not the throwaway's.
            let swap = { (path: String) in path.replacingOccurrences(of: layout.root.path, with: real.root.path) }
            let action: MemoryPublisher.Step.Action
            switch step.action {
            case .link(let target): action = .link(to: URL(fileURLWithPath: swap(target.path)))
            case .editJSON(let edit): action = .editJSON(.init(keyPath: edit.keyPath, value: swap(edit.value), mode: edit.mode))
            default: action = step.action
            }
            return MemoryPublisher.Step(path: step.path, action: action, agents: step.agents, what: step.what)
        }
    }

    /// Creates the base, starts its history and connects the chosen agents.
    func createVault(at root: URL, profile: CoreProfile, agents: [MemoryAgent]) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        let home = self.home
        let result: Result<(VaultLayout, MemoryPublisher.Outcome), Error> = await Task.detached {
            do {
                let layout = try VaultCreator.create(at: root, profile: profile, agents: agents, home: home)
                MemoryGit(root: layout.root).initialize(message: "Memory created")
                let publisher = MemoryPublisher(layout: layout, home: home)
                return .success((layout, publisher.apply(publisher.plan(agents: agents))))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .failure(let error):
            lastError = error.localizedDescription
            return false
        case .success(let (layout, outcome)):
            defaults.set(layout.root.path, forKey: Self.vaultPathKey)
            loadVault(at: layout.root)
            // recall / remember come from Embarsy's MCP bridge; connect it where it isn't yet.
            for agent in agents { connectTools?(agent) }
            reindex?()
            report(outcome, agents: agents)
            await rescan()
            return true
        }
    }

    private func loadVault(at root: URL) {
        let layout = VaultLayout(root: root)
        guard let manifest = MemoryManifest.load(at: layout.manifest) else {
            vault = nil
            writePointer(nil)
            return
        }
        vault = layout
        self.manifest = manifest
        profile = CoreProfile.load(from: layout)
        writePointer(layout)
        refreshGeneratedFiles(layout)
    }

    /// Where the bridge looks for the base (memory.json in Embarsy's Application Support).
    /// A pointer rather than a path baked into each agent's config: moving or recreating the
    /// base then never needs agents reconnected.
    var pointerFile: URL { home.appendingPathComponent("Library/Application Support/Embarsy/memory.json") }

    private func writePointer(_ layout: VaultLayout?) {
        var pointer: [String: String] = [:]
        if let layout { pointer["vault"] = layout.root.path }
        if let migration { pointer["migration"] = migration.staging.root.path }
        if pointer.isEmpty {
            try? FileManager.default.removeItem(at: pointerFile)
            return
        }
        try? FileManager.default.createDirectory(at: pointerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try? JSONSerialization.data(withJSONObject: pointer, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try? data?.write(to: pointerFile, options: .atomic)
    }

    /// Brings what Embarsy generates up to this version: AGENTS.md is rebuilt from core/, and
    /// the starter skill is upgraded only while it is still exactly as Embarsy first wrote it.
    private func refreshGeneratedFiles(_ layout: VaultLayout) {
        let fm = FileManager.default
        let path = layout.displayPath(home: home)
        let built = AgentsMdBuilder.build(profile: profile, vaultPath: path)
        let rebuildCore = (try? String(contentsOf: layout.agentsMd, encoding: .utf8)) != built
        let skill = layout.ownSkills.appendingPathComponent("embarsy-memory/SKILL.md")
        let upgradeSkill = fm.fileExists(atPath: skill.path)
            && (try? String(contentsOf: skill, encoding: .utf8)) == VaultCreator.starterSkillV1(vaultPath: path)
        guard rebuildCore || upgradeSkill else { return }

        // Whatever else changed is recorded first, so this commit holds only Embarsy's own update.
        let git = MemoryGit(root: layout.root)
        git.commitExternalChanges()
        if rebuildCore { try? built.write(to: layout.agentsMd, atomically: true, encoding: .utf8) }
        if upgradeSkill { try? VaultCreator.starterSkill(vaultPath: path).write(to: skill, atomically: true, encoding: .utf8) }
        git.commit(message: "Core and starter skill updated for this Embarsy version",
                   trailers: ["Source": "Embarsy update"])
    }

    // MARK: Core

    func saveCore(_ newProfile: CoreProfile) async {
        guard let vault else { return }
        let home = self.home
        let error: String? = await Task.detached {
            let git = MemoryGit(root: vault.root)
            git.commitExternalChanges()
            do {
                try newProfile.write(to: vault)
                try VaultCreator.writeAgentsMd(layout: vault, profile: newProfile, home: home)
            } catch {
                return error.localizedDescription
            }
            if case .blockedBySecret(let why) = git.commit(message: "Core: profile updated in Embarsy",
                                                           trailers: ["Agent": "user", "Source": "Memory → Core", "Approved-by": "user"]) {
                return L("Saved, but not kept in history: \(why). Remove it from the core.")
            }
            return nil
        }.value
        profile = CoreProfile.load(from: vault)
        lastError = error
        if error == nil {
            lastNotice = L("Saved. Agents pick up the new core in their next session.")
            reindex?()
        }
        await rescan()
    }

    // MARK: Publishing

    func publish() async {
        guard let publisher else { return }
        isWorking = true
        defer { isWorking = false }
        let steps = plan
        let outcome = await Task.detached { publisher.apply(steps) }.value
        report(outcome, agents: manifest.agents)
        await rescan()
    }

    /// Takes back every link and line Embarsy added, then moves the base to the Trash.
    func undoSetup() async {
        guard let vault, let publisher else { return }
        isWorking = true
        defer { isWorking = false }
        let problems = await Task.detached { publisher.undoAll() }.value
        do {
            try FileManager.default.trashItem(at: vault.root, resultingItemURL: nil)
        } catch {
            lastError = L("Agents are disconnected, but the base couldn't be moved to the Trash: \(error.localizedDescription)")
        }
        defaults.removeObject(forKey: Self.vaultPathKey)
        writePointer(nil)
        inbox = []
        self.vault = nil
        manifest = MemoryManifest()
        profile = CoreProfile()
        plan = []
        if !problems.isEmpty {
            lastError = L("Undone, except: \(problems.joined(separator: " "))")
        } else if lastError == nil {
            lastNotice = L("Undone. The base is in the Trash; restart your agents so they drop it.")
        }
        await rescan()
    }

    /// Connects an agent's recall / remember tools, then redraws: their state lives in the
    /// app's store, which the Memory screen doesn't observe.
    func connectToolsNow(_ agent: MemoryAgent) {
        connectTools?(agent)
        objectWillChange.send()
    }

    // MARK: Health fixes

    /// Applies fixes Health offered, then records them in the base's history.
    func applyFixes(_ fixes: [HealthFix]) async {
        guard let vault, !fixes.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        let home = self.home
        let problems: [String] = await Task.detached {
            let git = MemoryGit(root: vault.root)
            git.commitExternalChanges()
            var problems: [String] = []
            // Links are repaired before line numbers are stripped: a repair finds its link by
            // the exact text, line number included.
            let rank = { (fix: HealthFix) -> Int in
                switch fix {
                case .repairLinks: return 0
                case .stripLineNumbers: return 1
                case .mergeNotes: return 2
                case .moveLeftovers: return 3
                case .revertVendor, .updateVendor: return 4
                case .quoteFrontmatter, .setSkillName, .setDescription: return 5
                case .adoptSkill, .keepCopy: return 6
                case .publish: return 7
                }
            }
            for fix in fixes.sorted(by: { rank($0) < rank($1) }) {
                do { try HealthFixer.apply(fix, layout: vault, home: home) } catch { problems.append(error.localizedDescription) }
            }
            git.commit(message: "Health: \(fixes.count) fix\(fixes.count == 1 ? "" : "es") applied in Embarsy",
                       trailers: ["Source": "Memory → Health", "Approved-by": "user"])
            return problems
        }.value
        // Publishing goes last and once: a skill brought into the base, or a copy chosen to
        // keep, reaches the agents through it, and the copies it replaces are taken over.
        let publishing = fixes.contains {
            switch $0 {
            case .publish, .adoptSkill, .keepCopy, .setSkillName, .setDescription: return true
            default: return false
            }
        }
        if publishing, let publisher {
            var takeover = MemoryPublisher.Takeover()
            for fix in fixes {
                switch fix {
                case .adoptSkill(let from, _, true): takeover.skillFolders.insert(from.path)
                case .keepCopy(_, _, let others, _):
                    let base = vault.root.resolvingSymlinksInPath().path + "/"
                    for other in others where !other.resolvingSymlinksInPath().path.hasPrefix(base) { takeover.skillFolders.insert(other.path) }
                default: break
                }
            }
            let agents = manifest.agents
            // The folders a fix replaces aren't always where publishing links skills (Zoo /
            // Roo's own ~/.roo/skills, for one): replace those explicitly, journaled like
            // every other step, so Undo setup puts them back.
            var replacements: [(URL, URL, String)] = []
            for fix in fixes {
                switch fix {
                case .adoptSkill(let from, let name, true):
                    replacements.append((from, vault.adoptedSkills.appendingPathComponent(name), name))
                case .keepCopy(let skill, _, let others, let baseFolder):
                    let base = vault.root.resolvingSymlinksInPath().path + "/"
                    for other in others where !other.resolvingSymlinksInPath().path.hasPrefix(base) {
                        replacements.append((other, baseFolder, skill))
                    }
                default: break
                }
            }
            let outcome = await Task.detached { () -> MemoryPublisher.Outcome in
                var steps = publisher.plan(agents: agents, takeover: takeover)
                let planned = Set(steps.map(\.path.path))
                for (path, target, name) in replacements where !planned.contains(path.path) && !publisher.isLink(path, to: target) {
                    steps.append(MemoryPublisher.Step(path: path, action: .replaceWithLink(to: target), agents: [], what: L("Skill \(name)")))
                }
                return publisher.apply(steps)
            }.value
            report(outcome, agents: agents)
            if !outcome.failures.isEmpty { await rescan(); return }
        }
        reindex?()
        if problems.isEmpty {
            lastError = nil
            lastNotice = L("Fixed. Earlier versions of the edited notes stay in the base's history; moved copies are in Embarsy's backups.")
        } else {
            lastError = problems.joined(separator: "\n")
        }
        await rescan()
    }

    /// After the person re-checked a note against reality: stamps today's date as verified.
    func markVerified(_ note: URL) async {
        guard let vault else { return }
        await Task.detached {
            let git = MemoryGit(root: vault.root)
            git.commitExternalChanges()
            guard var text = try? String(contentsOf: note, encoding: .utf8), text.hasPrefix("---\n") else { return }
            let date = ISO8601DateFormatter.dateOnly.string(from: Date())
            if let range = text.range(of: #"(?m)^verified_at: .*$"#, options: .regularExpression) {
                text.replaceSubrange(range, with: "verified_at: \(date)")
            } else if let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
                text.insert(contentsOf: "\nverified_at: \(date)", at: end.lowerBound)
            }
            try? text.write(to: note, atomically: true, encoding: .utf8)
            git.commit(message: "Knowledge: \(note.lastPathComponent) verified",
                       trailers: ["Source": "Memory → Knowledge", "Approved-by": "user"])
        }.value
        reindex?()
        await rescan()
    }

    // MARK: Migration

    func migrationSources() -> [MigrationSource] {
        MigrationSources.detect(home: home)
    }

    /// Scans the chosen sources into a fresh staging folder and writes the agent's task.
    func startMigration(at root: URL, sources: [MigrationSource], agents: [MemoryAgent]) async -> Bool {
        if let problem = VaultCreator.validate(root) {
            lastError = problem.errorDescription
            return false
        }
        isWorking = true
        defer { isWorking = false }
        let staging = MigrationStaging(root: MigrationStaging.folder(home: home)
            .appendingPathComponent(MemoryPublisher.stamp(Date())))
        let state = MigrationState(vaultPath: root.standardizedFileURL.path, sources: sources,
                                   createdAt: Date(), agents: agents.map(\.rawValue))
        let home = self.home
        let result: Result<MigrationInventory, Error> = await Task.detached {
            do {
                try FileManager.default.createDirectory(at: staging.root, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                try encoder.encode(state).write(to: staging.state, options: .atomic)
                return .success(try MigrationScanner.prepare(state: state, staging: staging, home: home))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .failure(let error):
            lastError = L("Couldn't scan: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: staging.root)
            return false
        case .success(let inventory):
            lastError = nil
            migration = MigrationSession(staging: staging, state: state, inventory: inventory)
            writePointer(vault)
            for agent in agents { connectTools?(agent) }
            return true
        }
    }

    /// Picks up a migration left open when the app quit.
    private func resumeMigration() {
        let folder = MigrationStaging.folder(home: home)
        let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().reversed()
        for name in candidates {
            let staging = MigrationStaging(root: folder.appendingPathComponent(name))
            guard let stateData = try? Data(contentsOf: staging.state),
                  let state = try? JSONDecoder().decode(MigrationState.self, from: stateData),
                  let invData = try? Data(contentsOf: staging.inventory),
                  let inventory = try? JSONDecoder().decode(MigrationInventory.self, from: invData),
                  !FileManager.default.fileExists(atPath: staging.root.appendingPathComponent("applied").path)
            else { continue }
            migration = MigrationSession(staging: staging, state: state, inventory: inventory)
            checkForPlan()
            writePointer(nil)
            return
        }
    }

    /// Looks for the agent's plan. Cheap enough to call every few seconds while waiting.
    func checkForPlan() {
        guard var session = migration, FileManager.default.fileExists(atPath: session.staging.plan.path) else { return }
        let modified = (try? session.staging.plan.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != session.planModified else { return }
        session.planModified = modified
        do {
            session.plan = try MigrationPlan.load(session.staging.plan)
            session.planError = nil
        } catch {
            session.plan = nil
            session.planError = L("The plan file isn't in the expected format: \(error.localizedDescription). Ask the agent to check it against the format in the task.")
        }
        migration = session
    }

    /// Has the local model write the migration plan the agent would have written. It lands in
    /// the same file, so the review is the same; an agent's plan written later replaces it.
    func planMigrationLocally() {
        guard let session = migration, let model = localModel, localPlanTask == nil else { return }
        lastError = nil
        localPlanProgress = LocalPlanProgress(done: 0, total: 1, what: L("Starting the local model…"))
        localPlanTask = Task { [weak self] in
            var planner = LocalMigrationPlanner(session: session) { system, user, schema, think, numCtx in
                try await model.ask(system: system, user: user, schema: schema, think: think, numCtx: numCtx)
            }
            planner.progress = { done, total, what in
                self?.localPlanProgress = LocalPlanProgress(done: done, total: total, what: what)
            }
            do {
                let plan = try await planner.plan()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(plan).write(to: session.staging.plan, options: .atomic)
                self?.checkForPlan()
            } catch is CancellationError {
            } catch {
                self?.lastError = L("The local model couldn't finish the plan: \(error.localizedDescription)")
            }
            self?.localPlanProgress = nil
            self?.localPlanTask = nil
        }
    }

    func stopLocalPlan() {
        localPlanTask?.cancel()
    }

    // MARK: Health assistant

    /// A Memory tab a finding asked to open (the Inbox, Knowledge); MemoryView follows it.
    @Published var requestedTab: MemoryTab?
    /// The assistant's drafts, by finding id.
    @Published private(set) var assistStates: [String: AssistState] = [:]

    /// Asks the local model for a draft for one finding. Nothing is applied here.
    func assist(_ finding: HealthFinding) {
        guard let kind = finding.assist, let model = localModel, assistStates[finding.id] != .working else { return }
        assistStates[finding.id] = .working
        let vault = self.vault
        let profile = self.profile
        Task { [weak self] in
            let ask: HealthAssistant.Ask = { system, user, schema, numCtx in
                try await model.ask(system: system, user: user, schema: schema, numCtx: numCtx)
            }
            do {
                let result: AssistResult
                switch kind {
                case .shortenCore:
                    guard let vault else { return }
                    result = try await HealthAssistant.shortenCore(profile, vault: vault, ask: ask)
                case .shortenDescription(let file, let skill):
                    result = try await HealthAssistant.shortenDescription(file: file, skill: skill, ask: ask)
                case .compareCopies(let skill, let copies):
                    result = try await HealthAssistant.compareCopies(skill: skill, copies: copies, vault: vault, ask: ask)
                case .suggestNames(let skill, let file):
                    result = try await HealthAssistant.suggestNames(skill: skill, file: file, ask: ask)
                }
                self?.assistStates[finding.id] = .done(result)
            } catch {
                self?.assistStates[finding.id] = .failed(error.localizedDescription)
            }
        }
    }

    func clearAssist(_ finding: HealthFinding) {
        assistStates[finding.id] = nil
    }

    // MARK: Contradictions (H11)

    /// While the local model checks notes for contradictions.
    @Published private(set) var contradictionProgress: LocalPlanProgress?
    private var contradictionTask: Task<Void, Never>?

    var contradictionsCheckedAt: String? {
        vault.flatMap { ContradictionStore.load($0).checkedAt }
    }

    /// Pairs passages about the same thing and asks the local model about each pair it hasn't
    /// checked before. Verdicts are saved as they come, so a stopped check keeps its progress.
    func checkContradictions() {
        guard let vault, let model = localModel, let config = searchConfig?(), contradictionTask == nil else { return }
        lastError = nil
        contradictionProgress = LocalPlanProgress(done: 0, total: 1, what: L("Reading the index…"))
        contradictionTask = Task { [weak self] in
            defer {
                self?.contradictionProgress = nil
                self?.contradictionTask = nil
            }
            guard let passages = await MemorySearch.allPassages(config: config) else {
                self?.lastError = L("Couldn't read the memory index. Is the stack running?")
                return
            }
            var store = ContradictionStore.load(vault)
            let pairs = Contradictions.candidates(passages)
            let fresh = pairs.filter { store.records[Contradictions.key($0.0, $0.1)] == nil }
            for (n, (a, b, _)) in fresh.enumerated() {
                if Task.isCancelled { break }
                self?.contradictionProgress = LocalPlanProgress(done: n, total: fresh.count, what: "\(a.path) · \(b.path)")
                // A quick pass sorts every pair into yes / unsure / no; yes and unsure are asked
                // again with the model thinking it through. A yes/no quick pass dropped a real
                // conflict on one run and kept it on the next — "unsure" catches those.
                func quotesConflict(_ verdict: Contradictions.Verdict) async -> Bool {
                    // Unanimous: a real conflict got three "yes" out of three every time it was
                    // measured; "not committed" vs "accepted" slipped through two-of-three.
                    for _ in 0..<3 {
                        guard let reply = try? await model.ask(system: Contradictions.verifySystem, user: Contradictions.verifyQuestion(verdict),
                                                               schema: Contradictions.verifySchema, numCtx: 4096),
                              let vote = try? JSONDecoder().decode(Contradictions.Verify.self, from: Data(reply.utf8)) else { return true }
                        if !vote.conflict { return false }
                    }
                    return true
                }
                func askAssistant(think: Bool) async -> Contradictions.Verdict? {
                    guard let reply = try? await model.ask(system: Contradictions.system, user: Contradictions.question(a, b),
                                                           schema: Contradictions.schema, think: think, numCtx: think ? 16384 : 8192) else { return nil }
                    return try? JSONDecoder().decode(Contradictions.Verdict.self, from: Data(reply.utf8))
                }
                guard let screenReply = try? await model.ask(system: Contradictions.screenSystem, user: Contradictions.question(a, b),
                                                             schema: Contradictions.screenSchema, numCtx: 8192),
                      let screen = try? JSONDecoder().decode(Contradictions.Screen.self, from: Data(screenReply.utf8)) else { continue }
                var verdict = Contradictions.Verdict(contradiction: screen.answer != "no", a_says: "", b_says: "", explanation: "")
                if verdict.contradiction {
                    self?.contradictionProgress = LocalPlanProgress(done: n, total: fresh.count, what: L("Double-checking \(a.path) · \(b.path)"))
                    guard let second = await askAssistant(think: true) else { continue }
                    verdict = second
                    // The person decides on two quotes, so they must be quotes: a paraphrase is
                    // asked once more. If it's still one, the verdict stands — the passages and
                    // the explanation are shown either way.
                    if verdict.contradiction,
                       !(Contradictions.isQuoted(verdict.a_says, in: a.text) && Contradictions.isQuoted(verdict.b_says, in: b.text)),
                       let third = await askAssistant(think: true), third.contradiction,
                       Contradictions.isQuoted(third.a_says, in: a.text), Contradictions.isQuoted(third.b_says, in: b.text) {
                        verdict = third
                    }
                    // The two quotes alone must still conflict. If they don't, the assistant
                    // pinned the wrong sentences — the real conflict may sit next to them, so it
                    // gets one more look before the pair counts as agreeing.
                    if verdict.contradiction, await !quotesConflict(verdict) {
                        if let again = await askAssistant(think: true), again.contradiction, await quotesConflict(again) {
                            verdict = again
                        } else {
                            verdict = Contradictions.Verdict(contradiction: false, a_says: "", b_says: "", explanation: "")
                        }
                    }
                }
                let key = Contradictions.key(a, b)
                store.records[key] = ContradictionRecord(
                    key: key, aPath: a.path, bPath: b.path, aText: String(a.text.prefix(4000)), bText: String(b.text.prefix(4000)),
                    contradiction: verdict.contradiction, aSays: verdict.a_says, bSays: verdict.b_says,
                    explanation: verdict.explanation, status: .open,
                    checkedAt: ISO8601DateFormatter.dateOnly.string(from: Date()))
                try? store.save(vault)
            }
            if !Task.isCancelled {
                store.checkedAt = ISO8601DateFormatter().string(from: Date())
                try? store.save(vault)
            }
            let open = Contradictions.findings(vault).count
            self?.lastNotice = open == 0
                ? L("No notes disagree.")
                : L("\(open) places where notes disagree — see below.")
            await self?.rescan()
        }
    }

    func stopContradictions() {
        contradictionTask?.cancel()
    }

    /// The person's verdict: which note is right (the other gets a correction under the
    /// passage), or that they don't actually disagree.
    func resolveContradiction(_ record: ContradictionRecord, rightIsA: Bool?) async {
        guard let vault else { return }
        let problem: String? = await Task.detached {
            let git = MemoryGit(root: vault.root)
            git.commitExternalChanges()
            var store = ContradictionStore.load(vault)
            var updated = record
            if let rightIsA {
                do { try Contradictions.markOutdated(record, rightIsA: rightIsA, vault: vault) } catch { return error.localizedDescription }
                updated.status = .resolved
            } else {
                updated.status = .dismissed
            }
            store.records[record.key] = updated
            try? store.save(vault)
            let wrong = rightIsA.map { $0 ? record.bPath : record.aPath }
            git.commit(message: wrong.map { "Health: \($0) marked outdated" } ?? "Health: \(record.aPath) and \(record.bPath) don't disagree",
                       trailers: ["Source": "Memory → Health", "Approved-by": "user"])
            return nil
        }.value
        lastError = problem
        if rightIsA != nil { reindex?() }
        await rescan()
    }

    func cancelMigration() {
        guard let session = migration else { return }
        try? FileManager.default.removeItem(at: session.staging.root)
        migration = nil
        writePointer(vault)
    }

    /// Creates the base from the reviewed plan and connects agents to it, replacing the old
    /// copies it took over (they go to the backups, and Undo setup brings them back).
    func applyMigration(selection: MigrationSelection, clearSkippedCopies: Bool) async {
        guard let session = migration, let plan = session.plan else { return }
        isWorking = true
        defer { isWorking = false }
        let home = self.home
        let agents = session.state.agents.compactMap(MemoryAgent.init(rawValue:))
        let result: Result<(MigrationApplier.Result, MemoryPublisher.Outcome), Error> = await Task.detached {
            do {
                let applied = try MigrationApplier.apply(plan: plan, selection: selection, state: session.state,
                                                         staging: session.staging, home: home)
                let publisher = MemoryPublisher(layout: applied.layout, home: home)
                let takeover = Self.takeover(plan: plan, selection: selection, session: session, home: home,
                                             clearSkipped: clearSkippedCopies)
                let outcome = publisher.apply(publisher.plan(agents: agents, takeover: takeover))
                try? "applied \(Date())\n".write(to: session.staging.root.appendingPathComponent("applied"), atomically: true, encoding: .utf8)
                return .success((applied, outcome))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .failure(let error):
            lastError = error.localizedDescription
        case .success(let (applied, outcome)):
            migration = nil
            defaults.set(applied.layout.root.path, forKey: Self.vaultPathKey)
            loadVault(at: applied.layout.root)
            for agent in agents { connectTools?(agent) }
            reindex?()
            report(outcome, agents: agents)
            if !applied.failures.isEmpty {
                lastError = L("Brought over \(applied.skills) skills and \(applied.notes) notes. Not brought over:\n\(applied.failures.joined(separator: "\n"))")
            } else if lastError == nil {
                lastNotice = L("Brought over \(applied.skills) skills and \(applied.notes) notes. A backup of every source is in \(MemoryScanner.tilde(applied.backup)). Restart your agents so they load the new memory.")
            }
        }
        await rescan()
    }

    /// The four folders agents load skills from.
    nonisolated static func agentSkillFolders(home: URL) -> [String] {
        [".agents/skills", ".claude/skills", ".codex/skills", ".roo/skills"].map { home.appendingPathComponent($0).path }
    }

    /// What the migration took over, so publishing replaces it instead of stepping around it.
    nonisolated static func takeover(plan: MigrationPlan, selection: MigrationSelection, session: MigrationSession,
                                     home: URL, clearSkipped: Bool) -> MemoryPublisher.Takeover {
        let fm = FileManager.default
        var t = MemoryPublisher.Takeover()
        let folders = agentSkillFolders(home: home)
        let shared = home.appendingPathComponent(".agents/skills").path
        let claude = home.appendingPathComponent(".claude/skills").path
        let inAgentFolder = { (path: String) in folders.contains { URL(fileURLWithPath: path).deletingLastPathComponent().path == $0 } }

        let migrated = (plan.skills ?? []).filter { selection.skills.contains($0.id) }.map(\.name)
        for name in migrated {
            for base in [shared, claude] {
                let path = base + "/" + name
                if fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                    t.skillFolders.insert(path)
                }
            }
            // Any other copy an agent loads — under another folder name, or in Codex's old
            // folder, or in ~/.roo/skills which Zoo / Roo prefers — would compete with the base's.
            for copy in session.inventory.skills.first(where: { $0.name == name })?.copies ?? [] where inAgentFolder(copy.path) {
                let link = copy.path == shared + "/" + name || copy.path == claude + "/" + name
                if !link { t.moveAside.insert(copy.path) }
            }
        }
        if selection.useCore {
            for source in plan.core?.sources ?? [] where session.state.sources.contains(where: { $0.kind == .instructions && (source == $0.path || source.hasPrefix($0.path + "/")) }) {
                t.instructionFiles.insert(source)
            }
        }
        if clearSkipped {
            for skip in plan.skip ?? [] where inAgentFolder(skip.source) {
                t.moveAside.insert(skip.source)
            }
        }
        // Links in ~/.roo/skills pointing at anything that is about to move would dangle.
        let roo = home.appendingPathComponent(".roo/skills")
        let moving = t.moveAside.union(t.skillFolders)
        for name in (try? fm.contentsOfDirectory(atPath: roo.path)) ?? [] {
            let path = roo.appendingPathComponent(name).path
            if let dest = try? fm.destinationOfSymbolicLink(atPath: path), moving.contains(dest) {
                t.moveAside.insert(path)
            }
        }
        return t
    }

    // MARK: Inbox

    func suggestedDestination(for item: InboxItem) -> InboxDestination {
        guard let vault else { return .note(path: "knowledge/note.md") }
        return MemoryInbox(layout: vault).suggestedDestination(for: item)
    }

    func defaultDestination(type: String, title: String) -> InboxDestination {
        guard let vault else { return .note(path: "knowledge/note.md") }
        return MemoryInbox(layout: vault).defaultDestination(type: type, title: title)
    }

    /// What earlier decisions on proposals like this one suggest.
    func decisionHint(for item: InboxItem) async -> DecisionHint? {
        guard let vault, let config = searchConfig?() else { return nil }
        return await MemoryDecisions.hint(for: item, layout: vault, config: config)
    }

    func similarNotes(to item: InboxItem) async -> [SimilarNote] {
        guard let config = searchConfig?() else { return [] }
        return await MemorySearch.similar(to: item.title + "\n" + item.text, config: config)
    }

    func accept(_ item: InboxItem, to destination: InboxDestination) async {
        guard let vault else { return }
        let profile = self.profile
        let home = self.home
        let result: Result<CoreProfile?, Error> = await Task.detached {
            let git = MemoryGit(root: vault.root)
            git.commitExternalChanges()
            do {
                let updated = try MemoryInbox(layout: vault).accept(item, to: destination, profile: profile, home: home)
                git.commit(message: "Inbox: accepted \"\(item.title)\" into \(destination.label)",
                           trailers: ["Agent": item.agent, "Source": "inbox/\(item.agent)/\(item.url.lastPathComponent)", "Approved-by": "user"])
                return .success(updated)
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let updated):
            if let updated { self.profile = updated }
            lastError = nil
            reindex?()
        case .failure(let error):
            lastError = error.localizedDescription
        }
        await rescan()
    }

    func reject(_ item: InboxItem) async {
        guard let vault else { return }
        let error: String? = await Task.detached {
            let git = MemoryGit(root: vault.root)
            git.commitExternalChanges()
            do {
                try MemoryInbox(layout: vault).reject(item)
            } catch {
                return error.localizedDescription
            }
            git.commit(message: "Inbox: rejected \"\(item.title)\"",
                       trailers: ["Agent": item.agent, "Source": "inbox/\(item.agent)/\(item.url.lastPathComponent)", "Approved-by": "user"])
            return nil
        }.value
        lastError = error
        await rescan()
    }

    private func report(_ outcome: MemoryPublisher.Outcome, agents: [MemoryAgent]) {
        if outcome.failures.isEmpty {
            lastError = nil
            let names = MemoryAgent.allCases.filter(agents.contains).map(\.label).joined(separator: ", ")
            lastNotice = outcome.applied == 0 ? nil
                : L("Connected. Restart \(names) so they load the new memory.")
        } else {
            lastError = outcome.failures.map { "\($0.0.what) (\(MemoryScanner.tilde($0.0.path))): \($0.1)" }
                .joined(separator: "\n")
        }
    }
}
