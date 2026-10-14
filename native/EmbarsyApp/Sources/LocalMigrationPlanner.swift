import Foundation

/// "Bring existing memory" without a cloud agent (docs/memory-spec.md §10, tier 3): the local
/// model writes the same plan.json the agent would, and the user reviews it the same way.
///
/// The model gets only small questions — what kind of skill is this, where does this file go,
/// condense these files into a core — and everything that needs no judgement is decided here:
/// copies of project skills, journal entries (already split), exact duplicates, possible
/// secrets, and the paths notes land at.
@MainActor
struct LocalMigrationPlanner {
    typealias Ask = (_ system: String, _ user: String, _ schema: [String: Any], _ think: Bool, _ numCtx: Int) async throws -> String
    typealias Progress = (_ done: Int, _ total: Int, _ what: String) -> Void

    let session: MigrationSession
    let ask: Ask
    var progress: Progress = { _, _, _ in }

    /// Longest slice of one file the model reads. Notes past it are still moved whole; the model
    /// only needs enough to tell what the file is.
    private static let excerpt = 6000

    func plan() async throws -> MigrationPlan {
        let inv = session.inventory
        let secretPaths = Set(inv.secrets.compactMap { $0.components(separatedBy: ": looks like").first })
        let journalSources = Set(inv.experienceEntries.map { Self.resolved($0.from) })

        var skills: [MigrationPlan.Skill] = []
        var notes: [MigrationPlan.Note] = []
        var skip: [MigrationPlan.Skip] = []
        var questions: [MigrationPlan.Question] = []
        var coreTexts: [(path: String, text: String)] = []
        var ruleCandidates: [(rule: String, source: String)] = []

        /// Files the model sorts, with what is known about where each came from.
        var queue: [(path: String, hint: String, referencesRoot: String?, mayBeProcedure: Bool)] = []

        // Grows once the skills are sorted: an index skill's files join the queue.
        var total = inv.skills.count + inv.claudeMemories.count + inv.otherNotes.count + 2
        var done = 0
        func step(_ what: String) { done += 1; progress(min(done, total), total, what) }

        // MARK: Skills
        for skill in inv.skills {
            try Task.checkCancellation()
            step(L("Skill \(skill.name)"))
            if skill.looksLikeProjectCopy {
                for copy in skill.copies {
                    skip.append(.init(source: copy.path, reason: L("Copy of a project's own skill — project skills stay in their repository.")))
                }
                continue
            }
            // Of copies that differ, the one whose SKILL.md was edited last is read (a folder's
            // own date moves with any file in it); identical copies are one skill.
            let newest = Self.newestCopy(skill.copies)
            let skillMd = Self.read(newest.resolved + "/SKILL.md")
            let refs = MigrationScanner.referenceFiles(in: URL(fileURLWithPath: newest.resolved))
            let kind: SkillKind
            do {
                kind = try await skillKind(name: skill.name, text: skillMd, refs: refs.map { Self.relative($0, to: newest.resolved) })
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keeping a skill is the safe default: the review shows it and it can be unticked.
                kind = SkillKind(kind: "procedure", reason: L("The local model couldn't decide what this skill is — check it."))
            }

            if kind.kind == "persona" || kind.kind == "index" {
                // Persona and memory-rule skills are what the core is distilled from; their
                // files still move as notes too.
                coreTexts.append((newest.resolved + "/SKILL.md", "[\(kind.kind) skill \"\(skill.name)\"]\n" + skillMd))
                if kind.kind == "persona" {
                    for ref in refs { coreTexts.append((ref, "[file of the persona skill \"\(skill.name)\"]\n" + Self.read(ref))) }
                }
            }
            switch kind.kind {
            case "procedure":
                let origin = Self.origin(author: skill.author, owner: inv.owner)
                let versions = Dictionary(grouping: skill.copies, by: \.version)
                if versions.count > 1 {
                    let choice = "skill-" + skill.name
                    for (_, copies) in versions.sorted(by: { $0.key < $1.key }) {
                        let copy = copies.max { $0.modified < $1.modified }!
                        skills.append(.init(name: skill.name, origin: origin.origin, vendor_source: origin.vendorSource,
                                            from: copy.resolved, sources: copies.map(\.path),
                                            reason: L("Version \(copy.version), changed \(String(copy.modified.prefix(10))), at \(copy.path)."),
                                            choice: choice))
                    }
                    questions.append(.init(choice: choice, question: L("The copies of \(skill.name) differ. Which one should stay?")))
                } else {
                    skills.append(.init(name: skill.name, origin: origin.origin, vendor_source: origin.vendorSource,
                                        from: newest.resolved, sources: skill.copies.map(\.path), reason: kind.reason))
                }
            default:
                for copy in skill.copies { skip.append(.init(source: copy.path, reason: kind.reason)) }
                // An index or persona skill's reference files are the knowledge it pointed at.
                if kind.kind != "example" {
                    for ref in refs {
                        queue.append((ref, "a reference file of the skill \"\(skill.name)\" (\(kind.kind))", newest.resolved + "/references", true))
                    }
                }
            }
        }

        // MARK: Notes
        for file in inv.instructions { coreTexts.append((file.path, Self.read(file.path))) }
        // A memory records a fact or a piece of feedback; it is never a whole procedure.
        queue += inv.claudeMemories.map { ($0.path, "a Claude Code memory from " + Self.projectLabel($0.source), nil, false) }
        queue += inv.otherNotes.map { ($0.path, "a file in " + $0.source, nil, true) }

        total = done + queue.count + 2
        var seenText: [String: String] = [:]
        var taken = Set<String>()
        var topics: [String] = []
        for item in queue {
            try Task.checkCancellation()
            step(URL(fileURLWithPath: item.path).lastPathComponent)
            if secretPaths.contains(item.path) {
                skip.append(.init(source: item.path, reason: L("Looks like it holds a secret — secrets never move into memory.")))
                continue
            }
            if journalSources.contains(Self.resolved(item.path)) {
                skip.append(.init(source: item.path, reason: L("A journal: its entries were split and move one by one into experience/.")))
                continue
            }
            let text = Self.read(item.path)
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                skip.append(.init(source: item.path, reason: L("Empty.")))
                continue
            }
            if let first = seenText[body] {
                skip.append(.init(source: item.path, reason: L("Same text as \(first).")))
                continue
            }
            seenText[body] = item.path

            let sorted: Sorted
            do {
                sorted = try await sortFile(path: item.path, hint: item.hint, text: text, topics: topics, mayBeProcedure: item.mayBeProcedure)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let name = URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent
                sorted = Sorted(type: "knowledge", topic: "unsorted", file_name: name, title: name, rule: "", skill_name: "",
                                description: "", reason: L("The local model couldn't decide where this goes — check it."))
            }
            switch sorted.type {
            case "procedure":
                let name = Self.skillName(sorted.skill_name.isEmpty ? sorted.file_name : sorted.skill_name)
                let md = "---\nname: \(name)\ndescription: \(Self.yamlQuoted(sorted.description))\n---\n\n" + MarkdownRenderer.split(text).body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                skills.append(.init(name: name, origin: "own", skill_md: md, sources: [item.path], reason: sorted.reason))
            case "skip":
                skip.append(.init(source: item.path, reason: sorted.reason))
            default:
                // A rule is offered to the core as one line, and its file stays a note: the
                // core keeps only rules that hold everywhere, and the note keeps the "why".
                if sorted.type == "rule" {
                    ruleCandidates.append((sorted.rule.isEmpty ? sorted.title : sorted.rule, item.path))
                }
                var path: String
                switch sorted.type {
                case "person":
                    path = "people/\(Self.fileName(sorted.title.isEmpty ? sorted.file_name : sorted.title)).md"
                case "experience":
                    path = "experience/\(Self.year(of: item.path, text: text))/\(Self.slug(sorted.file_name)).md"
                default:
                    if let root = item.referencesRoot, item.path.hasPrefix(root + "/") {
                        // Knowledge a skill already arranged in folders keeps that arrangement.
                        path = "knowledge/" + String(item.path.dropFirst(root.count + 1))
                    } else {
                        let topic = Self.slug(sorted.topic.isEmpty ? "general" : sorted.topic)
                        if !topics.contains(topic) { topics.append(topic) }
                        path = "knowledge/\(topic)/\(Self.slug(sorted.file_name)).md"
                    }
                }
                path = Self.unique(path, taken: &taken)
                notes.append(.init(path: path, type: sorted.type == "rule" ? "knowledge" : sorted.type,
                                   title: sorted.title, from: item.path, sources: [item.path], reason: sorted.reason))
            }
        }

        // Journal entries were split by Embarsy; they are experience by construction.
        for entry in inv.experienceEntries {
            let name = URL(fileURLWithPath: entry.file).lastPathComponent
            let path = Self.unique("experience/\(entry.date.prefix(4))/\(name)", taken: &taken)
            notes.append(.init(path: path, type: "experience", title: entry.title, from: entry.file,
                               sources: [entry.from], reason: L("An entry of the journal \(URL(fileURLWithPath: entry.from).lastPathComponent).")))
        }

        // MARK: Core
        try Task.checkCancellation()
        step(L("Core"))
        let core = try await distillCore(texts: coreTexts, rules: ruleCandidates)
        step(L("Done"))

        let differing = questions.count
        var summary = L("Planned by the local model: \(skills.filter { $0.choice == nil }.count) skills, \(notes.count) notes, \(core.custom_rules?.count ?? 0) rules in the core, \(skip.count) items left behind.")
        if differing > 0 { summary += " " + L("\(differing) skills have copies that differ — choose which to keep.") }
        summary += " " + L("Check where notes go and the core's wording: a local model is a first draft.")
        return MigrationPlan(version: 1, summary: summary, core: core, skills: skills, notes: notes, skip: skip, questions: questions)
    }

    // MARK: Questions to the model

    private struct SkillKind: Decodable { let kind: String; let reason: String }

    private func skillKind(name: String, text: String, refs: [String]) async throws -> SkillKind {
        let system = """
        You sort Agent Skills (folders with SKILL.md) while moving a user's agent memory into a new memory base.
        Decide what this skill is:
        - procedure: it teaches how to do a real task (testing, writing, a tool, a workflow). It moves as a skill.
        - index: it mostly routes to other files (an index of knowledge, abilities, memory rules) or tells the agent what to load first. Its files move as notes; the skill itself doesn't.
        - persona: it describes who the user is, who the agent is, its character or social rules. That goes into the always-loaded core profile.
        - example: a template or sample with no real use.
        Write `reason` as one short sentence in \(AppLanguage.modelInstruction) — the person reads it in Embarsy.
        """
        let user = "Skill folder name: \(name)\nOther files in the folder: \(refs.isEmpty ? "none" : refs.prefix(40).joined(separator: ", "))\n\nSKILL.md:\n\(text.prefix(Self.excerpt))"
        let schema: [String: Any] = ["type": "object", "required": ["kind", "reason"], "properties": [
            "kind": ["type": "string", "enum": ["procedure", "index", "persona", "example"]],
            "reason": ["type": "string"],
        ]]
        return try decode(await ask(system, user, schema, false, 16384))
    }

    private struct Sorted: Decodable {
        let type: String
        let topic: String
        let file_name: String
        let title: String
        let rule: String
        let skill_name: String
        let description: String
        let reason: String
    }

    private func sortFile(path: String, hint: String, text: String, topics: [String], mayBeProcedure: Bool) async throws -> Sorted {
        let system = """
        You sort one file from a user's old agent memory into a new memory base. Types:
        - knowledge: durable facts about products, systems, tools, setups — things to look up later.
        - experience: one dated episode — what happened, what was done, the lesson.
        - person: a note about a person.
        - rule: a standing instruction from the user about how the agent must behave in ALL work, whatever the project ("never commit", "screenshots only of windows"). Memories marked `type: feedback` often are. Feedback about one app's or project's design stays knowledge. A rule goes into the always-loaded core as one line; give that line in `rule`.
        \(mayBeProcedure ? "- procedure: a complete step-by-step guide for a recurring task, written as instructions to follow. It becomes a skill; give `skill_name` (lowercase, hyphens) and `description` (when to use it, one sentence). Facts about how something works, or a fix that was found once, are knowledge, not a procedure." : "")
        - skip: only when the file is empty, a bare list of links to other files with no facts of its own, or a template. Overviews, open questions and source lists are knowledge.
        `topic` (knowledge only): one short lowercase word or two with hyphens; reuse an existing topic when it fits.
        `file_name`: short, lowercase, hyphens, no extension.
        Write `title`, `rule` and `description` in the language of the file — they go into the memory. Write `reason` as one short sentence in \(AppLanguage.modelInstruction) — the person reads it in Embarsy.
        """
        let user = """
        Existing topics: \(topics.isEmpty ? "none yet" : topics.joined(separator: ", "))
        Where it's from: \(hint)
        Path: \(path)

        \(text.prefix(Self.excerpt))
        """
        let schema: [String: Any] = ["type": "object",
            "required": ["type", "topic", "file_name", "title", "rule", "skill_name", "description", "reason"],
            "properties": [
                "type": ["type": "string", "enum": ["knowledge", "experience", "person", "rule"] + (mayBeProcedure ? ["procedure"] : []) + ["skip"]],
                "topic": ["type": "string"], "file_name": ["type": "string"], "title": ["type": "string"],
                "rule": ["type": "string"], "skill_name": ["type": "string"], "description": ["type": "string"],
                "reason": ["type": "string"],
            ]]
        return try decode(await ask(system, user, schema, false, 16384))
    }

    private func distillCore(texts: [(path: String, text: String)], rules: [(rule: String, source: String)]) async throws -> MigrationPlan.Core {
        let system = """
        You write the core profile of a user's memory base: who the user is, who their AI agent is, and the user's standing rules. Every agent loads it in every session, so keep it short — all fields together under 3000 characters.
        Take facts only from the material given; leave a field empty when the material doesn't say.
        The user's name, role and how to address them are usually in a file about a person or in a persona skill; the agent's name and character in the persona skills.
        `tone` is how the user wants to be answered: direct (brief, to the point), friendly, or formal.
        Drop routing boilerplate ("ALWAYS load X first"), quality-gate repetition, and anything a validator can check.
        `custom_rules`: at most 12 one-line rules, each a standing instruction that holds in ALL of the user's work. Leave out rules about one project's or app's design or behaviour — they stay in that project's notes. No duplicates of each other and none that repeat the four standard rules (ask before changes, browser only on request, no secrets, separate facts from guesses).
        Write every field in the main language of the material, translating rules written in another language.
        """
        var budget = 40_000
        var parts: [String] = []
        for item in texts {
            let slice = String(item.text.prefix(min(Self.excerpt, max(0, budget))))
            guard !slice.isEmpty else { break }
            budget -= slice.count
            parts.append("### \(item.path)\n\(slice)")
        }
        if !rules.isEmpty {
            parts.append("### Rules found in the agent's memories\n" + rules.map { "- \($0.rule)" }.joined(separator: "\n"))
        }
        let string = ["type": "string"]
        let schema: [String: Any] = ["type": "object",
            "required": ["user_name", "role", "languages", "address_as", "answer_style", "about_me", "agent_name", "tone", "about_agent", "custom_rules", "reason"],
            "properties": [
                "user_name": string, "role": string, "languages": string, "address_as": string,
                "answer_style": string, "about_me": string, "agent_name": string,
                "tone": ["type": "string", "enum": ["direct", "friendly", "formal"]],
                "about_agent": string, "custom_rules": ["type": "array", "items": string], "reason": string,
            ]]
        let user = parts.isEmpty ? "No material was found." : parts.joined(separator: "\n\n")
        var core: MigrationPlan.Core = try decode(await ask(system, user, schema, true, 32768))
        // The budget is a promise to every agent's context; the model's count isn't trusted.
        var rulesKept: [String] = []
        var size = [core.user_name, core.role, core.languages, core.address_as, core.answer_style, core.about_me,
                    core.agent_name, core.about_agent].compactMap { $0?.count }.reduce(0, +)
        for rule in core.custom_rules ?? [] where size + rule.count <= 3000 && rulesKept.count < 12 {
            rulesKept.append(rule)
            size += rule.count
        }
        core.custom_rules = rulesKept
        core.ask_before_changes = true
        core.browser_only_on_request = true
        core.no_secrets = true
        core.separate_facts = true
        core.sources = texts.map(\.path) + rules.map(\.source)
        return core
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw LocalModelService.ModelError.failed(L("The local model's answer was missing a field: \(String(json.prefix(200)))"))
        }
    }

    // MARK: Helpers

    /// The copy whose SKILL.md changed last; on a tie, the longer one.
    static func newestCopy(_ copies: [MigrationInventory.Copy]) -> MigrationInventory.Copy {
        func stamp(_ c: MigrationInventory.Copy) -> (Date, Int) {
            let path = c.resolved + "/SKILL.md"
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            return ((attrs?[.modificationDate] as? Date) ?? .distantPast, (attrs?[.size] as? Int) ?? 0)
        }
        return copies.max { a, b in
            let (da, sa) = stamp(a), (db, sb) = stamp(b)
            return da == db ? sa < sb : da < db
        } ?? copies[0]
    }

    static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    static func projectLabel(_ source: String) -> String {
        let folder = URL(fileURLWithPath: source).deletingLastPathComponent().lastPathComponent
        return "the project " + MigrationSources.projectLabel(folder)
    }

    /// Someone else's skill when it names an author who isn't this Mac's user.
    static func origin(author: String?, owner: String) -> (origin: String, vendorSource: String?) {
        guard let author = author?.trimmingCharacters(in: .whitespaces), !author.isEmpty else { return ("own", nil) }
        let me = [owner, NSUserName(), NSFullUserName()].map { $0.lowercased() }
        return me.contains(author.lowercased()) ? ("own", nil) : ("vendor", "author: \(author)")
    }

    static func slug(_ text: String) -> String {
        let s = MemoryInbox.slug(text)
        return s.isEmpty ? "note" : s
    }

    static func skillName(_ text: String) -> String {
        let lowered = text.lowercased().precomposedStringWithCanonicalMapping
        var out = ""
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "imported-skill" : String(trimmed.prefix(64))
    }

    /// A person's name as a file name: kept as written, minus characters a path can't hold.
    static func fileName(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/:\\\n")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "person" : cleaned
    }

    static func yamlQuoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// The year an episode belongs to: a date in its name or text, else when the file changed.
    static func year(of path: String, text: String) -> String {
        let candidates = [URL(fileURLWithPath: path).lastPathComponent, String(text.prefix(2000))]
        for c in candidates {
            if let r = c.range(of: #"20\d\d-\d\d-\d\d"#, options: .regularExpression) { return String(c[r].prefix(4)) }
        }
        let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        return String(Calendar(identifier: .gregorian).component(.year, from: date))
    }

    static func unique(_ path: String, taken: inout Set<String>) -> String {
        var candidate = path
        var n = 2
        while taken.contains(candidate) {
            let base = (path as NSString).deletingPathExtension
            candidate = "\(base)-\(n).md"
            n += 1
        }
        taken.insert(candidate)
        return candidate
    }
}
