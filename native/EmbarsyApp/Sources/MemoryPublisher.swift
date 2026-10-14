import Foundation

/// Puts the memory base where each agent looks (docs/memory-spec.md §6.1–6.2), and takes it
/// back out again.
///
/// Three rules hold everywhere here:
/// - Embarsy only touches what it created. Every link and line it adds is recorded in the
///   base's .embarsy/exposure.json; undo removes exactly those, and only while they are
///   still what Embarsy left there.
/// - A real folder or a file with content that is already in the way is left alone; the
///   plan says why instead.
/// - Before a file is replaced, a copy goes to Embarsy's backups.
struct MemoryPublisher {
    let layout: VaultLayout
    let home: URL
    private var fm: FileManager { .default }

    init(layout: VaultLayout, home: URL) {
        self.layout = layout
        self.home = home
    }

    // MARK: Locations

    var codexAgentsMd: URL { home.appendingPathComponent(".codex/AGENTS.md") }
    var codexOverride: URL { home.appendingPathComponent(".codex/AGENTS.override.md") }
    var claudeMd: URL { home.appendingPathComponent(".claude/CLAUDE.md") }
    var rooRule: URL { home.appendingPathComponent(".roo/rules/00-embarsy-memory.md") }
    var sharedSkills: URL { home.appendingPathComponent(".agents/skills") }
    var claudeSkills: URL { home.appendingPathComponent(".claude/skills") }
    var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    var claudeInbox: URL { layout.inbox.appendingPathComponent("claude") }
    var backupsRoot: URL { home.appendingPathComponent("Library/Application Support/Embarsy/memory-backups") }

    static let blockStart = "<!-- embarsy:memory:start -->"
    static let blockEnd = "<!-- embarsy:memory:end -->"

    var claudeBlock: String {
        "\(Self.blockStart)\n@\(layout.agentsMd.path.replacingOccurrences(of: layout.root.path, with: layout.displayPath(home: home)))\n\(Self.blockEnd)\n"
    }

    // MARK: Plan

    struct Step: Identifiable, Hashable {
        enum Action: Hashable {
            case link(to: URL)
            case replaceEmptyWithLink(to: URL)
            case appendBlock(String)
            case editJSON(JSONEdit)
            /// What is there (an old copy of a skill, migrated instructions) goes to the
            /// backups; a link to the base takes its place.
            case replaceWithLink(to: URL)
            /// The file's old content goes to the backups; it is rewritten to just this.
            case replaceContent(String)
            /// Moved into the backups, nothing put in its place.
            case moveAside
            case removeLink
            case alreadyDone
            case skip(String)
        }

        let path: URL
        let action: Action
        let agents: [MemoryAgent]
        let what: String

        var id: String { path.path + "|" + what }

        var changesSomething: Bool {
            switch action {
            case .link, .replaceEmptyWithLink, .appendBlock, .editJSON, .removeLink,
                 .replaceWithLink, .replaceContent, .moveAside: return true
            case .alreadyDone, .skip: return false
            }
        }
    }

    /// What a migration took over, and so may be replaced rather than left alone.
    struct Takeover: Equatable {
        /// Skill folders in agents' folders whose skill now lives in the base.
        var skillFolders: Set<String> = []
        /// Instruction files whose content went into the core.
        var instructionFiles: Set<String> = []
        /// Old copies in agents' folders the user chose to clear away.
        var moveAside: Set<String> = []
    }

    /// What publishing would do right now. Reads only.
    func plan(agents: [MemoryAgent], takeover: Takeover = Takeover()) -> [Step] {
        var steps: [Step] = []
        let selected = Set(agents)

        // Core instructions.
        if selected.contains(.codex) {
            if let override = textFile(codexOverride), !override.trimmed.isEmpty {
                steps.append(Step(path: codexOverride, action: .skip(L("Codex reads AGENTS.override.md instead of AGENTS.md, so your core would be ignored. Empty or remove it, then publish again.")),
                                  agents: [.codex], what: L("Core instructions for Codex")))
            } else if takeover.instructionFiles.contains(codexAgentsMd.path), !isLink(codexAgentsMd, to: layout.agentsMd),
                      fm.fileExists(atPath: codexAgentsMd.path), !isEmptyFile(codexAgentsMd) {
                steps.append(Step(path: codexAgentsMd, action: .replaceWithLink(to: layout.agentsMd), agents: [.codex],
                                  what: L("Core instructions for Codex")))
            } else {
                steps.append(linkStep(at: codexAgentsMd, to: layout.agentsMd, agents: [.codex],
                                      what: L("Core instructions for Codex"), allowReplacingEmpty: true,
                                      occupied: L("It already has your own instructions. Embarsy leaves them as they are; you'll be able to bring them into the base with \"Bring existing memory\".")))
            }
        }
        if selected.contains(.claude) {
            let text = textFile(claudeMd) ?? ""
            let action: Step.Action
            if text.contains(claudeBlock) {
                action = .alreadyDone
            } else if takeover.instructionFiles.contains(claudeMd.path), !text.trimmed.isEmpty {
                action = .replaceContent(claudeBlock)
            } else if text.contains(Self.blockStart) {
                action = .skip(L("It already imports a memory base from somewhere else. Remove the lines between the embarsy:memory markers, then publish again."))
            } else {
                action = .appendBlock(claudeBlock)
            }
            steps.append(Step(path: claudeMd, action: action, agents: [.claude], what: L("Core instructions for Claude Code")))
            steps += claudeSettingsSteps()
        }
        if selected.contains(.zoo) {
            // Rules that went into the core would otherwise load twice.
            for path in takeover.instructionFiles.sorted() where path.hasPrefix(rooRule.deletingLastPathComponent().path + "/") && path != rooRule.path {
                if fm.fileExists(atPath: path) {
                    steps.append(Step(path: URL(fileURLWithPath: path), action: .moveAside, agents: [.zoo],
                                      what: L("Old Zoo / Roo rule, now in the core")))
                }
            }
            steps.append(linkStep(at: rooRule, to: layout.agentsMd, agents: [.zoo],
                                  what: L("Core instructions for Zoo / Roo"), allowReplacingEmpty: false,
                                  occupied: L("A file with this name is already there.")))
        }

        // Skills. Codex and Zoo / Roo share one folder, so one link serves both.
        for skill in vaultSkills() {
            let wanted = skill.agents.isEmpty ? selected : selected.intersection(skill.agents)
            if let problem = skill.problem {
                steps.append(Step(path: skill.url, action: .skip(problem), agents: MemoryAgent.allCases.filter(wanted.contains), what: L("Skill \(skill.name)")))
                continue
            }
            let shared = MemoryAgent.allCases.filter { [.codex, .zoo].contains($0) && wanted.contains($0) }
            if !shared.isEmpty {
                steps.append(skillStep(at: sharedSkills.appendingPathComponent(skill.name), skill: skill, agents: shared, takeover: takeover))
            }
            if wanted.contains(.claude) {
                steps.append(skillStep(at: claudeSkills.appendingPathComponent(skill.name), skill: skill, agents: [.claude], takeover: takeover))
            }
        }

        // Old copies the user chose to clear from agents' folders.
        for path in takeover.moveAside.sorted() where !steps.contains(where: { $0.path.path == path }) {
            guard fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil else { continue }
            steps.append(Step(path: URL(fileURLWithPath: path), action: .moveAside, agents: [],
                              what: L("Old copy \(URL(fileURLWithPath: path).lastPathComponent)")))
        }

        // Links Embarsy made earlier whose skill has since left the base.
        let planned = Set(steps.map(\.path.path))
        for record in loadJournal().records where record.kind == .link {
            let path = URL(fileURLWithPath: record.path)
            guard !planned.contains(path.path), let target = record.target,
                  !fm.fileExists(atPath: target), isLink(path, to: URL(fileURLWithPath: target)) else { continue }
            steps.append(Step(path: path, action: .removeLink, agents: [], what: L("Skill \(path.lastPathComponent) is no longer in the base")))
        }
        return steps
    }

    // MARK: Claude Code settings

    /// A change to one key of a JSON settings file, made so that it can be taken back exactly.
    struct JSONEdit: Hashable {
        enum Mode: String, Codable, Hashable {
            /// Set the key to the value.
            case set
            /// Add the value to the array at the key, once.
            case addToArray
        }
        let keyPath: [String]
        let value: String
        let mode: Mode
    }

    /// Claude Code's own memory goes to the base's inbox, and it may read the base without
    /// asking each time (docs/memory-spec.md §6.3–6.4).
    func claudeSettingsSteps() -> [Step] {
        let settings = readJSON(claudeSettings)
        var steps: [Step] = []

        let memoryEdit = JSONEdit(keyPath: ["autoMemoryDirectory"], value: claudeInbox.path, mode: .set)
        let memoryAction: Step.Action
        switch settings {
        case .unreadable:
            memoryAction = .skip(L("It isn't valid JSON, so Embarsy can't change it safely."))
        case .object(let json):
            if let current = json["autoMemoryDirectory"] as? String {
                memoryAction = current == memoryEdit.value ? .alreadyDone
                    : .skip(L("Claude Code already keeps its memory in \(current). Embarsy leaves that alone; clear it to have Claude's memory go to the inbox."))
            } else {
                memoryAction = .editJSON(memoryEdit)
            }
        }
        steps.append(Step(path: claudeSettings, action: memoryAction, agents: [.claude], what: L("Claude Code's memory goes to the inbox")))

        let readEdit = JSONEdit(keyPath: ["permissions", "additionalDirectories"], value: layout.root.path, mode: .addToArray)
        let readAction: Step.Action
        switch settings {
        case .unreadable:
            readAction = .skip(L("It isn't valid JSON, so Embarsy can't change it safely."))
        case .object(let json):
            let list = (json["permissions"] as? [String: Any])?["additionalDirectories"] as? [String] ?? []
            readAction = list.contains(readEdit.value) ? .alreadyDone : .editJSON(readEdit)
        }
        steps.append(Step(path: claudeSettings, action: readAction, agents: [.claude], what: L("Claude Code may read the memory base")))
        return steps
    }

    enum JSONFile {
        case object([String: Any])
        case unreadable
    }

    func readJSON(_ url: URL) -> JSONFile {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return .object([:]) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        return .object(json)
    }

    private func writeJSON(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (String(decoding: data, as: UTF8.self) + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Applies one edit; returns the key's previous value as JSON text (nil if it was absent).
    private func applyJSONEdit(_ edit: JSONEdit, to url: URL) throws -> String? {
        guard case .object(var json) = readJSON(url) else { throw CocoaError(.fileReadCorruptFile) }
        let previous = Self.value(at: edit.keyPath, in: json).flatMap(Self.jsonText)
        switch edit.mode {
        case .set:
            json = Self.setting(edit.value, at: edit.keyPath, in: json)
        case .addToArray:
            var list = Self.value(at: edit.keyPath, in: json) as? [Any] ?? []
            if !list.contains(where: { ($0 as? String) == edit.value }) { list.append(edit.value) }
            json = Self.setting(list, at: edit.keyPath, in: json)
        }
        try writeJSON(json, to: url)
        return previous
    }

    /// Takes one edit back, but only while the key still holds what Embarsy put there.
    private func undoJSONEdit(_ edit: JSONEdit, previous: String?, at url: URL) throws -> Bool {
        guard case .object(var json) = readJSON(url) else { return false }
        switch edit.mode {
        case .set:
            guard (Self.value(at: edit.keyPath, in: json) as? String) == edit.value else { return false }
            if let previous, let restored = Self.parseJSONText(previous) {
                json = Self.setting(restored, at: edit.keyPath, in: json)
            } else {
                json = Self.setting(nil, at: edit.keyPath, in: json)
            }
        case .addToArray:
            var list = Self.value(at: edit.keyPath, in: json) as? [Any] ?? []
            guard list.contains(where: { ($0 as? String) == edit.value }) else { return true }
            list.removeAll { ($0 as? String) == edit.value }
            json = Self.setting(list.isEmpty && previous == nil ? nil : list, at: edit.keyPath, in: json)
        }
        try writeJSON(json, to: url)
        return true
    }

    static func value(at keyPath: [String], in json: [String: Any]) -> Any? {
        var current: Any? = json
        for key in keyPath { current = (current as? [String: Any])?[key] }
        return current
    }

    /// Sets (or, with nil, removes) a nested key; parents left empty by a removal go too.
    static func setting(_ value: Any?, at keyPath: [String], in json: [String: Any]) -> [String: Any] {
        guard let key = keyPath.first else { return json }
        var out = json
        if keyPath.count == 1 {
            out[key] = value
        } else {
            let child = out[key] as? [String: Any] ?? [:]
            let updated = setting(value, at: Array(keyPath.dropFirst()), in: child)
            out[key] = updated.isEmpty && value == nil ? nil : updated
        }
        return out
    }

    static func jsonText(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseJSONText(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private func skillStep(at path: URL, skill: VaultSkill, agents: [MemoryAgent], takeover: Takeover) -> Step {
        let exists = fm.fileExists(atPath: path.path) || (try? fm.destinationOfSymbolicLink(atPath: path.path)) != nil
        if exists, !isLink(path, to: skill.url), takeover.skillFolders.contains(path.path) {
            return Step(path: path, action: .replaceWithLink(to: skill.url), agents: agents, what: L("Skill \(skill.name)"))
        }
        return linkStep(at: path, to: skill.url, agents: agents, what: L("Skill \(skill.name)"), allowReplacingEmpty: false,
                        occupied: L("A different skill with this name is already in this folder. Embarsy leaves it alone."))
    }

    private func linkStep(at path: URL, to target: URL, agents: [MemoryAgent], what: String,
                          allowReplacingEmpty: Bool, occupied: String) -> Step {
        let action: Step.Action
        if isLink(path, to: target) {
            action = .alreadyDone
        } else if let destination = try? fm.destinationOfSymbolicLink(atPath: path.path) {
            action = .skip(L("It's already a link to \(tilde(URL(fileURLWithPath: destination))). Embarsy leaves it alone."))
        } else if fm.fileExists(atPath: path.path) {
            if allowReplacingEmpty, isEmptyFile(path) {
                action = .replaceEmptyWithLink(to: target)
            } else {
                action = .skip(occupied)
            }
        } else {
            action = .link(to: target)
        }
        return Step(path: path, action: action, agents: agents, what: what)
    }

    struct VaultSkill {
        let name: String
        let url: URL
        let agents: Set<MemoryAgent>
        let problem: String?
    }

    /// Skills in the base: own/ and adopted/ one level down, vendor/<source>/ two.
    func vaultSkills() -> [VaultSkill] {
        var folders: [URL] = []
        for base in [layout.ownSkills, layout.adoptedSkills] {
            folders += children(of: base)
        }
        for source in children(of: layout.vendorSkills) {
            folders += children(of: source)
        }
        return folders.filter { fm.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
            .map { folder in
                let text = (try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
                let fm = MemoryScanner.parseFrontmatter(text)
                let name = folder.lastPathComponent
                return VaultSkill(name: name, url: folder, agents: fm.embarsyAgents, problem: Self.portabilityProblem(folder: name, frontmatter: fm))
            }
            .sorted { $0.name < $1.name }
    }

    /// The minimum every agent accepts (docs/memory-spec.md §4); nil when the skill passes.
    static func portabilityProblem(folder: String, frontmatter: SkillFrontmatter) -> String? {
        guard frontmatter.hasFrontmatter else { return L("SKILL.md has no frontmatter, so agents can't tell what the skill is for.") }
        guard let name = frontmatter.name, !name.trimmed.isEmpty else { return L("name is missing. Zoo / Roo requires it.") }
        if name != folder { return L("name: \(name) differs from the folder name \(folder). Zoo / Roo would skip it.") }
        if name.count > 64 || name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) == nil {
            return L("name must be lowercase letters, digits and single hyphens, up to 64.")
        }
        let description = frontmatter.description?.trimmed ?? ""
        if description.isEmpty { return L("description is empty; agents pick skills by it.") }
        if description.utf16.count > 1024 { return L("description is over 1024 characters; Zoo / Roo would skip it.") }
        return nil
    }

    // MARK: Apply

    struct Outcome {
        var applied = 0
        var failures: [(Step, String)] = []
    }

    /// Carries out the changing steps of a plan, recording each one as it lands so a
    /// half-finished run can still be undone.
    func apply(_ steps: [Step], now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        var journal = loadJournal()
        let backupFolder = backupsRoot.appendingPathComponent(Self.stamp(now))

        for step in steps where step.changesSomething {
            do {
                switch step.action {
                case .link(let target):
                    try ensureParent(of: step.path, journal: &journal)
                    try fm.createSymbolicLink(at: step.path, withDestinationURL: target)
                    journal.records.append(.init(kind: .link, path: step.path.path, target: target.path))

                case .replaceEmptyWithLink(let target):
                    let backup = try backUp(step.path, into: backupFolder)
                    try fm.removeItem(at: step.path)
                    try fm.createSymbolicLink(at: step.path, withDestinationURL: target)
                    journal.records.append(.init(kind: .link, path: step.path.path, target: target.path, backup: backup.path))

                case .appendBlock(let block):
                    var record = JournalRecord(kind: .block, path: step.path.path, block: block)
                    if fm.fileExists(atPath: step.path.path) {
                        record.backup = try backUp(step.path, into: backupFolder).path
                        let existing = textFile(step.path) ?? ""
                        let separator = existing.isEmpty || existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
                        // The separator is recorded with the block, so undo removes exactly what was added.
                        record.block = separator + block
                        try (existing + separator + block).write(to: step.path, atomically: true, encoding: .utf8)
                    } else {
                        try ensureParent(of: step.path, journal: &journal)
                        try block.write(to: step.path, atomically: true, encoding: .utf8)
                        record.createdFile = true
                    }
                    journal.records.append(record)

                case .editJSON(let edit):
                    var record = JournalRecord(kind: .json, path: step.path.path)
                    if fm.fileExists(atPath: step.path.path) {
                        record.backup = try backUp(step.path, into: backupFolder).path
                    } else {
                        try ensureParent(of: step.path, journal: &journal)
                        record.createdFile = true
                    }
                    record.previous = try applyJSONEdit(edit, to: step.path)
                    record.keyPath = edit.keyPath
                    record.target = edit.value
                    record.mode = edit.mode
                    journal.records.append(record)

                case .replaceWithLink(let target):
                    let aside = try moveAside(step.path, into: backupFolder)
                    try fm.createSymbolicLink(at: step.path, withDestinationURL: target)
                    journal.records.append(.init(kind: .link, path: step.path.path, target: target.path, backup: aside.path, movedAside: true))

                case .replaceContent(let content):
                    let backup = try backUp(step.path, into: backupFolder)
                    try content.write(to: step.path, atomically: true, encoding: .utf8)
                    journal.records.append(.init(kind: .replaced, path: step.path.path, block: content, backup: backup.path))

                case .moveAside:
                    let aside = try moveAside(step.path, into: backupFolder)
                    journal.records.append(.init(kind: .movedAside, path: step.path.path, backup: aside.path))

                case .removeLink:
                    try fm.removeItem(at: step.path)
                    journal.records.removeAll { $0.kind == .link && $0.path == step.path.path }

                case .alreadyDone, .skip:
                    break
                }
                outcome.applied += 1
                try saveJournal(journal)
            } catch {
                outcome.failures.append((step, error.localizedDescription))
            }
        }
        return outcome
    }

    // MARK: Undo

    /// Takes back everything the journal records, newest first, and only where it is still
    /// exactly what Embarsy left. Returns what it couldn't take back.
    @discardableResult
    func undoAll() -> [String] {
        var journal = loadJournal()
        var problems: [String] = []

        for record in journal.records.reversed() {
            let path = URL(fileURLWithPath: record.path)
            do {
                switch record.kind {
                case .link:
                    guard let target = record.target else { break }
                    if isLink(path, to: URL(fileURLWithPath: target)) {
                        try fm.removeItem(at: path)
                        if let backup = record.backup {
                            // What was moved aside goes back itself; what was copied is copied back.
                            if record.movedAside == true {
                                try fm.moveItem(at: URL(fileURLWithPath: backup), to: path)
                            } else {
                                try fm.copyItem(at: URL(fileURLWithPath: backup), to: path)
                            }
                        }
                    } else if fm.fileExists(atPath: path.path) || (try? fm.destinationOfSymbolicLink(atPath: path.path)) != nil {
                        problems.append(L("\(tilde(path)) was changed after Embarsy set it up, so it was left as it is."))
                    }

                case .block:
                    guard let block = record.block, let text = textFile(path) else { break }
                    guard text.contains(block) else {
                        problems.append(L("The lines Embarsy added to \(tilde(path)) were edited, so they were left as they are."))
                        break
                    }
                    let remaining: String
                    if let range = text.range(of: block, options: .backwards) {
                        remaining = text.replacingCharacters(in: range, with: "")
                    } else {
                        remaining = text
                    }
                    if record.createdFile == true, remaining.trimmed.isEmpty {
                        try fm.removeItem(at: path)
                    } else {
                        try remaining.write(to: path, atomically: true, encoding: .utf8)
                    }

                case .json:
                    guard let keyPath = record.keyPath, let value = record.target, let mode = record.mode else { break }
                    let edit = JSONEdit(keyPath: keyPath, value: value, mode: mode)
                    if try !undoJSONEdit(edit, previous: record.previous, at: path) {
                        problems.append(L("\(keyPath.joined(separator: ".")) in \(tilde(path)) was changed after Embarsy set it, so it was left as it is."))
                    } else if record.createdFile == true, case .object(let json) = readJSON(path), json.isEmpty {
                        try fm.removeItem(at: path)
                    }

                case .replaced:
                    guard let content = record.block, let backup = record.backup else { break }
                    if textFile(path) == content {
                        try fm.removeItem(at: path)
                        try fm.copyItem(at: URL(fileURLWithPath: backup), to: path)
                    } else {
                        problems.append(L("\(tilde(path)) was changed after Embarsy rewrote it, so it was left as it is. Its earlier version is in \(tilde(URL(fileURLWithPath: backup)))."))
                    }

                case .movedAside:
                    guard let backup = record.backup else { break }
                    if fm.fileExists(atPath: path.path) || (try? fm.destinationOfSymbolicLink(atPath: path.path)) != nil {
                        problems.append(L("Something new is at \(tilde(path)), so the old copy stays in \(tilde(URL(fileURLWithPath: backup)))."))
                    } else {
                        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: URL(fileURLWithPath: backup), to: path)
                    }

                case .createdDir:
                    let contents = ((try? fm.contentsOfDirectory(atPath: path.path)) ?? []).filter { $0 != ".DS_Store" }
                    if contents.isEmpty, fm.fileExists(atPath: path.path) {
                        try fm.removeItem(at: path)
                    }
                }
            } catch {
                problems.append("\(tilde(path)): \(error.localizedDescription)")
            }
        }
        journal.records.removeAll()
        try? saveJournal(journal)
        return problems
    }

    /// Whether this agent currently gets the core from this base.
    func coreConnected(for agent: MemoryAgent) -> Bool {
        switch agent {
        case .codex: return isLink(codexAgentsMd, to: layout.agentsMd)
        case .claude: return (textFile(claudeMd) ?? "").contains(claudeBlock)
        case .zoo: return isLink(rooRule, to: layout.agentsMd)
        }
    }

    // MARK: Journal

    struct JournalRecord: Codable, Hashable {
        enum Kind: String, Codable { case link, block, json, replaced, movedAside, createdDir }
        var kind: Kind
        var path: String
        var target: String?
        var block: String?
        var backup: String?
        var createdFile: Bool?
        var keyPath: [String]?
        var previous: String?
        var mode: JSONEdit.Mode?
        var movedAside: Bool?
    }

    struct Journal: Codable {
        var version = 1
        var records: [JournalRecord] = []
    }

    func loadJournal() -> Journal {
        guard let data = try? Data(contentsOf: layout.exposureJournal),
              let journal = try? JSONDecoder().decode(Journal.self, from: data) else { return Journal() }
        return journal
    }

    private func saveJournal(_ journal: Journal) throws {
        try fm.createDirectory(at: layout.service, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(journal).write(to: layout.exposureJournal, options: .atomic)
    }

    // MARK: Helpers

    /// Creates missing parent folders, recording each so undo can remove it again if empty.
    private func ensureParent(of path: URL, journal: inout Journal) throws {
        var missing: [URL] = []
        var folder = path.deletingLastPathComponent()
        while !fm.fileExists(atPath: folder.path), folder.path != "/" {
            missing.insert(folder, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        for folder in missing {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            journal.records.append(.init(kind: .createdDir, path: folder.path))
        }
    }

    private func backUp(_ file: URL, into folder: URL) throws -> URL {
        let relative = file.path.hasPrefix(home.path + "/") ? String(file.path.dropFirst(home.path.count + 1)) : String(file.path.dropFirst())
        let destination = folder.appendingPathComponent(relative)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: file, to: destination)
        return destination
    }

    /// Leftover copies no agent reads, moved to the backups and recorded so Undo setup can
    /// put them back. Returns what couldn't be moved.
    func moveAsideLeftovers(_ paths: [URL], now: Date = Date()) -> [String] {
        var journal = loadJournal()
        let folder = backupsRoot.appendingPathComponent(Self.stamp(now) + "-leftovers")
        var problems: [String] = []
        for path in paths {
            do {
                let aside = try moveAside(path, into: folder)
                journal.records.append(.init(kind: .movedAside, path: path.path, backup: aside.path))
            } catch {
                problems.append("\(tilde(path)): \(error.localizedDescription)")
            }
        }
        try? saveJournal(journal)
        return problems
    }

    /// Moves a file, folder or link into the backups, keeping its path below home.
    private func moveAside(_ item: URL, into folder: URL) throws -> URL {
        let relative = item.path.hasPrefix(home.path + "/") ? String(item.path.dropFirst(home.path.count + 1)) : String(item.path.dropFirst())
        let destination = folder.appendingPathComponent("moved-aside").appendingPathComponent(relative)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: item, to: destination)
        return destination
    }

    func isLink(_ path: URL, to target: URL) -> Bool {
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: path.path) else { return false }
        let resolved = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
            : path.deletingLastPathComponent().appendingPathComponent(destination)
        return resolved.standardizedFileURL.path == target.standardizedFileURL.path
    }

    private func isEmptyFile(_ url: URL) -> Bool {
        guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data, as: UTF8.self).trimmed.isEmpty
    }

    private func textFile(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func children(of folder: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { folder.appendingPathComponent($0) }
            .filter { var dir: ObjCBool = false; return fm.fileExists(atPath: $0.path, isDirectory: &dir) && dir.boolValue }
            .sorted { $0.path < $1.path }
    }

    func tilde(_ url: URL) -> String {
        let path = url.path
        return path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: date)
    }
}
