import CryptoKit
import Foundation

// "Bring existing memory" (docs/memory-spec.md §9.2).
//
// Embarsy does the mechanical part itself — finds where agents keep things, groups copies of
// each skill, cuts journals into entries, flags secrets — and writes it all to a staging
// folder with a task for the user's own agent. The agent does the part that needs judgement
// (what is core, what is knowledge, which of two differing copies is right) and hands back a
// plan. Nothing is written into the base until the user has reviewed that plan.

// MARK: - Sources

struct MigrationSource: Identifiable, Hashable, Codable {
    enum Kind: String, Codable, Hashable {
        /// A folder of skill folders.
        case skills
        /// A file an agent loads into every session.
        case instructions
        /// Claude Code's auto-memory for one project.
        case claudeMemory
        /// Anything else the user pointed at: skills, notes, references.
        case folder
    }

    let path: String
    let kind: Kind
    let label: String
    /// Files that would be read, for the list the user picks from.
    let fileCount: Int

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

enum MigrationSources {
    /// Every place on this Mac where agents keep memory, skills or standing instructions.
    static func detect(home: URL) -> [MigrationSource] {
        let fm = FileManager.default
        var out: [MigrationSource] = []
        func add(_ url: URL, _ kind: MigrationSource.Kind, _ label: String) {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &dir) else { return }
            let count: Int
            if !dir.boolValue {
                count = ((try? Data(contentsOf: url).count) ?? 0) > 0 ? 1 : 0
            } else if kind == .skills {
                count = skillCount(url)
            } else {
                count = markdownCount(url)
            }
            guard count > 0, !out.contains(where: { $0.path == url.path }) else { return }
            out.append(MigrationSource(path: url.path, kind: kind, label: label, fileCount: count))
        }
        add(home.appendingPathComponent(".agents/skills"), .skills, L("Shared skills (Codex, Zoo / Roo)"))
        add(home.appendingPathComponent(".claude/skills"), .skills, L("Claude Code's skills"))
        add(home.appendingPathComponent(".codex/skills"), .skills, L("Codex's old skills folder"))
        add(home.appendingPathComponent(".roo/skills"), .skills, L("Zoo / Roo's skills"))
        add(home.appendingPathComponent("Library/Application Support/Code/User/globalStorage/zoocodeorganization.zoo-code/settings/skills"), .skills, L("Copies in Zoo's settings"))
        add(home.appendingPathComponent(".claude/CLAUDE.md"), .instructions, L("Claude Code's global instructions"))
        add(home.appendingPathComponent(".codex/AGENTS.md"), .instructions, L("Codex's global instructions"))
        add(home.appendingPathComponent(".codex/AGENTS.override.md"), .instructions, L("Codex's override instructions"))
        add(home.appendingPathComponent(".roo/rules"), .instructions, L("Zoo / Roo's rules"))
        let projects = home.appendingPathComponent(".claude/projects")
        for name in ((try? fm.contentsOfDirectory(atPath: projects.path)) ?? []).sorted() {
            let memory = projects.appendingPathComponent(name).appendingPathComponent("memory")
            add(memory, .claudeMemory, L("Claude Code's memory · \(projectLabel(name))"))
        }
        return out
    }

    /// Claude names project folders after their path with dashes ("-Users-me-code-app").
    static func projectLabel(_ folder: String) -> String {
        folder.split(separator: "-").suffix(2).joined(separator: "/")
    }

    static func folder(_ url: URL) -> MigrationSource {
        MigrationSource(path: url.standardizedFileURL.path, kind: .folder, label: L("Added by you"),
                        fileCount: markdownCount(url))
    }

    /// Skill folders, following links — an agent's folder is often made of links alone.
    static func skillCount(_ folder: URL) -> Int {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && fm.fileExists(atPath: folder.appendingPathComponent($0).appendingPathComponent("SKILL.md").path) }
            .count
    }

    static func markdownCount(_ folder: URL) -> Int {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var n = 0
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "md" { n += 1 }
        }
        return n
    }
}

// MARK: - Staging

/// The folder a migration works in until it is applied: inventory, the task, pre-split
/// journal entries, and the agent's plan. Outside the base, so an abandoned migration
/// leaves the base untouched.
struct MigrationStaging: Hashable {
    let root: URL

    var state: URL { root.appendingPathComponent("migration.json") }
    var inventory: URL { root.appendingPathComponent("inventory.json") }
    var inventorySummary: URL { root.appendingPathComponent("inventory.md") }
    var task: URL { root.appendingPathComponent("TASK.md") }
    var plan: URL { root.appendingPathComponent("plan.json") }
    var experience: URL { root.appendingPathComponent("experience") }
    var proposed: URL { root.appendingPathComponent("proposed") }

    static func folder(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Embarsy/migration")
    }
}

struct MigrationState: Codable, Equatable {
    var vaultPath: String
    var sources: [MigrationSource]
    var createdAt: Date
    var agents: [String]
}

// MARK: - Inventory

struct MigrationInventory: Codable {
    struct Copy: Codable {
        let path: String
        let resolved: String
        let isLink: Bool
        let version: String
        let modified: String
        let readBy: [String]
        let folderName: String
    }
    struct Skill: Codable {
        let name: String
        let author: String?
        let description: String?
        let copies: [Copy]
        let copiesDiffer: Bool
        /// Folder named "<prefix>-<name>": a copy a sync script made of a project's own skill.
        let looksLikeProjectCopy: Bool
        let referenceFiles: [String]
    }
    struct File: Codable {
        let path: String
        let bytes: Int
        let source: String
    }
    struct Entry: Codable {
        let file: String
        let date: String
        let title: String
        let from: String
    }

    var sources: [MigrationSource]
    var owner: String
    var skills: [Skill] = []
    var instructions: [File] = []
    var claudeMemories: [File] = []
    var otherNotes: [File] = []
    var experienceEntries: [Entry] = []
    var secrets: [String] = []
}

enum MigrationScanner {
    /// Builds the inventory, pre-splits journals and writes the agent's task. Reads sources only.
    static func prepare(state: MigrationState, staging: MigrationStaging, home: URL) throws -> MigrationInventory {
        let fm = FileManager.default
        try fm.createDirectory(at: staging.experience, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.proposed, withIntermediateDirectories: true)

        var inv = MigrationInventory(sources: state.sources, owner: NSFullUserName())
        let selected = state.sources.map(\.path)
        func isSelected(_ path: String) -> Bool { selected.contains { path == $0 || path.hasPrefix($0 + "/") } }

        // Skills: the Memory scanner already groups copies and knows who reads what.
        let extra = state.sources.filter { $0.kind == .folder || $0.kind == .skills }.map(\.url)
        let snapshot = MemoryScanner(home: home, extraFolders: extra).scan()
        var skillDirs = Set<String>()
        for group in snapshot.groups {
            let copies = group.entries.filter { isSelected($0.url.path) || isSelected($0.resolvedURL.path) }
            guard !copies.isEmpty else { continue }
            var versions: [String] = []
            let rendered: [MigrationInventory.Copy] = copies.map { entry in
                if !versions.contains(entry.contentHash) { versions.append(entry.contentHash) }
                let letter = String(UnicodeScalar(UInt8(65 + (versions.firstIndex(of: entry.contentHash) ?? 0) % 26)))
                return .init(path: entry.url.path, resolved: entry.resolvedURL.path, isLink: entry.isSymlink,
                             version: letter,
                             modified: entry.modified.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                             readBy: MemoryAgent.allCases.filter { entry.visibility(for: $0).isVisible }.map(\.rawValue),
                             folderName: entry.folderName)
            }
            let differ = Set(copies.map(\.contentHash)).count > 1
            let projectCopy = copies.contains { $0.folderName != group.name && $0.folderName.hasSuffix("-" + group.name) }
            let refs = copies.first.map { referenceFiles(in: $0.resolvedURL) } ?? []
            copies.forEach { skillDirs.insert($0.resolvedURL.path) }
            inv.skills.append(.init(name: group.name, author: group.author, description: group.description,
                                    copies: rendered, copiesDiffer: differ, looksLikeProjectCopy: projectCopy,
                                    referenceFiles: refs))
        }

        // Instructions, Claude's memories and anything else in the chosen folders.
        for source in state.sources {
            let files = markdownFiles(source.url)
            switch source.kind {
            case .instructions:
                inv.instructions += files.map { .init(path: $0.path, bytes: size($0), source: source.path) }
            case .claudeMemory:
                inv.claudeMemories += files.filter { $0.lastPathComponent != "MEMORY.md" }
                    .map { .init(path: $0.path, bytes: size($0), source: source.path) }
            case .skills, .folder:
                for file in files where !skillDirs.contains(where: { file.path.hasPrefix($0 + "/") }) && file.lastPathComponent != "SKILL.md" {
                    inv.otherNotes.append(.init(path: file.path, bytes: size(file), source: source.path))
                }
            }
        }

        // Journals with dated entries ("### 2026-08-12 — …") are cut into one file per entry,
        // which is the shape experience/ wants; the agent only has to point at them.
        let allFiles = state.sources.flatMap { markdownFiles($0.url) }
        var seenFiles = Set<String>()
        // The same journal often exists in several copies; an entry that reads the same in
        // all of them is written once.
        var seenEntries = Set<String>()
        for file in allFiles where seenFiles.insert(file.resolvingSymlinksInPath().path).inserted {
            for entry in splitJournal(file) where seenEntries.insert(entry.date + "\u{1f}" + entry.body).inserted {
                let name = "\(entry.date)-\(MemoryInbox.slug(entry.title)).md"
                var target = staging.experience.appendingPathComponent(name)
                var n = 2
                while fm.fileExists(atPath: target.path) {
                    target = staging.experience.appendingPathComponent("\(entry.date)-\(MemoryInbox.slug(entry.title))-\(n).md")
                    n += 1
                }
                try entry.body.write(to: target, atomically: true, encoding: .utf8)
                inv.experienceEntries.append(.init(file: target.path, date: entry.date, title: entry.title, from: file.path))
            }
        }

        // Secrets: listed so the agent leaves them out; the apply step refuses them anyway.
        for file in allFiles {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (kind, pattern) in MemoryScanner.secretPatterns where text.range(of: pattern, options: .regularExpression) != nil {
                inv.secrets.append("\(file.path): looks like a \(kind)")
                break
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(inv).write(to: staging.inventory, options: .atomic)
        try summary(inv).write(to: staging.inventorySummary, atomically: true, encoding: .utf8)
        try MigrationTask.text(state: state, staging: staging, inventory: inv).write(to: staging.task, atomically: true, encoding: .utf8)
        return inv
    }

    struct JournalEntry {
        let date: String
        let title: String
        let body: String
    }

    /// A file with at least two "### YYYY-MM-DD — title" headings is a journal.
    static func splitJournal(_ file: URL) -> [JournalEntry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")
        let heading = try! NSRegularExpression(pattern: #"^#{2,4}\s+(\d{4}-\d{2}-\d{2})\s*[—–-]?\s*(.*)$"#)
        var starts: [(Int, String, String)] = []
        for (i, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if let m = heading.firstMatch(in: line, range: range),
               let d = Range(m.range(at: 1), in: line), let t = Range(m.range(at: 2), in: line) {
                starts.append((i, String(line[d]), String(line[t]).trimmed))
            }
        }
        guard starts.count >= 2 else { return [] }
        var out: [JournalEntry] = []
        for (k, start) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].0 : lines.count
            // Stop at the next heading of the same or higher level, so trailing "## Rules"
            // sections of the journal file don't leak into its last entry.
            var stop = end
            for j in (start.0 + 1)..<end where lines[j].hasPrefix("## ") || lines[j].hasPrefix("# ") {
                stop = j
                break
            }
            let body = lines[(start.0 + 1)..<stop].joined(separator: "\n").trimmed
            let title = start.2.isEmpty ? "Entry \(start.1)" : start.2
            out.append(JournalEntry(date: start.1, title: title, body: "# \(title)\n\n\(body)\n"))
        }
        return out
    }

    static func referenceFiles(in skill: URL) -> [String] {
        markdownFiles(skill).filter { $0.lastPathComponent != "SKILL.md" }.map(\.path)
    }

    static func markdownFiles(_ url: URL) -> [URL] {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) else { return [] }
        if !dir.boolValue { return url.pathExtension.lowercased() == "md" ? [url] : [] }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var out: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            if file.pathExtension.lowercased() == "md" { out.append(file) }
        }
        return out.sorted { $0.path < $1.path }
    }

    private static func size(_ url: URL) -> Int { (try? Data(contentsOf: url).count) ?? 0 }

    static func summary(_ inv: MigrationInventory) -> String {
        var out = ["# Inventory", "", "## Skills (\(inv.skills.count))", ""]
        for s in inv.skills {
            var flags: [String] = []
            if s.copiesDiffer { flags.append("COPIES DIFFER") }
            if s.looksLikeProjectCopy { flags.append("looks like a copy of a project's skill") }
            if let a = s.author { flags.append("author: \(a)") }
            out.append("- **\(s.name)**\(flags.isEmpty ? "" : " — " + flags.joined(separator: "; "))")
            for c in s.copies {
                out.append("  - version \(c.version): \(c.path)\(c.isLink ? " → \(c.resolved)" : "") · changed \(c.modified) · read by \(c.readBy.isEmpty ? "no agent" : c.readBy.joined(separator: ", "))")
            }
            if !s.referenceFiles.isEmpty { out.append("  - reference files: \(s.referenceFiles.count)") }
        }
        out += ["", "## Global instructions (\(inv.instructions.count))", ""]
        out += inv.instructions.map { "- \($0.path) (\($0.bytes) bytes)" }
        out += ["", "## Claude Code memories (\(inv.claudeMemories.count))", ""]
        out += inv.claudeMemories.map { "- \($0.path)" }
        out += ["", "## Journal entries already split (\(inv.experienceEntries.count))", ""]
        out += inv.experienceEntries.map { "- \($0.date) \($0.title): \($0.file)" }
        out += ["", "## Other markdown outside skills (\(inv.otherNotes.count))", ""]
        out += inv.otherNotes.map { "- \($0.path) (\($0.bytes) bytes)" }
        out += ["", "## Possible secrets (\(inv.secrets.count)) — never carry these over", ""]
        out += inv.secrets.map { "- \($0)" }
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - The agent's task

enum MigrationTask {
    /// The one line the user pastes into their agent.
    static func prompt(staging: MigrationStaging) -> String {
        "Read \(staging.task.path) and do what it says. It's a one-off task from Embarsy: move my existing agent memory into my new memory base."
    }

    static func text(state: MigrationState, staging: MigrationStaging, inventory: MigrationInventory) -> String {
        """
        # Task from Embarsy: plan the move of my agent memory

        I'm moving everything my coding agents know into one memory base at `\(state.vaultPath)`, which Claude Code, Codex and Zoo / Roo will all read. Embarsy has already done the mechanical part. Your job is the part that needs judgement: decide what goes where, and hand back a **plan**. I review the plan in Embarsy before anything is written.

        ## Rules

        - **Read only.** Don't create, edit, move or delete anything in the source folders or in `\(state.vaultPath)`. The only place you may write is `\(staging.proposed.path)` (for new text) and the plan itself.
        - Only files inside these sources may be referenced in the plan:
        \(state.sources.map { "  - `\($0.path)` — \($0.label)" }.joined(separator: "\n"))
        - **Never** carry a password, token or key into the plan. The inventory lists possible secrets.
        - When you aren't sure, don't guess: offer alternatives with a `choice` and a question (see the plan format).
        - Write the plan in the language the sources are written in.

        ## What I want

        1. **Core** — who I am, who my agent is, and my standing rules, distilled from global instructions, persona / character / social files and rules scattered across skills. Every agent loads it in every session, so keep it short: everything together under about 3000 characters. Drop routing boilerplate ("ALWAYS load X first"), quality-gate repetition and anything a validator can check.
        2. **Skills** — one per real procedure.
           - Copies of the same skill: keep one. If copies differ, compare them and keep the right one (often the most complete, not the newest); if you can't tell, offer both as a `choice`.
           - A skill that only routes to other files (an index of knowledge, abilities, memory rules) is not a skill: carry its content as notes or core instead.
           - Abilities or procedures hidden in a skill's reference files become skills of their own (give the full SKILL.md text in `skill_md`).
           - A copy of a project's own skill (inventory says "looks like a copy of a project's skill"): skip it — project skills stay in their repositories.
           - `origin`: `own` (mine), `adopted` (mine to edit, origin unknown), `vendor` (someone else's, has a different author; not edited).
           - `name` must be lowercase letters, digits and single hyphens, and must be the folder name.
           - Skills move into the base, so relative links between them (`../other-skill/SKILL.md`) and links to files that don't move will break. Rewrite them in `skill_md`, or point at the note that now holds that content. Line-number links (`file.md:36`) should become links to headings.
        3. **Notes** — durable knowledge in `knowledge/<topic>/…`, experience in `experience/<year>/…`, people in `people/<Name>.md`. Keep a source file whole with `from` when it's already a good note; write new text with `content` when it needs restructuring. Journal entries are already split in `\(staging.experience.path)` — point at them with `from`.
        4. **Skip** anything that shouldn't move, with a reason.

        ## What Embarsy found

        The full inventory is in `\(staging.inventory.path)` (JSON) and `\(staging.inventorySummary.path)` (readable). In short: \(inventory.skills.count) skills (\(inventory.skills.filter(\.copiesDiffer).count) with differing copies, \(inventory.skills.filter(\.looksLikeProjectCopy).count) that look like copies of project skills), \(inventory.instructions.count) global instruction files, \(inventory.claudeMemories.count) Claude Code memories, \(inventory.experienceEntries.count) journal entries, \(inventory.otherNotes.count) other notes, \(inventory.secrets.count) possible secrets.

        ## Plan format

        ```json
        {
          "version": 1,
          "summary": "two or three sentences for me: what you did and what needs my attention",
          "core": {
            "user_name": "", "role": "", "languages": "", "address_as": "", "answer_style": "", "about_me": "",
            "agent_name": "", "tone": "direct | friendly | formal", "about_agent": "",
            "ask_before_changes": true, "browser_only_on_request": true, "no_secrets": true, "separate_facts": true,
            "custom_rules": ["one rule per item"],
            "sources": ["/absolute/paths/you/took/it/from"],
            "reason": "why the core looks like this"
          },
          "skills": [
            {
              "name": "kebab-name",
              "origin": "own | adopted | vendor",
              "vendor_source": "for vendor: where it came from, e.g. a team repository",
              "from": "/absolute/path/to/the/skill/folder/to/copy",
              "skill_md": "optional: full replacement SKILL.md text (to fix it, or for a skill that has no folder yet)",
              "sources": ["/absolute/paths"],
              "reason": "why",
              "choice": "optional: id shared by alternatives"
            }
          ],
          "notes": [
            {
              "path": "knowledge/topic/name.md",
              "type": "knowledge | experience | person",
              "title": "title",
              "from": "/absolute/path/to/an/existing/file (or omit and use content)",
              "content": "markdown body without frontmatter",
              "content_file": "or: a file you wrote under \(staging.proposed.path)",
              "verified_at": "YYYY-MM-DD if the source says when it was checked",
              "sources": ["/absolute/paths"],
              "reason": "why",
              "choice": "optional"
            }
          ],
          "skip": [{ "source": "/absolute/path", "reason": "why it doesn't move" }],
          "questions": [{ "choice": "the id used above", "question": "what I need to decide" }]
        }
        ```

        ## Hand it back

        - If you have Embarsy's `memory_propose` tool, call it with the plan. It checks the plan and tells you what to fix.
        - Otherwise write the plan as JSON to `\(staging.plan.path)`.

        Then tell me it's ready; I'll review it in Embarsy → Memory.
        """
    }
}

// MARK: - The plan

struct MigrationPlan: Codable, Equatable {
    struct Core: Codable, Equatable {
        var user_name: String?
        var role: String?
        var languages: String?
        var address_as: String?
        var answer_style: String?
        var about_me: String?
        var agent_name: String?
        var tone: String?
        var about_agent: String?
        var ask_before_changes: Bool?
        var browser_only_on_request: Bool?
        var no_secrets: Bool?
        var separate_facts: Bool?
        var custom_rules: [String]?
        var sources: [String]?
        var reason: String?
    }
    struct Skill: Codable, Equatable, Identifiable {
        var name: String
        var origin: String?
        var vendor_source: String?
        var from: String?
        var skill_md: String?
        var sources: [String]?
        var reason: String?
        var choice: String?
        var id: String { "skill:" + name + "|" + (from ?? "") + "|" + (choice ?? "") }
    }
    struct Note: Codable, Equatable, Identifiable {
        var path: String
        var type: String?
        var title: String?
        var from: String?
        var content: String?
        var content_file: String?
        var verified_at: String?
        var sources: [String]?
        var reason: String?
        var choice: String?
        var id: String { "note:" + path + "|" + (choice ?? "") }
    }
    struct Skip: Codable, Equatable, Identifiable {
        var source: String
        var reason: String?
        var id: String { "skip:" + source }
    }
    struct Question: Codable, Equatable, Identifiable {
        var choice: String
        var question: String
        var id: String { choice }
    }

    var version: Int?
    var summary: String?
    var core: Core?
    var skills: [Skill]?
    var notes: [Note]?
    var skip: [Skip]?
    var questions: [Question]?

    var profile: CoreProfile {
        var p = CoreProfile()
        guard let c = core else { return p }
        p.userName = c.user_name ?? ""
        p.role = c.role ?? ""
        p.languages = c.languages ?? ""
        p.addressAs = c.address_as ?? ""
        p.answerStyle = c.answer_style ?? ""
        p.aboutMe = c.about_me ?? ""
        p.agentName = c.agent_name ?? ""
        p.tone = CoreProfile.Tone(rawValue: c.tone ?? "") ?? .direct
        p.aboutAgent = c.about_agent ?? ""
        p.askBeforeChanges = c.ask_before_changes ?? true
        p.browserOnlyOnRequest = c.browser_only_on_request ?? true
        p.noSecrets = c.no_secrets ?? true
        p.separateFacts = c.separate_facts ?? true
        p.customRules = (c.custom_rules ?? []).joined(separator: "\n")
        return p
    }

    static func load(_ url: URL) throws -> MigrationPlan {
        try JSONDecoder().decode(MigrationPlan.self, from: Data(contentsOf: url))
    }
}

/// Checks every item against what the plan may touch. A problem excludes the item; it never
/// widens what is read or written.
struct MigrationValidator {
    let state: MigrationState
    let staging: MigrationStaging

    func allowedToRead(_ path: String) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let roots = state.sources.map { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path }
            + [staging.experience.resolvingSymlinksInPath().path, staging.proposed.resolvingSymlinksInPath().path]
        // A skill folder in a source may be a link to a folder elsewhere (that is how agents'
        // folders hold skills); following it is fine as long as the link itself is in a source.
        let raw = URL(fileURLWithPath: path).standardizedFileURL.path
        let rawRoots = state.sources.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        return roots.contains { p == $0 || p.hasPrefix($0 + "/") } || rawRoots.contains { raw == $0 || raw.hasPrefix($0 + "/") }
    }

    func problem(skill s: MigrationPlan.Skill) -> String? {
        if s.name.count > 64 || s.name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) == nil {
            return L("name \(s.name) must be lowercase letters, digits and single hyphens.")
        }
        if let from = s.from {
            guard allowedToRead(from) else { return L("\(from) is outside the folders you chose to bring in.") }
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: from).appendingPathComponent("SKILL.md").path) else {
                return L("\(from) has no SKILL.md.")
            }
        } else if (s.skill_md ?? "").trimmed.isEmpty {
            return L("It has neither a folder to copy nor SKILL.md text.")
        }
        if let md = s.skill_md, let secret = secretIn(md) { return L("Its SKILL.md looks like it contains a \(secret).") }
        if let md = s.skill_md {
            let fm = MemoryScanner.parseFrontmatter(md)
            if let issue = MemoryPublisher.portabilityProblem(folder: s.name, frontmatter: fm) { return issue }
        }
        return nil
    }

    func problem(note n: MigrationPlan.Note, vault: VaultLayout) -> String? {
        guard MemoryInbox(layout: vault).isValidNotePath(n.path) else {
            return L("\(n.path) isn't a note path: use a .md path inside knowledge/, experience/ or people/.")
        }
        if let from = n.from {
            guard allowedToRead(from) else { return L("\(from) is outside the folders you chose to bring in.") }
            guard FileManager.default.fileExists(atPath: from) else { return L("\(from) doesn't exist.") }
        }
        if let file = n.content_file {
            let path = file.hasPrefix("/") ? file : staging.proposed.appendingPathComponent(file).path
            guard allowedToRead(path), FileManager.default.fileExists(atPath: path) else {
                return L("content_file \(file) must be a file under \(staging.proposed.path).")
            }
        }
        if n.from == nil && n.content_file == nil && (n.content ?? "").trimmed.isEmpty { return L("It has no content.") }
        if let text = noteText(n), let secret = secretIn(text) { return L("It looks like it contains a \(secret).") }
        return nil
    }

    func noteText(_ n: MigrationPlan.Note) -> String? {
        if let from = n.from { return try? String(contentsOfFile: from, encoding: .utf8) }
        if let file = n.content_file {
            let path = file.hasPrefix("/") ? file : staging.proposed.appendingPathComponent(file).path
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        return n.content
    }

    func secretIn(_ text: String) -> String? {
        MemoryScanner.secretPatterns.first { text.range(of: $0.1, options: .regularExpression) != nil }?.0
    }
}

// MARK: - Applying

struct MigrationSelection: Equatable {
    var skills: Set<String> = []
    var notes: Set<String> = []
    var useCore = true
}

enum MigrationApplier {
    struct Result {
        var layout: VaultLayout
        var skills = 0
        var notes = 0
        var failures: [String] = []
        var backup: URL
    }

    /// Backs up every source, creates the base from the plan and writes what the user kept.
    static func apply(plan: MigrationPlan, selection: MigrationSelection, state: MigrationState,
                      staging: MigrationStaging, home: URL, now: Date = Date()) throws -> Result {
        let fm = FileManager.default
        let backup = home.appendingPathComponent("Library/Application Support/Embarsy/memory-backups")
            .appendingPathComponent(MemoryPublisher.stamp(now) + "-migration")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try backUpSources(state.sources, into: backup)

        let vaultURL = URL(fileURLWithPath: state.vaultPath)
        let agents = state.agents.compactMap(MemoryAgent.init(rawValue:))
        let profile = selection.useCore ? plan.profile : CoreProfile()
        let layout = try VaultCreator.create(at: vaultURL, profile: profile, agents: agents, home: home, today: now)
        let git = MemoryGit(root: layout.root)
        git.initialize(message: "Memory created from existing agent memory")

        var result = Result(layout: layout, backup: backup)
        let validator = MigrationValidator(state: state, staging: staging)
        let date = ISO8601DateFormatter.dateOnly.string(from: now)
        var vendorLock: [String] = []

        for skill in plan.skills ?? [] where selection.skills.contains(skill.id) {
            if let problem = validator.problem(skill: skill) { result.failures.append(L("Skill \(skill.name): \(problem)")); continue }
            let origin = ["own", "adopted", "vendor"].contains(skill.origin ?? "") ? skill.origin! : "own"
            let base: URL
            switch origin {
            case "vendor":
                let source = MemoryInbox.slug(skill.vendor_source ?? "unknown")
                base = layout.vendorSkills.appendingPathComponent(source)
            case "adopted": base = layout.adoptedSkills
            default: base = layout.ownSkills
            }
            let target = base.appendingPathComponent(skill.name)
            do {
                try fm.createDirectory(at: base, withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                if let from = skill.from {
                    try copyResolvingLinks(from: URL(fileURLWithPath: from).resolvingSymlinksInPath(), to: target)
                } else {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                }
                let skillFile = target.appendingPathComponent("SKILL.md")
                if let md = skill.skill_md, !md.trimmed.isEmpty {
                    try md.write(to: skillFile, atomically: true, encoding: .utf8)
                } else if origin != "vendor" {
                    try fixName(in: skillFile, to: skill.name)
                }
                if origin == "adopted" { try markAdopted(skillFile, date: date) }
                if origin == "vendor" {
                    let fmData = MemoryScanner.parseFrontmatter((try? String(contentsOf: skillFile, encoding: .utf8)) ?? "")
                    vendorLock.append(lockEntry(name: skill.name, folder: target, layout: layout, skill: skill,
                                                author: fmData.author, date: date))
                }
                result.skills += 1
            } catch {
                result.failures.append(L("Skill \(skill.name): \(error.localizedDescription)"))
            }
        }
        if !vendorLock.isEmpty {
            try ("version: 1\nskills:\n" + vendorLock.joined()).write(to: layout.vendorLock, atomically: true, encoding: .utf8)
        }

        for note in plan.notes ?? [] where selection.notes.contains(note.id) {
            if let problem = validator.problem(note: note, vault: layout) { result.failures.append(L("Note \(note.path): \(problem)")); continue }
            guard let body = validator.noteText(note) else { continue }
            let url = layout.root.appendingPathComponent(note.path)
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try noteFile(note, body: body, date: date).write(to: url, atomically: true, encoding: .utf8)
                result.notes += 1
            } catch {
                result.failures.append(L("Note \(note.path): \(error.localizedDescription)"))
            }
        }

        // Where each file came from, so links written relative to the old places can be repaired.
        var map = MigrationMap()
        let inventory = (try? Data(contentsOf: staging.inventory)).flatMap { try? JSONDecoder().decode(MigrationInventory.self, from: $0) }
        map.add(plan: plan, inventory: inventory, layout: layout, sources: state.sources.map(\.path))
        map.save(layout)

        _ = git.commit(message: "Migration: \(result.skills) skills and \(result.notes) notes from existing agent memory",
                       trailers: ["Source": "migration", "Approved-by": "user"])
        return result
    }

    /// One archive of everything that was chosen, before anything else happens.
    private static func backUpSources(_ sources: [MigrationSource], into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // -h follows links, so an agent folder made of links is archived with what it points at.
        process.arguments = ["-czhf", folder.appendingPathComponent("sources.tar.gz").path, "-P"] + sources.map(\.path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Embarsy", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: L("Couldn't back up the sources, so nothing was changed.")])
        }
    }

    /// Copies a skill folder as real files: the base holds its own copy, not links back to
    /// the places it is replacing.
    private static func copyResolvingLinks(from: URL, to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: from.path) where name != ".DS_Store" {
            let src = from.appendingPathComponent(name).resolvingSymlinksInPath()
            let dst = to.appendingPathComponent(name)
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &dir) else { continue }
            if dir.boolValue { try copyResolvingLinks(from: src, to: dst) } else { try fm.copyItem(at: src, to: dst) }
        }
    }

    private static func fixName(in skillFile: URL, to name: String) throws {
        guard var text = try? String(contentsOf: skillFile, encoding: .utf8),
              text.hasPrefix("---"),
              let range = text.range(of: #"(?m)^name:.*$"#, options: .regularExpression) else { return }
        text.replaceSubrange(range, with: "name: \(name)")
        try text.write(to: skillFile, atomically: true, encoding: .utf8)
    }

    private static func markAdopted(_ skillFile: URL, date: String) throws {
        guard var text = try? String(contentsOf: skillFile, encoding: .utf8), text.hasPrefix("---\n"),
              !text.contains("embarsy-origin:") else { return }
        let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        guard let end else { return }
        let header = String(text[text.startIndex..<end.lowerBound])
        let addition = header.contains("\nmetadata:")
            ? "\n  embarsy-origin: adopted\n  embarsy-adopted-at: \"\(date)\""
            : "\nmetadata:\n  embarsy-origin: adopted\n  embarsy-adopted-at: \"\(date)\""
        if header.contains("\nmetadata:"), let meta = text.range(of: "\nmetadata:") {
            text.insert(contentsOf: addition, at: meta.upperBound)
        } else {
            text.insert(contentsOf: addition, at: end.lowerBound)
        }
        try text.write(to: skillFile, atomically: true, encoding: .utf8)
    }

    private static func lockEntry(name: String, folder: URL, layout: VaultLayout, skill: MigrationPlan.Skill,
                                  author: String?, date: String) -> String {
        var hasher = SHA256()
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath && $0.lastPathComponent != ".DS_Store" }
            .sorted { $0.path < $1.path }
        for file in files {
            hasher.update(data: Data(MemoryScanner.relativePath(of: file, in: folder).utf8))
            if let data = try? Data(contentsOf: file) { hasher.update(data: data) }
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let path = folder.path.replacingOccurrences(of: layout.skills.path + "/", with: "")
        return """
          \(name):
            path: \(path)
            source:
              kind: \(skill.from == nil ? "unknown" : "path")
              path: \(CoreFile.jsonString(skill.from ?? ""))
            author: \(CoreFile.jsonString(author ?? ""))
            tree_sha256: \(hash)
            installed_at: \(date)
            exposed_as: \(name)

        """
    }

    private static func noteFile(_ n: MigrationPlan.Note, body: String, date: String) -> String {
        // A note carried whole keeps its text; its own frontmatter, if any, gives way to ours.
        var text = body
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            text = String(text[end.upperBound...])
        }
        let type = n.type ?? (n.path.hasPrefix("experience/") ? "experience" : n.path.hasPrefix("people/") ? "person" : "knowledge")
        let title = n.title ?? URL(fileURLWithPath: n.path).deletingPathExtension().lastPathComponent
        var lines = ["---", "type: \(type)", "title: \(CoreFile.jsonString(title))", "created: \(date)", "updated: \(date)"]
        if let v = n.verified_at, !v.trimmed.isEmpty { lines.append("verified_at: \(v)") }
        lines.append("source:")
        lines.append("  kind: migration")
        let refs = (n.sources ?? [n.from].compactMap { $0 }).prefix(5)
        if !refs.isEmpty {
            lines.append("  refs:")
            for s in refs { lines.append("    - \(CoreFile.jsonString(s))") }
        }
        lines += ["status: active", "---", ""]
        return lines.joined(separator: "\n") + "\n" + text.trimmed + "\n"
    }
}
