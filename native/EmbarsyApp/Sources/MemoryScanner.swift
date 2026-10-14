import CryptoKit
import Foundation

// Read-only inventory of what each coding agent can actually see: the skill folders Claude
// Code, Codex and Zoo / Roo read, the global instruction files they load, and the problems
// that silently hide a skill from one of them. Nothing here writes to disk.
//
// The discovery rules mirror each agent's own loader (docs/memory-spec.md §4): Claude Code
// and Zoo read one level deep, Codex up to six; Zoo drops a skill whose `name` differs from
// its folder; all three follow symlinked skill folders.

enum MemoryAgent: String, CaseIterable, Identifiable, Hashable {
    case claude, codex, zoo

    /// The same agent as Connections knows it.
    var editorAgent: EditorAgent {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .zoo: return .roo
        }
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .zoo: return "Zoo / Roo"
        }
    }
}

/// One folder that holds skills, and which agents read it.
struct SkillRoot: Identifiable, Hashable {
    enum Kind: Hashable {
        case claudeUser
        case agentsUser
        case agentsMode(String)
        case codexLegacy
        case codexSystem
        case rooUser
        case rooMode(String)
        case zooStaleCopy
        case vault
        case extra
    }

    let url: URL
    let kind: Kind

    var id: String { url.path }

    /// Agents that load skills from this folder, with how deep each one looks.
    var readers: [MemoryAgent: Int] {
        switch kind {
        case .claudeUser: return [.claude: 1]
        case .agentsUser: return [.codex: 6, .zoo: 1]
        case .agentsMode, .rooUser, .rooMode: return [.zoo: 1]
        case .codexLegacy, .codexSystem: return [.codex: 6]
        case .zooStaleCopy, .vault, .extra: return [:]
        }
    }

    /// Only the agent that owns it reads this folder, and its own UI creates skills here.
    var isAgentPrivate: Bool {
        switch kind {
        case .claudeUser, .codexLegacy, .rooUser, .rooMode: return true
        default: return false
        }
    }

    var summary: String {
        switch kind {
        case .claudeUser: return L("Claude Code's own skills folder")
        case .agentsUser: return L("Shared folder — read by Codex and Zoo / Roo")
        case .agentsMode(let mode): return L("Zoo / Roo skills for the \(mode) mode")
        case .codexLegacy: return L("Codex's old skills folder — still read, but deprecated")
        case .codexSystem: return L("Skills bundled with Codex")
        case .rooUser: return L("Zoo / Roo's own skills folder")
        case .rooMode(let mode): return L("Zoo / Roo skills for the \(mode) mode")
        case .zooStaleCopy: return L("Copies left in Zoo's settings — Zoo doesn't read this folder")
        case .vault: return L("Your memory base — agents get these skills through links Embarsy publishes")
        case .extra: return L("Added by you — no agent reads this folder")
        }
    }
}

/// The handful of SKILL.md frontmatter fields the agents care about.
struct SkillFrontmatter: Hashable {
    var hasFrontmatter = false
    var name: String?
    var description: String?
    var author: String?
    /// `metadata.embarsy-agents`: which agents a skill in the memory base is published to.
    /// Empty means every connected agent.
    var embarsyAgents: Set<MemoryAgent> = []
    /// Top-level fields whose unquoted value a strict YAML parser rejects (an inner ": ", a
    /// trailing ":", a leading YAML indicator). Claude Code reads such a file anyway; Codex
    /// and Zoo / Roo parse strictly and drop the whole skill.
    var strictYAMLKeys: [String] = []
}

enum SkillVisibility: Hashable {
    case visible(note: String?)
    case rejected(reason: String)
    case absent

    var isVisible: Bool { if case .visible = self { return true } else { return false } }
    var isRejected: Bool { if case .rejected = self { return true } else { return false } }
}

/// A SKILL.md found on disk, as reached through one root.
struct SkillEntry: Identifiable, Hashable {
    let root: SkillRoot
    /// The folder as found under the root, symlinks NOT resolved.
    let url: URL
    /// Where it really lives.
    let resolvedURL: URL
    let depth: Int
    let isSymlink: Bool
    let frontmatter: SkillFrontmatter
    let contentHash: String
    let modified: Date?

    var id: String { url.path }
    var folderName: String { url.lastPathComponent }
    var identity: String { frontmatter.name?.nilIfBlank ?? folderName }

    func visibility(for agent: MemoryAgent) -> SkillVisibility {
        guard let maxDepth = root.readers[agent] else { return .absent }
        let fm = frontmatter
        let description = fm.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch agent {
        case .claude:
            if depth > maxDepth {
                return .rejected(reason: L("Nested \(depth) folders deep. Claude Code only looks one level into its skills folder."))
            }
            if !fm.hasFrontmatter {
                return .rejected(reason: L("SKILL.md has no frontmatter, so there is no description to choose the skill by."))
            }
            if let name = fm.name, !name.isEmpty, name != folderName {
                return .visible(note: L("Invoked as /\(folderName) — Claude Code uses the folder name, not name: \(name)."))
            }
            return .visible(note: nil)

        case .codex:
            if depth > maxDepth {
                return .rejected(reason: L("Nested \(depth) folders deep. Codex stops at 6."))
            }
            if !fm.hasFrontmatter {
                return .rejected(reason: L("SKILL.md has no frontmatter. Codex skips it."))
            }
            if !fm.strictYAMLKeys.isEmpty {
                return .rejected(reason: L("\(fm.strictYAMLKeys.joined(separator: ", ")) in SKILL.md isn't valid YAML — an unquoted value with “: ” in it. Codex reads the frontmatter strictly and skips the skill."))
            }
            if description.isEmpty {
                return .rejected(reason: L("description is empty. Codex skips skills without one."))
            }
            if identity.count > 64 {
                return .rejected(reason: L("name is longer than 64 characters. Codex skips it."))
            }
            if root.kind == .codexLegacy {
                return .visible(note: L("Loaded from ~/.codex/skills, which Codex keeps only for backward compatibility."))
            }
            if description.count > 1024 {
                return .visible(note: L("Codex cuts the description to 1024 characters in its skill list."))
            }
            return .visible(note: nil)

        case .zoo:
            if depth > maxDepth {
                return .rejected(reason: L("Nested \(depth) folders deep. Zoo / Roo only looks one level into its skills folder."))
            }
            if !fm.hasFrontmatter {
                return .rejected(reason: L("SKILL.md has no frontmatter. Zoo / Roo skips it."))
            }
            if !fm.strictYAMLKeys.isEmpty {
                return .rejected(reason: L("\(fm.strictYAMLKeys.joined(separator: ", ")) in SKILL.md isn't valid YAML — an unquoted value with “: ” in it. Zoo / Roo reads the frontmatter strictly and skips the skill."))
            }
            guard let name = fm.name?.nilIfBlank else {
                return .rejected(reason: L("name is missing. Zoo / Roo requires it."))
            }
            if name != folderName {
                return .rejected(reason: L("name: \(name) differs from the folder name \(folderName). Zoo / Roo skips a skill unless the two match."))
            }
            if name.count > 64 || name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) == nil {
                return .rejected(reason: L("name \(name) isn't lowercase letters, digits and single hyphens (up to 64). Zoo / Roo skips it."))
            }
            if description.isEmpty {
                return .rejected(reason: L("description is empty. Zoo / Roo skips skills without one."))
            }
            if description.utf16.count > 1024 {
                return .rejected(reason: L("description is \(description.utf16.count) characters; Zoo / Roo skips anything over 1024."))
            }
            return .visible(note: nil)
        }
    }
}

/// Every copy of one skill (grouped by its name), with what each agent ends up seeing.
struct SkillGroup: Identifiable, Hashable {
    let name: String
    let entries: [SkillEntry]

    var id: String { name }

    /// Copies that live in different places (symlinks to the same folder count once).
    var distinctCopies: [SkillEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.resolvedURL.path).inserted }
    }

    /// True when copies of the skill in different places have different contents.
    var hasDrift: Bool { Set(distinctCopies.map(\.contentHash)).count > 1 }

    var newestCopy: SkillEntry? {
        distinctCopies.max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
    }

    var author: String? { entries.lazy.compactMap(\.frontmatter.author).first }

    var description: String? { entries.lazy.compactMap(\.frontmatter.description).first }

    func visibility(for agent: MemoryAgent) -> SkillVisibility {
        let all = entries.map { $0.visibility(for: agent) }
        if let visible = all.first(where: \.isVisible) {
            // Zoo / Roo lets ~/.roo shadow ~/.agents: say so if a differing copy wins.
            if agent == .zoo, hasDrift {
                let readByZoo = entries.filter { $0.visibility(for: .zoo).isVisible }
                if Set(readByZoo.map(\.contentHash)).count > 1 {
                    return .visible(note: L("Zoo / Roo reads two different copies; the one in ~/.roo/skills wins."))
                }
            }
            if agent == .codex {
                let readByCodex = entries.filter { $0.visibility(for: .codex).isVisible }
                if Set(readByCodex.map(\.resolvedURL.path)).count > 1 {
                    return .visible(note: L("Codex lists this skill \(Set(readByCodex.map(\.resolvedURL.path)).count) times — once per copy."))
                }
            }
            return visible
        }
        return all.first(where: \.isRejected) ?? .absent
    }

    var hasAgentProblem: Bool { MemoryAgent.allCases.contains { visibility(for: $0).isRejected } }

    var isSeenByNoAgent: Bool { MemoryAgent.allCases.allSatisfy { !visibility(for: $0).isVisible } }

    var hasProblem: Bool { hasAgentProblem || hasDrift || isSeenByNoAgent }
}

/// A global instruction file an agent loads into every session.
struct InstructionSource: Identifiable, Hashable {
    let agent: MemoryAgent
    let url: URL
    let bytes: Int
    let exists: Bool
    var id: String { url.path }
}

struct HealthFinding: Identifiable, Hashable {
    enum Severity: Int, Comparable, CaseIterable {
        case error, warning, info
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .error: return L("Problems")
            case .warning: return L("Warnings")
            case .info: return L("Notes")
            }
        }
    }

    let code: String
    let severity: Severity
    let title: String
    let detail: String
    let paths: [URL]
    /// Orders findings of the same kind: bigger first (e.g. more line-number links).
    var weight: Int = 0
    /// What Embarsy can do about it by itself, if anything.
    var fix: HealthFix? = nil
    /// H11: the verdict the person decides on — not a fix: which note is right is theirs to say.
    var contradiction: ContradictionRecord? = nil
    /// Somewhere in Embarsy to go and deal with it (the Inbox, Knowledge).
    var action: HealthAction? = nil
    /// What the local model can draft for it; the person still decides.
    var assist: HealthAssist? = nil

    var id: String { code + "|" + title + "|" + paths.map(\.path).joined(separator: ",") }
}

struct MemorySnapshot {
    var roots: [SkillRoot] = []
    var skillCounts: [String: Int] = [:]
    var groups: [SkillGroup] = []
    var systemSkillNames: Set<String> = []
    var instructions: [InstructionSource] = []
    var findings: [HealthFinding] = []
    var scannedAt = Date()
}

// MARK: - Scanner

struct MemoryScanner {
    let home: URL
    let extraFolders: [URL]
    /// The memory base, if one is set up: its skills are sources, like an extra folder.
    let vault: VaultLayout?
    private let fm = FileManager.default

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, extraFolders: [URL] = [], vault: VaultLayout? = nil) {
        self.home = home
        self.extraFolders = extraFolders
        self.vault = vault
    }

    func scan() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        let roots = discoverRoots()
        snapshot.roots = roots

        var entries: [SkillEntry] = []
        var leftovers: [SkillEntry] = []
        for root in roots {
            let found = skills(in: root)
            snapshot.skillCounts[root.id] = found.count
            if root.kind == .codexSystem {
                snapshot.systemSkillNames.formUnion(found.map(\.identity))
            } else if root.kind == .zooStaleCopy {
                // Copies in a folder nothing reads are leftovers, not skills: they don't drift
                // from anything an agent sees, they're just in the way.
                leftovers += found
            } else {
                entries += found
            }
        }

        let grouped = Dictionary(grouping: entries, by: \.identity)
        snapshot.groups = grouped.map { SkillGroup(name: $0.key, entries: $0.value) }
            .sorted { ($0.hasProblem ? 0 : 1, $0.name) < ($1.hasProblem ? 0 : 1, $1.name) }
        snapshot.instructions = instructionSources()
        snapshot.findings = findings(groups: snapshot.groups,
                                     systemNames: snapshot.systemSkillNames,
                                     instructions: snapshot.instructions)
        snapshot.findings += leftoverFindings(leftovers)
        snapshot.findings.sort { ($0.severity, $0.code, -$0.weight, $0.title) < ($1.severity, $1.code, -$1.weight, $1.title) }
        snapshot.scannedAt = Date()
        return snapshot
    }

    // MARK: Roots

    func discoverRoots() -> [SkillRoot] {
        var roots: [SkillRoot] = []
        func add(_ url: URL, _ kind: SkillRoot.Kind) {
            guard isDirectory(url), !roots.contains(where: { $0.url.path == url.path }) else { return }
            roots.append(SkillRoot(url: url, kind: kind))
        }

        let agents = home.appendingPathComponent(".agents")
        let roo = home.appendingPathComponent(".roo")
        add(home.appendingPathComponent(".claude/skills"), .claudeUser)
        add(agents.appendingPathComponent("skills"), .agentsUser)
        for mode in modeFolders(in: agents) { add(agents.appendingPathComponent("skills-\(mode)"), .agentsMode(mode)) }
        add(home.appendingPathComponent(".codex/skills"), .codexLegacy)
        add(home.appendingPathComponent(".codex/skills/.system"), .codexSystem)
        add(roo.appendingPathComponent("skills"), .rooUser)
        for mode in modeFolders(in: roo) { add(roo.appendingPathComponent("skills-\(mode)"), .rooMode(mode)) }
        add(home.appendingPathComponent("Library/Application Support/Code/User/globalStorage/zoocodeorganization.zoo-code/settings/skills"), .zooStaleCopy)
        if let vault {
            add(vault.ownSkills, .vault)
            add(vault.adoptedSkills, .vault)
            add(vault.vendorSkills, .vault)
        }
        for folder in extraFolders { add(folder.standardizedFileURL, .extra) }
        return roots
    }

    private func modeFolders(in folder: URL) -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("skills-") && $0.count > 7 }
            .map { String($0.dropFirst(7)) }
            .sorted()
    }

    // MARK: Skills

    /// Breadth-first, like Codex: up to six levels, hidden entries skipped, symlinks followed,
    /// and scanning continues inside a skill folder. Deeper finds are kept so the UI can say
    /// "too deep for Claude / Zoo" instead of silently not listing them.
    func skills(in root: SkillRoot) -> [SkillEntry] {
        var result: [SkillEntry] = []
        var queue: [(URL, Int)] = [(root.url, 0)]
        var visited = Set<String>()
        var scannedFolders = 0

        while !queue.isEmpty, scannedFolders < 2000 {
            let (folder, depth) = queue.removeFirst()
            let real = folder.resolvingSymlinksInPath().path
            guard visited.insert(real).inserted else { continue }
            scannedFolders += 1

            if depth > 0, isFile(folder.appendingPathComponent("SKILL.md")) {
                result.append(entry(at: folder, root: root, depth: depth))
            }
            guard depth < 6 else { continue }
            let children = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            for child in children where !child.hasPrefix(".") {
                let url = folder.appendingPathComponent(child)
                if isDirectory(url) { queue.append((url, depth + 1)) }
            }
        }
        return result
    }

    private func entry(at folder: URL, root: SkillRoot, depth: Int) -> SkillEntry {
        let resolved = folder.resolvingSymlinksInPath()
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil
        let text = (try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
        let (hash, modified) = treeFingerprint(resolved)
        return SkillEntry(root: root, url: folder, resolvedURL: resolved, depth: depth,
                          isSymlink: isLink, frontmatter: Self.parseFrontmatter(text),
                          contentHash: hash, modified: modified)
    }

    /// Hash of every file under the skill (relative path + bytes), ignoring Finder litter,
    /// plus the newest modification date among them.
    private func treeFingerprint(_ folder: URL) -> (String, Date?) {
        var hasher = SHA256()
        var newest: Date?
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == ".DS_Store" { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            files.append(url)
            if let date = values?.contentModificationDate, date > (newest ?? .distantPast) { newest = date }
        }
        for url in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(Self.relativePath(of: url, in: folder).utf8))
            if let data = try? Data(contentsOf: url) { hasher.update(data: data) }
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (hash, newest)
    }

    // MARK: Frontmatter

    /// A deliberately small YAML reader: top-level `key: value` pairs (plain, quoted, or `|` / `>`
    /// block scalars) plus `metadata.author`. That is all the agents' loaders look at.
    /// "Bring into the base" for a skill that lives outside it, when the base has room for it.
    private func adoptFix(_ group: SkillGroup, replaceOriginal: Bool) -> HealthFix? {
        guard let vault, let copy = group.newestCopy else { return nil }
        let base = vault.root.resolvingSymlinksInPath().path + "/"
        guard !copy.resolvedURL.path.hasPrefix(base),
              group.name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil,
              !FileManager.default.fileExists(atPath: vault.adoptedSkills.appendingPathComponent(group.name).path),
              !FileManager.default.fileExists(atPath: vault.ownSkills.appendingPathComponent(group.name).path) else { return nil }
        return .adoptSkill(from: copy.url, name: group.name, replaceOriginal: replaceOriginal)
    }

    /// A plain (unquoted) scalar strict YAML refuses: "a: b" inside it starts a mapping where
    /// none can be, and a leading indicator character starts something else entirely.
    static func breaksStrictYAML(_ value: String) -> Bool {
        guard let first = value.first, first != "\"", first != "'", first != "|", first != ">" else { return false }
        return value.contains(": ") || value.hasSuffix(":") || "@`%&*!".contains(first)
    }

    static func parseFrontmatter(_ text: String) -> SkillFrontmatter {
        var result = SkillFrontmatter()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return result }
        result.hasFrontmatter = true
        let body = Array(lines[1..<end])

        var values: [String: String] = [:]
        var index = 0
        var parent: String?
        while index < body.count {
            let line = body[index]
            index += 1
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let indented = line.first == " " || line.first == "\t"
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            if !indented { parent = value.isEmpty ? key : nil }
            let fullKey = indented ? "\(parent ?? "").\(key)" : key
            if indented && parent == nil { continue }

            if value.hasPrefix("|") || value.hasPrefix(">") {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                while index < body.count {
                    let next = body[index]
                    if !next.trimmingCharacters(in: .whitespaces).isEmpty && !(next.first == " " || next.first == "\t") { break }
                    block.append(next.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                while block.last?.isEmpty == true { block.removeLast() }
                value = folded ? block.joined(separator: " ") : block.joined(separator: "\n")
            } else {
                if !indented, Self.breaksStrictYAML(value) { result.strictYAMLKeys.append(key) }
                value = unquote(value)
            }
            values[fullKey] = value
        }

        result.name = values["name"]?.nilIfBlank
        result.description = values["description"]
        result.author = values["metadata.author"]?.nilIfBlank ?? values["author"]?.nilIfBlank
        result.embarsyAgents = Set((values["metadata.embarsy-agents"] ?? "")
            .split(separator: ",")
            .compactMap { MemoryAgent(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) })
        return result
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"") : inner.replacingOccurrences(of: "''", with: "'")
    }

    // MARK: Instructions

    func instructionSources() -> [InstructionSource] {
        func source(_ agent: MemoryAgent, _ url: URL) -> InstructionSource {
            let bytes = (try? Data(contentsOf: url))?.count ?? 0
            return InstructionSource(agent: agent, url: url, bytes: bytes, exists: isFile(url))
        }
        var result = [source(.claude, home.appendingPathComponent(".claude/CLAUDE.md"))]

        // Codex uses the first non-empty of AGENTS.override.md and AGENTS.md.
        let override = source(.codex, home.appendingPathComponent(".codex/AGENTS.override.md"))
        result.append(override.bytes > 0 ? override : source(.codex, home.appendingPathComponent(".codex/AGENTS.md")))

        let rules = home.appendingPathComponent(".roo/rules")
        let ruleFiles = markdownFiles(under: rules)
        if ruleFiles.isEmpty {
            result.append(InstructionSource(agent: .zoo, url: rules, bytes: 0, exists: isDirectory(rules)))
        } else {
            result += ruleFiles.map { source(.zoo, $0) }
        }
        return result
    }

    // MARK: Health

    func findings(groups: [SkillGroup], systemNames: Set<String>, instructions: [InstructionSource]) -> [HealthFinding] {
        var out: [HealthFinding] = []

        for group in groups {
            // H01 — an agent reads the folder but drops every copy of the skill.
            // Frontmatter that isn't strict YAML is one problem for every strict reader, with
            // one fix, so it's one finding naming them all — not one per agent with the fix on
            // only one of them.
            let strictlyRejected = MemoryAgent.allCases.filter { agent in
                group.visibility(for: agent).isRejected
                    && group.entries.contains { !$0.frontmatter.strictYAMLKeys.isEmpty && $0.visibility(for: agent).isRejected }
            }
            if let broken = group.entries.first(where: { !$0.frontmatter.strictYAMLKeys.isEmpty }), !strictlyRejected.isEmpty {
                let keys = broken.frontmatter.strictYAMLKeys.joined(separator: ", ")
                let agents = ListFormatter.localizedString(byJoining: strictlyRejected.map(\.label))
                let several = strictlyRejected.count > 1
                var finding = HealthFinding(code: "H01", severity: .error,
                                            title: several ? L("\(agents) skip \(group.name)") : L("\(agents) skips \(group.name)"),
                                            detail: several
                                                ? L("\(keys) in SKILL.md isn't valid YAML — an unquoted value with “: ” in it. \(agents) read the frontmatter strictly and skip the skill; Claude Code reads it anyway.")
                                                : L("\(keys) in SKILL.md isn't valid YAML — an unquoted value with “: ” in it. \(agents) reads the frontmatter strictly and skips the skill; Claude Code reads it anyway."),
                                            paths: [broken.url])
                if let vault, broken.resolvedURL.path.hasPrefix(vault.root.resolvingSymlinksInPath().path + "/") {
                    finding.fix = .quoteFrontmatter(file: broken.resolvedURL.appendingPathComponent("SKILL.md"),
                                                    keys: broken.frontmatter.strictYAMLKeys)
                } else {
                    // Outside the base Embarsy doesn't edit files, so say what to do by hand.
                    finding = HealthFinding(code: finding.code, severity: finding.severity, title: finding.title,
                                            detail: finding.detail + " " + L("To fix it, put the value of \(keys) in double quotes in that SKILL.md."),
                                            paths: finding.paths)
                }
                out.append(finding)
            }
            for agent in MemoryAgent.allCases where !strictlyRejected.contains(agent) {
                guard case .rejected(let reason) = group.visibility(for: agent) else { continue }
                let rejected = group.entries.filter { $0.visibility(for: agent).isRejected }
                var finding = HealthFinding(code: "H01", severity: .error,
                                            title: L("\(agent.label) skips \(group.name)"),
                                            detail: reason + " " + L("Change that in the skill's folder or SKILL.md, then press Rescan."),
                                            paths: rejected.map(\.url))
                // Inside the base, two of these Embarsy can settle: a name that differs from
                // its folder, and (with the assistant) a description that's too long.
                if let vault, let own = rejected.first(where: { $0.resolvedURL.path.hasPrefix(vault.root.resolvingSymlinksInPath().path + "/") }) {
                    let file = own.resolvedURL.appendingPathComponent("SKILL.md")
                    let fm = own.frontmatter
                    if let name = fm.name?.nilIfBlank, name != own.folderName,
                       own.folderName.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil {
                        finding.fix = .setSkillName(file: file, name: own.folderName)
                    } else if (fm.description?.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count ?? 0) > 1024 {
                        finding.assist = .shortenDescription(file: file, skill: group.name)
                    }
                }
                out.append(finding)
            }

            // H02 — copies of the same skill disagree.
            if group.hasDrift {
                let copies = group.distinctCopies
                let lines = copies.map { copy -> String in
                    let date = copy.modified.map { Self.dateFormatter.string(from: $0) } ?? L("unknown date")
                    let readers = group.entries
                        .filter { $0.resolvedURL.path == copy.resolvedURL.path }
                        .flatMap { entry in MemoryAgent.allCases.filter { entry.visibility(for: $0).isVisible } }
                    let readBy = Set(readers).isEmpty
                        ? L("no agent reads it")
                        : L("read by \(MemoryAgent.allCases.filter(Set(readers).contains).map(\.label).joined(separator: ", "))")
                    return L("• \(Self.tilde(copy.resolvedURL)) — changed \(date), \(readBy)")
                }
                var drift = HealthFinding(code: "H02", severity: .error,
                                         title: L("\(copies.count) copies of \(group.name) differ"),
                                         detail: L("Each agent sees whichever copy sits in its own folder, so a rule added to one copy doesn't reach the others. The most recently changed copy isn't necessarily the right one — compare them before keeping one.") + "\n" + lines.joined(separator: "\n"),
                                         paths: copies.map(\.resolvedURL))
                drift.assist = .compareCopies(skill: group.name, copies: copies.map(\.resolvedURL))
                out.append(drift)
            }

            // H03 — clashes with a skill Codex ships.
            if systemNames.contains(group.name), group.visibility(for: .codex).isVisible {
                var clash = HealthFinding(code: "H03", severity: .warning,
                                          title: L("\(group.name) has the same name as a skill bundled with Codex"),
                                          detail: L("Codex lists both, and the model may pick either. Rename one of them — its folder and the name in its SKILL.md — or remove the one you don't need."),
                                          paths: group.entries.map(\.url))
                if let copy = group.newestCopy {
                    clash.assist = .suggestNames(skill: group.name, file: copy.resolvedURL.appendingPathComponent("SKILL.md"))
                }
                out.append(clash)
            }

            // H14 — lives only in one agent's private folder.
            let visibleTo = MemoryAgent.allCases.filter { group.visibility(for: $0).isVisible }
            if visibleTo.count == 1, let only = visibleTo.first,
               group.entries.allSatisfy({ $0.root.isAgentPrivate || $0.root.readers.isEmpty }) {
                var lonely = HealthFinding(code: "H14", severity: .info,
                                           title: L("Only \(only.label) sees \(group.name)"),
                                           detail: L("It sits in \(only.label)'s own skills folder, where its UI creates new skills. The other agents don't know it exists. To share it, bring it into the memory base with Bring existing memory, or move it to ~/.agents/skills."),
                                           paths: group.distinctCopies.map(\.url))
                lonely.fix = adoptFix(group, replaceOriginal: true)
                out.append(lonely)
            }

            // H18 — sits only in folders no agent reads.
            if group.isSeenByNoAgent, !group.hasAgentProblem {
                var unseen = HealthFinding(code: "H18", severity: .warning,
                                           title: L("No agent sees \(group.name)"),
                                           detail: L("It exists only in folders that no agent reads. Move it to ~/.agents/skills or bring it into the memory base — or remove it if you no longer need it."),
                                           paths: group.distinctCopies.map(\.url))
                unseen.fix = adoptFix(group, replaceOriginal: false)
                // A skill in the base that simply hasn't been published yet.
                if let vault, let copy = group.newestCopy,
                   copy.resolvedURL.path.hasPrefix(vault.root.resolvingSymlinksInPath().path + "/"),
                   MemoryPublisher.portabilityProblem(folder: copy.folderName, frontmatter: copy.frontmatter) == nil {
                    unseen = HealthFinding(code: "H18", severity: .warning,
                                           title: L("No agent sees \(group.name)"),
                                           detail: L("It's in the memory base but not published yet, so no agent has a link to it."),
                                           paths: [copy.url])
                    unseen.fix = .publish
                }
                // A skill already in the base that publishing holds back: say why, and settle
                // what Embarsy can — the name, or (with the assistant) a long description.
                if let vault, let copy = group.newestCopy,
                   copy.resolvedURL.path.hasPrefix(vault.root.resolvingSymlinksInPath().path + "/"),
                   let problem = MemoryPublisher.portabilityProblem(folder: copy.folderName, frontmatter: copy.frontmatter) {
                    unseen = HealthFinding(code: "H18", severity: .warning,
                                           title: L("\(group.name) isn't published to any agent"),
                                           detail: L("It's in the memory base, but publishing holds it back because an agent would reject it: \(problem)"),
                                           paths: [copy.url])
                    let file = copy.resolvedURL.appendingPathComponent("SKILL.md")
                    if let name = copy.frontmatter.name?.nilIfBlank, name != copy.folderName,
                       copy.folderName.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil {
                        unseen.fix = .setSkillName(file: file, name: copy.folderName)
                    } else if (copy.frontmatter.description?.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count ?? 0) > 1024 {
                        unseen.assist = .shortenDescription(file: file, skill: copy.folderName)
                    }
                }
                out.append(unseen)
            }
        }

        // H04 / H05 — links, read from one copy per skill (the most recently changed) so
        // three copies of a skill don't report the same file three times.
        for group in groups {
            guard let copy = group.newestCopy else { continue }
            out += linkFindings(in: copy.resolvedURL, skill: group.name)
        }
        // H12 — secrets, from every copy: an old copy leaks as much as a new one.
        var secretLabels = Set<String>()
        for copy in groups.flatMap(\.distinctCopies) {
            for finding in secretFindings(in: copy.resolvedURL, skill: copy.identity)
            where secretLabels.insert(finding.title).inserted {
                out.append(finding)
            }
        }
        for source in instructions where source.exists && source.bytes > 0 {
            out += fileLinkFindings(file: source.url, label: Self.tilde(source.url))
            if let secret = secretFinding(file: source.url, label: Self.tilde(source.url)) { out.append(secret) }
        }

        if let vault {
            out += noteLinkFindings(vault)
            out += staleFindings(vault)
            out += orphanFindings(vault)
            out += VendorLock.findings(vault)
            if let budget = CoreBudget.finding(vault) { out.append(budget) }
        }

        // H19 — an agent that sees none of the skills the others see.
        let anyVisible = groups.filter { group in MemoryAgent.allCases.contains { group.visibility(for: $0).isVisible } }
        for agent in MemoryAgent.allCases where !anyVisible.isEmpty {
            guard !groups.contains(where: { $0.visibility(for: agent).isVisible }) else { continue }
            let folder: URL
            switch agent {
            case .claude: folder = home.appendingPathComponent(".claude/skills")
            case .codex, .zoo: folder = home.appendingPathComponent(".agents/skills")
            }
            var none = HealthFinding(code: "H19", severity: .error,
                                     title: L("\(agent.label) doesn't see any of your skills"),
                                     detail: L("\(anyVisible.count) of your skills are available to other agents, but none is in \(Self.tilde(folder)), where \(agent.label) looks for them. Publish them for \(agent.label) in Memory → Core."),
                                     paths: [isDirectory(folder) ? folder : folder.deletingLastPathComponent()])
            if vault != nil { none.fix = .publish }
            out.append(none)
        }

        // H17 — proposals left waiting in the inbox.
        if let vault {
            let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
            let stale = MemoryInbox(layout: vault).items().filter { ($0.modified ?? Date()) < cutoff }
            if !stale.isEmpty {
                var waiting = HealthFinding(code: "H17", severity: .info,
                                            title: L("\(stale.count) proposals have waited in the inbox for over two weeks"),
                                            detail: L("Agents don't see inbox proposals until you accept them. Review them in Memory → Inbox."),
                                            paths: stale.map(\.url))
                waiting.action = .openInbox
                out.append(waiting)
            }
        }

        // H15 — the skill list each agent puts in every turn.
        out += budgetFindings(groups: groups, systemNames: systemNames)

        // H16 — agents with no global instructions.
        for agent in MemoryAgent.allCases {
            let mine = instructions.filter { $0.agent == agent }
            guard mine.allSatisfy({ $0.bytes == 0 }), let first = mine.first else { continue }
            var bare = HealthFinding(code: "H16", severity: .warning,
                                     title: L("\(agent.label) gets no global instructions"),
                                     detail: first.exists
                                        ? L("\(Self.tilde(first.url)) is empty, so \(agent.label) starts every session without your standing rules. Publish in Memory → Core to connect it.")
                                        : L("\(Self.tilde(first.url)) doesn't exist, so \(agent.label) starts every session without your standing rules. Publish in Memory → Core to connect it."),
                                     paths: [first.exists ? first.url : first.url.deletingLastPathComponent()])
            if vault != nil { bare.fix = .publish }
            out.append(bare)
        }

        return out.sorted { ($0.severity, $0.code, -$0.weight, $0.title) < ($1.severity, $1.code, -$1.weight, $1.title) }
    }

    /// H20 — leftover copies in folders nothing reads, with a way to clear them.
    private func leftoverFindings(_ leftovers: [SkillEntry]) -> [HealthFinding] {
        guard !leftovers.isEmpty else { return [] }
        let folders = leftovers.map(\.url)
        return [HealthFinding(code: "H20", severity: .info,
                              title: L("\(leftovers.count) leftover copies in a folder no agent reads"),
                              detail: L("Old copies in \(Self.tilde(leftovers[0].url.deletingLastPathComponent())). No agent loads them, so they don't affect anything — they only make it harder to see what agents really use: \(leftovers.map(\.folderName).sorted().joined(separator: ", "))."),
                              paths: folders,
                              fix: vault == nil ? nil : .moveLeftovers(folders))]
    }

    /// Links in the base's own notes (knowledge, experience, people), which Embarsy may fix.
    private func noteLinkFindings(_ vault: VaultLayout) -> [HealthFinding] {
        var out: [HealthFinding] = []
        var anchored = 0
        var anchoredFiles: [URL] = []
        for section in [vault.knowledge, vault.experience, vault.people] {
            for file in markdownFiles(under: section) {
                let links = checkLinks(file: file)
                if !links.broken.isEmpty {
                    out.append(brokenLinksFinding(file: file, label: Self.relativePath(of: file, in: vault.root), broken: links.broken))
                }
                if let found = leftBehindFinding(file: file, label: Self.relativePath(of: file, in: vault.root)) { out.append(found) }
                if links.anchored > 0 {
                    anchored += links.anchored
                    anchoredFiles.append(file)
                }
            }
        }
        if anchored > 0 {
            out.append(lineNumberFinding(count: anchored, label: L("notes"), fileCount: anchoredFiles.count, paths: anchoredFiles))
        }
        return out
    }

    /// How old "verified" may get for knowledge before it's worth a second look.
    static let staleAfterDays = 180

    /// H09 — knowledge last checked long ago. Only a person can re-check it, so there is no
    /// automatic fix; the Knowledge tab has "mark verified" for after they have.
    private func staleFindings(_ vault: VaultLayout) -> [HealthFinding] {
        let cutoff = Date().addingTimeInterval(-Double(Self.staleAfterDays) * 24 * 3600)
        let stale = markdownFiles(under: vault.knowledge).filter { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let value = MarkdownRenderer.split(text).fields.first(where: { $0.0 == "verified_at" })?.1,
                  let date = ISO8601DateFormatter.dateOnly.date(from: String(value.prefix(10))) else { return false }
            return date < cutoff
        }
        guard !stale.isEmpty else { return [] }
        var old = HealthFinding(code: "H09", severity: .warning,
                                title: L("\(stale.count) knowledge notes were last verified over \(Self.staleAfterDays / 30) months ago"),
                                detail: L("What they describe may have changed since — code, services and processes move on. Re-check each one; then open it in Knowledge and mark it verified, so agents know they can rely on it."),
                                paths: stale)
        old.action = .openKnowledge
        return [old]
    }

    /// H13 — notes nothing links to. Not wrong — recall finds them anyway — just unconnected.
    private func orphanFindings(_ vault: VaultLayout) -> [HealthFinding] {
        var linked = Set<String>()
        let all = markdownFiles(under: vault.root).filter { !$0.path.hasPrefix(vault.archive.path + "/") }
        for file in all {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for target in Self.markdownLinkTargets(in: text) {
                var path = target
                if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
                if let range = path.range(of: #":\d+$"#, options: .regularExpression) { path.removeSubrange(range) }
                let decoded = path.removingPercentEncoding ?? path
                let resolved = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : file.deletingLastPathComponent().appendingPathComponent(decoded)
                linked.insert(resolved.standardizedFileURL.path)
            }
        }
        let orphans = (markdownFiles(under: vault.knowledge) + markdownFiles(under: vault.people))
            .filter { !linked.contains($0.standardizedFileURL.path) }
        guard !orphans.isEmpty else { return [] }
        return [HealthFinding(code: "H13", severity: .info,
                              title: L("\(orphans.count) notes nothing links to"),
                              detail: L("Agents still find them with recall. Linking related notes to each other helps an agent that opens one find the rest."),
                              paths: orphans)]
    }

    /// The base's files are Embarsy's to edit; everything else is only reported.
    private func isInVault(_ file: URL) -> Bool {
        guard let vault else { return false }
        let root = vault.root.standardizedFileURL.resolvingSymlinksInPath().path
        return file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root + "/")
    }

    private var resolver: LinkResolver? {
        vault.map { LinkResolver(layout: $0, home: home, map: MigrationMap.load(layout: $0, home: home)) }
    }

    /// One H04 per file with broken links; one H05 per skill, totalled across its files.
    private func linkFindings(in folder: URL, skill: String) -> [HealthFinding] {
        var out: [HealthFinding] = []
        var anchored = 0
        var anchoredFiles: [URL] = []
        for file in markdownFiles(under: folder) {
            let label = "\(skill)/\(Self.relativePath(of: file, in: folder))"
            let links = checkLinks(file: file)
            if !links.broken.isEmpty { out.append(brokenLinksFinding(file: file, label: label, broken: links.broken)) }
            if let found = leftBehindFinding(file: file, label: label) { out.append(found) }
            if links.anchored > 0 {
                anchored += links.anchored
                anchoredFiles.append(file)
            }
        }
        if anchored > 0 {
            out.append(lineNumberFinding(count: anchored, label: skill, fileCount: anchoredFiles.count, paths: anchoredFiles))
        }
        return out
    }

    private func fileLinkFindings(file: URL, label: String) -> [HealthFinding] {
        let links = checkLinks(file: file)
        var out: [HealthFinding] = []
        if !links.broken.isEmpty { out.append(brokenLinksFinding(file: file, label: label, broken: links.broken)) }
        if links.anchored > 0 { out.append(lineNumberFinding(count: links.anchored, label: label, fileCount: 1, paths: [file])) }
        return out
    }

    private func checkLinks(file: URL) -> (broken: [String], anchored: Int) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return ([], 0) }
        var broken: [String] = []
        var anchored = 0
        for target in Self.markdownLinkTargets(in: text) {
            var path = target
            if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
            if let range = path.range(of: #":\d+$"#, options: .regularExpression) {
                anchored += 1
                path.removeSubrange(range)
            }
            guard !path.isEmpty else { continue }
            let decoded = path.removingPercentEncoding ?? path
            let resolved = decoded.hasPrefix("/")
                ? URL(fileURLWithPath: decoded)
                : file.deletingLastPathComponent().appendingPathComponent(decoded)
            if !fm.fileExists(atPath: resolved.path), !broken.contains(target) { broken.append(target) }
        }
        return (broken, anchored)
    }

    /// H21 — working links from the base back into a copy the migration left behind. They
    /// break the day that copy is cleaned up, and until then they lead to outdated text.
    private func leftBehindFinding(file: URL, label: String) -> HealthFinding? {
        guard isInVault(file), let resolver,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let repairs = Self.markdownLinkTargets(in: text).reduce(into: [LinkRepair]()) { out, target in
            if !out.contains(where: { $0.original == target }), let repair = resolver.leftBehindRepair(for: target, in: file) {
                out.append(repair)
            }
        }
        guard !repairs.isEmpty else { return nil }
        return HealthFinding(code: "H21", severity: .warning,
                             title: L("\(repairs.count) links to old copies in \(label)"),
                             detail: L("They point at files in the folders the migration read, not at the base. They break once those old copies are cleaned up, and until then they lead to outdated text."),
                             paths: [file], weight: repairs.count,
                             fix: .repairLinks(file: file, repairs: repairs))
    }

    private func brokenLinksFinding(file: URL, label: String, broken: [String]) -> HealthFinding {
        var fix: HealthFix?
        if isInVault(file), let resolver {
            fix = .repairLinks(file: file, repairs: resolver.repairs(for: broken, in: file))
        }
        return HealthFinding(code: "H04", severity: .error,
                             title: L("Broken links in \(label)"),
                             detail: broken.count > 8
                                ? L("These targets don't exist: \(broken.prefix(8).joined(separator: ", ")) and \(broken.count - 8) more")
                                : L("These targets don't exist: \(broken.joined(separator: ", "))"),
                             paths: [file], fix: fix)
    }

    private func lineNumberFinding(count: Int, label: String, fileCount: Int, paths: [URL]) -> HealthFinding {
        let editable = paths.filter(isInVault)
        return HealthFinding(code: "H05", severity: .warning,
                             title: fileCount == 1
                                ? L("\(count) links with line numbers in \(label)")
                                : L("\(count) links with line numbers in \(label) across \(fileCount) files"),
                             detail: L("Links like file.md:36 point at a line number, which moves with every edit above it. Link to a heading instead."),
                             paths: paths, weight: count,
                             fix: editable.isEmpty ? nil : .stripLineNumbers(files: editable, count: count))
    }

    /// Every text file in the skill, markdown included.
    private func secretFindings(in folder: URL, skill: String) -> [HealthFinding] {
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var out: [HealthFinding] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent != ".DS_Store",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) < 1_000_000 else { continue }
            if let finding = secretFinding(file: url, label: "\(skill)/\(Self.relativePath(of: url, in: folder))") {
                out.append(finding)
            }
        }
        return out
    }

    private func secretFinding(file: URL, label: String) -> HealthFinding? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var hits: [String] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            for (kind, pattern) in Self.secretPatterns where line.range(of: pattern, options: .regularExpression) != nil {
                hits.append(L("line \(index + 1): \(kind)"))
                break
            }
        }
        guard !hits.isEmpty else { return nil }
        return HealthFinding(code: "H12", severity: .error,
                             title: L("Possible secret in \(label)"),
                             detail: L("Found \(hits.prefix(5).joined(separator: "; ")). The value itself isn't shown here. Agents load this file, so the secret ends up in their context. Remove it from the file and keep it in a password manager or the keychain; if it's a real key, replace it with a new one."),
                             paths: [file])
    }

    static let secretPatterns: [(String, String)] = [
        ("GitHub token", #"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}"#),
        ("GitLab token", #"glpat-[A-Za-z0-9_\-]{20,}"#),
        ("Anthropic key", #"sk-ant-[A-Za-z0-9_\-]{30,}"#),
        ("OpenAI key", #"sk-(proj-)?[A-Za-z0-9]{32,}"#),
        ("AWS access key", #"AKIA[0-9A-Z]{16}"#),
        ("Slack token", #"xox[abpr]-[A-Za-z0-9-]{10,}"#),
        ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
    ]

    private func budgetFindings(groups: [SkillGroup], systemNames: Set<String>) -> [HealthFinding] {
        // Assumes a 200k-token context window: Claude Code spends 1% of it on the skill list,
        // Codex 2%. Mixed Russian / English text runs at roughly 3 characters per token.
        let budgets: [(MemoryAgent, Int, Int)] = [(.claude, 2_000, 1_536), (.codex, 4_000, 1_024)]
        var out: [HealthFinding] = []
        for (agent, budget, cap) in budgets {
            var chars = groups.filter { $0.visibility(for: agent).isVisible }
                .reduce(0) { $0 + $1.name.count + min(($1.description ?? "").count, cap) + 20 }
            if agent == .codex { chars += systemNames.count * 200 }
            let tokens = chars / 3
            guard tokens > budget else { continue }
            out.append(HealthFinding(code: "H15", severity: .warning,
                                     title: L("\(agent.label)'s skill list is over its budget (≈\(tokens.formatted()) of \(budget.formatted()) tokens)"),
                                     detail: L("\(agent.label) shows every skill's name and description in each turn, within a fixed share of the context. Past that it shortens or drops descriptions, and the model stops choosing those skills. Estimate assumes a 200k-token context. Remove skills you don't use, or publish rarely used ones only to the agents that need them (metadata.embarsy-agents in SKILL.md)."),
                                     paths: []))
        }
        return out
    }

    // MARK: Helpers

    static func markdownLinkTargets(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            let target = String(text[r])
            let lower = target.lowercased()
            if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("mailto:")
                || lower.hasPrefix("#") || lower.contains("://") || lower.hasPrefix("<") { return nil }
            return target
        }
    }

    private func markdownFiles(under folder: URL) -> [URL] {
        guard isDirectory(folder) else { return [] }
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var out: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            // A symlinked file counts as the file it points to (Zoo / Roo rules are links).
            if url.pathExtension.lowercased() == "md", isFile(url.resolvingSymlinksInPath()) {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    private func isFile(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
    }

    /// `file`'s path inside `folder`. Both are resolved first: the file enumerator reports
    /// /private/tmp where the folder may say /tmp, and a plain prefix cut would mangle it.
    static func relativePath(of file: URL, in folder: URL) -> String {
        let base = folder.resolvingSymlinksInPath().path
        let path = file.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return file.lastPathComponent }
        return String(path.dropFirst(base.count + 1))
    }

    static func tilde(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLanguage.running.rawValue)
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter
    }()
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
