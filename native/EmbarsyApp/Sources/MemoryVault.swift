import Foundation

// The memory base on disk (docs/memory-spec.md §5): plain markdown in a plain folder that
// works without Embarsy. This file knows its layout, reads and writes the core profile the
// Core tab edits, and builds the AGENTS.md every agent loads.

/// Where everything lives inside a base.
struct VaultLayout: Hashable {
    let root: URL

    var manifest: URL { root.appendingPathComponent("memory.yaml") }
    var agentsMd: URL { root.appendingPathComponent("AGENTS.md") }
    var core: URL { root.appendingPathComponent("core") }
    var coreMe: URL { core.appendingPathComponent("me.md") }
    var coreAgent: URL { core.appendingPathComponent("agent.md") }
    var coreRules: URL { core.appendingPathComponent("rules.md") }
    var skills: URL { root.appendingPathComponent("skills") }
    var ownSkills: URL { skills.appendingPathComponent("own") }
    var adoptedSkills: URL { skills.appendingPathComponent("adopted") }
    var vendorSkills: URL { skills.appendingPathComponent("vendor") }
    var vendorLock: URL { skills.appendingPathComponent("vendor.lock.yaml") }
    var knowledge: URL { root.appendingPathComponent("knowledge") }
    var experience: URL { root.appendingPathComponent("experience") }
    var people: URL { root.appendingPathComponent("people") }
    var inbox: URL { root.appendingPathComponent("inbox") }
    var archive: URL { root.appendingPathComponent("archive") }
    var service: URL { root.appendingPathComponent(".embarsy") }
    var exposureJournal: URL { service.appendingPathComponent("exposure.json") }
    var gitignore: URL { root.appendingPathComponent(".gitignore") }

    /// Folders created empty, so the shape of the base is visible from day one.
    var skeleton: [URL] {
        [core, ownSkills, adoptedSkills, vendorSkills, knowledge, experience, people,
         inbox.appendingPathComponent("claude"), inbox.appendingPathComponent("codex"),
         inbox.appendingPathComponent("roo"), inbox.appendingPathComponent("manual"),
         archive, service]
    }

    /// The path as agents should see it: `~/…` inside home, absolute elsewhere.
    func displayPath(home: URL) -> String {
        let path = root.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }
}

// MARK: - Core profile

/// Everything the Core form edits. Stored in core/*.md: the fields as frontmatter (each
/// value a JSON string literal, which is also valid YAML), the free-form notes as the body.
struct CoreProfile: Equatable {
    // core/me.md
    var userName = ""
    var role = ""
    var languages = ""
    var addressAs = ""
    var answerStyle = ""
    var aboutMe = ""

    // core/agent.md
    var agentName = ""
    var tone: Tone = .direct
    var aboutAgent = ""

    // core/rules.md
    var askBeforeChanges = true
    var browserOnlyOnRequest = true
    var noSecrets = true
    var separateFacts = true
    var customRules = ""

    enum Tone: String, CaseIterable, Identifiable {
        case direct, friendly, formal
        var id: String { rawValue }

        var label: String {
            switch self {
            case .direct: return L("Direct and concise")
            case .friendly: return L("Friendly and detailed")
            case .formal: return L("Formal")
            }
        }

        var instruction: String {
            switch self {
            case .direct: return "Be direct, technical and brief. Lead with the answer; skip pleasantries."
            case .friendly: return "Be warm and explain your reasoning. Prefer complete answers over terse ones."
            case .formal: return "Keep a formal, neutral tone. Be precise and structured."
            }
        }
    }

    var isComplete: Bool {
        !userName.trimmed.isEmpty && !agentName.trimmed.isEmpty
    }

    // MARK: Files

    func meFile() -> String {
        CoreFile.render(type: "core", fields: [
            ("title", "Who I am"),
            ("name", userName), ("role", role), ("languages", languages),
            ("address_as", addressAs), ("answer_style", answerStyle),
        ], body: aboutMe)
    }

    func agentFile() -> String {
        CoreFile.render(type: "core", fields: [
            ("title", "Who you are"),
            ("name", agentName), ("tone", tone.rawValue),
        ], body: aboutAgent)
    }

    func rulesFile() -> String {
        CoreFile.render(type: "core", fields: [
            ("title", "Rules"),
            ("ask_before_changes", askBeforeChanges), ("browser_only_on_request", browserOnlyOnRequest),
            ("no_secrets", noSecrets), ("separate_facts", separateFacts),
        ], body: customRules)
    }

    static func load(from layout: VaultLayout) -> CoreProfile {
        var profile = CoreProfile()
        if let me = CoreFile.parse(at: layout.coreMe) {
            profile.userName = me.string("name")
            profile.role = me.string("role")
            profile.languages = me.string("languages")
            profile.addressAs = me.string("address_as")
            profile.answerStyle = me.string("answer_style")
            profile.aboutMe = me.body
        }
        if let agent = CoreFile.parse(at: layout.coreAgent) {
            profile.agentName = agent.string("name")
            profile.tone = Tone(rawValue: agent.string("tone")) ?? .direct
            profile.aboutAgent = agent.body
        }
        if let rules = CoreFile.parse(at: layout.coreRules) {
            profile.askBeforeChanges = rules.bool("ask_before_changes", default: true)
            profile.browserOnlyOnRequest = rules.bool("browser_only_on_request", default: true)
            profile.noSecrets = rules.bool("no_secrets", default: true)
            profile.separateFacts = rules.bool("separate_facts", default: true)
            profile.customRules = rules.body
        }
        return profile
    }

    func write(to layout: VaultLayout) throws {
        try FileManager.default.createDirectory(at: layout.core, withIntermediateDirectories: true)
        try meFile().write(to: layout.coreMe, atomically: true, encoding: .utf8)
        try agentFile().write(to: layout.coreAgent, atomically: true, encoding: .utf8)
        try rulesFile().write(to: layout.coreRules, atomically: true, encoding: .utf8)
    }
}

/// A core/*.md file: flat frontmatter of strings and booleans, then a markdown body.
struct CoreFile {
    var fields: [String: String] = [:]
    var body = ""

    func string(_ key: String) -> String { fields[key] ?? "" }

    func bool(_ key: String, default value: Bool) -> Bool {
        switch fields[key] {
        case "true": return true
        case "false": return false
        default: return value
        }
    }

    static func render(type: String, fields: [(String, Any)], body: String) -> String {
        var lines = ["---", "type: \(type)"]
        for (key, value) in fields {
            if let flag = value as? Bool {
                lines.append("\(key): \(flag ? "true" : "false")")
            } else {
                lines.append("\(key): \(jsonString(String(describing: value)))")
            }
        }
        lines.append("---")
        let trimmed = body.trimmed
        return lines.joined(separator: "\n") + "\n" + (trimmed.isEmpty ? "" : "\n" + trimmed + "\n")
    }

    static func parse(at url: URL) -> CoreFile? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> CoreFile {
        var file = CoreFile()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            file.body = text.trimmed
            return file
        }
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""),
               let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                file.fields[key] = decoded
            } else {
                file.fields[key] = raw
            }
        }
        file.body = lines[(end + 1)...].joined(separator: "\n").trimmed
        return file
    }

    static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }
}

// MARK: - AGENTS.md

enum AgentsMdBuilder {
    static let header = "<!-- Generated by Embarsy from core/*.md. Edit those files, or Memory → Core in Embarsy — changes here are overwritten. -->"
    /// Everything in the core must fit here; it is loaded into every session of every agent.
    static let budgetBytes = 4 * 1024

    static func build(profile p: CoreProfile, vaultPath: String) -> String {
        var out: [String] = [header, ""]
        out.append("# Working with \(p.userName.trimmed.isEmpty ? "me" : p.userName.trimmed)")
        out.append("")

        out.append("## Who I am")
        out.append("")
        let me: [(String, String)] = [
            ("Name", p.userName), ("Role", p.role), ("Languages", p.languages),
            ("Address me as", p.addressAs), ("Answer style", p.answerStyle),
        ]
        for (label, value) in me where !value.trimmed.isEmpty {
            out.append("- \(label): \(value.trimmed)")
        }
        if !p.aboutMe.trimmed.isEmpty { out += ["", p.aboutMe.trimmed] }
        out.append("")

        out.append("## Who you are")
        out.append("")
        let name = p.agentName.trimmed
        out.append((name.isEmpty ? "" : "You are \(name). ") + p.tone.instruction)
        if !p.aboutAgent.trimmed.isEmpty { out += ["", p.aboutAgent.trimmed] }
        out.append("")

        var rules: [String] = []
        if p.askBeforeChanges {
            rules.append("Ask me before any action that changes something — writing, deleting, sending, publishing — unless I asked for exactly that. Reading needs no permission.")
        }
        if p.browserOnlyOnRequest {
            rules.append("Use the browser or control the computer's interface only when I ask for it in the current task. Permission from an earlier task doesn't carry over.")
        }
        if p.noSecrets {
            rules.append("Never store, repeat or write down passwords, tokens or keys.")
        }
        if p.separateFacts {
            rules.append("Keep what I told you, what you verified and what you infer apart, and say which is which.")
        }
        let custom = p.customRules.components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty }
        rules += custom.map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
        if !rules.isEmpty {
            out.append("## Rules")
            out.append("")
            out += rules.map { "- \($0)" }
            out.append("")
        }

        out.append("## Memory")
        out.append("")
        out.append("Your long-term memory is the folder \(vaultPath), shared by every agent I use.")
        out.append("- Before answering anything that depends on earlier sessions or on my own context, use the `recall` tool. Without it, search knowledge/, experience/ and people/ there.")
        out.append("- To remember something, use the `remember` tool — only when I asked or agreed. Without it, write a note to inbox/ as the `embarsy-memory` skill describes. I review the inbox in Embarsy.")
        out.append("- Don't edit core/, skills/, knowledge/ or experience/ directly.")
        out.append("")
        return out.joined(separator: "\n")
    }
}

// MARK: - Manifest

struct MemoryManifest: Equatable {
    static let formatVersion = 1

    var owner = ""
    var agents: [MemoryAgent] = MemoryAgent.allCases
    var created = ""

    func render() -> String {
        """
        # Embarsy memory base. Read by Embarsy; safe to read, edit with care.
        format: \(Self.formatVersion)
        owner: \(CoreFile.jsonString(owner))
        agents: [\(agents.map(\.rawValue).joined(separator: ", "))]
        created: \(created)

        """
    }

    static func load(at url: URL) -> MemoryManifest? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("format:") else { return nil }
        var manifest = MemoryManifest()
        for line in text.components(separatedBy: "\n") {
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "owner": manifest.owner = CoreFile.parse("---\nowner: \(value)\n---").string("owner")
            case "created": manifest.created = value
            case "agents":
                manifest.agents = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",")
                    .compactMap { MemoryAgent(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            default: break
            }
        }
        return manifest
    }
}

// MARK: - Creating a base

enum VaultCreator {
    enum CreateError: LocalizedError {
        case notEmpty(String)
        case hasSpace(String)

        var errorDescription: String? {
            switch self {
            case .notEmpty(let path): return L("\(path) already has files in it. Choose an empty or new folder.")
            case .hasSpace(let path): return L("\(path) has a space in its path. Agents' instruction imports break on spaces — choose a path without them.")
            }
        }
    }

    /// Checks a candidate folder before anything is written.
    static func validate(_ root: URL) -> CreateError? {
        let path = root.standardizedFileURL.path
        if path.contains(" ") { return .hasSpace(path) }
        let contents = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { $0 != ".DS_Store" }
        if !contents.isEmpty { return .notEmpty(path) }
        return nil
    }

    /// Writes a fresh base. Throws before writing anything if the folder isn't usable.
    static func create(at root: URL, profile: CoreProfile, agents: [MemoryAgent], home: URL, today: Date = Date()) throws -> VaultLayout {
        if let problem = validate(root) { throw problem }
        let fm = FileManager.default
        let layout = VaultLayout(root: root.standardizedFileURL)
        for folder in [layout.root] + layout.skeleton {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let date = ISO8601DateFormatter.dateOnly.string(from: today)
        let manifest = MemoryManifest(owner: profile.userName.trimmed, agents: agents, created: date)
        try manifest.render().write(to: layout.manifest, atomically: true, encoding: .utf8)
        try profile.write(to: layout)
        try writeAgentsMd(layout: layout, profile: profile, home: home)
        try "version: 1\nskills: {}\n".write(to: layout.vendorLock, atomically: true, encoding: .utf8)
        try ".embarsy/\n.DS_Store\n".write(to: layout.gitignore, atomically: true, encoding: .utf8)

        let skill = layout.ownSkills.appendingPathComponent("embarsy-memory")
        try fm.createDirectory(at: skill, withIntermediateDirectories: true)
        try starterSkill(vaultPath: layout.displayPath(home: home))
            .write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return layout
    }

    static func writeAgentsMd(layout: VaultLayout, profile: CoreProfile, home: URL) throws {
        let text = AgentsMdBuilder.build(profile: profile, vaultPath: layout.displayPath(home: home))
        try text.write(to: layout.agentsMd, atomically: true, encoding: .utf8)
    }

    /// The one skill every base starts with: how to use the base itself.
    static func starterSkill(vaultPath: String) -> String {
        """
        ---
        name: embarsy-memory
        description: Use when the user asks you to remember something, asks what you know about them, their projects or earlier work, or when a task needs knowledge from past sessions. Explains where the long-term memory lives, how to look things up in it and how to propose a new memory.
        metadata:
          embarsy-origin: own
        ---

        # Embarsy memory

        The memory base is the folder `\(vaultPath)`. Embarsy keeps it in order; the user reviews changes in Embarsy → Memory.

        ## Look things up

        - Use the `recall` tool first: it searches the whole base by meaning and says which note each passage comes from.
        - Without the tool, search the folder yourself:
          - `knowledge/<topic>/` — facts by subject.
          - `experience/<year>/` — work that was done and verified, one note per piece of work.
          - `people/` — people the user works with.
        - Check `verified_at` in a note's frontmatter before relying on it for code: code changes.
        - `memory_history` tells who changed a note and when — use it when a fact looks wrong.

        ## Propose a memory

        Only when the user asked you to remember something, or agreed when you offered.

        - Use the `remember` tool: one fact per call, with the reason you think it's worth keeping.
        - Without the tool, write one fact per file to `inbox/<agent>/<YYYY-MM-DD-HHMM>-<short-slug>.md`, where `<agent>` is `claude`, `codex` or `roo`, with this frontmatter and then the fact in plain words:

          ```yaml
          ---
          type: inbox
          created: 2026-01-31T14:02
          agent: codex
          proposed_type: knowledge   # knowledge | experience | person | core
          reason: "why this is worth keeping, and how you know it"
          confidence: observed       # stated (the user said it) | observed (you verified it) | inferred
          ---
          ```

        - Tell the user the proposal is in the inbox.

        ## Never

        - Never write to `core/`, `skills/`, `knowledge/`, `experience/` or `people/` directly — only to `inbox/`.
        - Never put passwords, tokens or keys in any note.
        """
    }

    /// The first version, kept so a base created with it can be upgraded — but only while
    /// its copy is still exactly what Embarsy wrote.
    static func starterSkillV1(vaultPath: String) -> String {
        """
        ---
        name: embarsy-memory
        description: Use when the user asks you to remember something, asks what you know about them, their projects or earlier work, or when a task needs knowledge from past sessions. Explains where the long-term memory lives, how to look things up in it and how to propose a new memory.
        metadata:
          embarsy-origin: own
        ---

        # Embarsy memory

        The memory base is the folder `\(vaultPath)`. Embarsy keeps it in order; the user reviews changes in Embarsy → Memory.

        ## Look things up

        - `knowledge/<topic>/` — facts by subject.
        - `experience/<year>/` — work that was done and verified, one note per piece of work.
        - `people/` — people the user works with.
        - Search with grep or rg across the base; notes link to each other with relative links.
        - Check `verified_at` in a note's frontmatter before relying on it for code: code changes.

        ## Propose a memory

        Only when the user asked you to remember something, or agreed when you offered.

        1. Write one fact per file to `inbox/<agent>/<YYYY-MM-DD-HHMM>-<short-slug>.md`, where `<agent>` is `claude`, `codex` or `roo`.
        2. Use this frontmatter, then the fact itself in plain words:

           ```yaml
           ---
           type: inbox
           created: 2026-01-31T14:02
           agent: codex
           proposed_type: knowledge   # knowledge | experience | person | core
           reason: "why this is worth keeping, and how you know it"
           confidence: observed       # stated (the user said it) | observed (you verified it) | inferred
           ---
           ```

        3. Tell the user the note is in the inbox.

        ## Never

        - Never write to `core/`, `skills/`, `knowledge/`, `experience/` or `people/` directly — only to `inbox/`.
        - Never put passwords, tokens or keys in any note.
        """
    }
}

extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return formatter
    }()
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
