import Foundation

/// What a Health finding offers besides fixing files: a place in Embarsy to go to.
enum HealthAction: Hashable {
    case openInbox
    case openKnowledge

    var title: String {
        switch self {
        case .openInbox: return L("Open Inbox")
        case .openKnowledge: return L("Open Knowledge")
        }
    }

    var tab: MemoryTab {
        switch self {
        case .openInbox: return .inbox
        case .openKnowledge: return .knowledge
        }
    }
}

/// A finding the local model can help with: it writes a draft, the person decides.
enum HealthAssist: Hashable {
    /// H06 — the profile, condensed under its budget.
    case shortenCore
    /// H01 — a description over Zoo / Roo's 1024 characters, shortened.
    case shortenDescription(file: URL, skill: String)
    /// H02 — copies that drifted apart: what differs, and which to keep.
    case compareCopies(skill: String, copies: [URL])
    /// H03 — a name Codex already uses for a bundled skill: other names to pick from.
    case suggestNames(skill: String, file: URL)
}

/// The assistant's answer to one finding.
struct AssistResult: Equatable {
    var text: String
    /// A ready change, applied with one button after the person reads it.
    var fix: HealthFix?
    /// A profile to save instead (H06), with the sizes before and after.
    var profile: CoreProfile?
    var sizes: (before: Int, after: Int)?
    /// Several ready changes to pick one from (H02: keep this copy).
    var choices: [(label: String, fix: HealthFix)] = []

    static func == (a: AssistResult, b: AssistResult) -> Bool {
        a.text == b.text && a.fix == b.fix && a.profile == b.profile && a.choices.map(\.label) == b.choices.map(\.label)
    }
}

enum AssistState: Equatable {
    case working
    case done(AssistResult)
    case failed(String)
}

/// The questions and the parsing for each kind of help. The model only drafts; every change
/// still goes through a HealthFix or the profile's own save, with the history behind it.
enum HealthAssistant {
    typealias Ask = (_ system: String, _ user: String, _ schema: [String: Any], _ numCtx: Int) async throws -> String

    private static func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: H06

    private struct CoreDraft: Decodable {
        let role: String
        let about_me: String
        let about_agent: String
        let custom_rules: [String]
    }

    static func shortenCore(_ profile: CoreProfile, vault: VaultLayout, ask: Ask) async throws -> AssistResult {
        let size = { (p: CoreProfile) in AgentsMdBuilder.build(profile: p, vaultPath: vault.root.path).utf8.count }
        let before = size(profile)
        let rules = profile.customRules.components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty }
        let system = """
        You shorten the profile an AI agent loads at the start of every session. It must fit in about \(AgentsMdBuilder.budgetBytes - 600) bytes of UTF-8 together with fields you don't touch.
        Keep every standing rule's meaning; merge rules that say the same thing; drop examples, repetition and anything an agent can look up elsewhere. Keep facts about the person that change how to work with them.
        Write in the language each field is written in. Return the same fields, shortened.
        """
        let user = """
        role: \(profile.role)
        about_me: \(profile.aboutMe)
        about_agent: \(profile.aboutAgent)
        custom_rules:
        \(rules.map { "- " + $0 }.joined(separator: "\n"))
        """
        let schema: [String: Any] = ["type": "object", "required": ["role", "about_me", "about_agent", "custom_rules"],
            "properties": ["role": ["type": "string"], "about_me": ["type": "string"], "about_agent": ["type": "string"],
                           "custom_rules": ["type": "array", "items": ["type": "string"]]]]
        var draft = profile
        for attempt in 0..<2 {
            let prompt = attempt == 0 ? user : user + "\n\nThe previous draft was still too long. Cut harder."
            let d: CoreDraft = try decode(try await ask(system, prompt, schema, 16384))
            draft.role = d.role
            draft.aboutMe = d.about_me
            draft.aboutAgent = d.about_agent
            draft.customRules = d.custom_rules.map(\.trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
            if size(draft) <= AgentsMdBuilder.budgetBytes { break }
        }
        let after = size(draft)
        let text = after <= AgentsMdBuilder.budgetBytes
            ? L("A shorter profile: \(before / 1024) KB → \(after / 1024) KB. Read it below; nothing changes until you use it.")
            : L("The assistant couldn't get the profile under 4 KB (\(after / 1024) KB). You can still use the draft and shorten the rest yourself in Memory → Core.")
        return AssistResult(text: text, profile: draft, sizes: (before, after))
    }

    // MARK: H01 — long description

    private struct Description: Decodable { let description: String }

    static func shortenDescription(file: URL, skill: String, ask: Ask) async throws -> AssistResult {
        let fm = MemoryScanner.parseFrontmatter((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        let description = fm.description ?? ""
        let system = """
        You shorten the description of an Agent Skill. Agents read only the description to decide when to use the skill, so keep what says WHEN to use it (triggers, situations, key words) and drop how it works. At most 900 characters. Write in the language of the original.
        """
        let schema: [String: Any] = ["type": "object", "required": ["description"], "properties": ["description": ["type": "string"]]]
        var short = ""
        for _ in 0..<2 {
            let d: Description = try decode(try await ask(system, "Skill: \(skill)\n\nDescription:\n\(description)", schema, 8192))
            short = d.description.trimmed
            if short.utf16.count <= 1024 { break }
        }
        guard !short.isEmpty, short.utf16.count <= 1024 else {
            throw LocalModelService.ModelError.failed(L("The assistant couldn't fit the description into 1024 characters."))
        }
        return AssistResult(text: L("Shortened from \(description.utf16.count) to \(short.utf16.count) characters:") + "\n\n" + short,
                            fix: .setDescription(file: file, text: short))
    }

    // MARK: H02 — drifted copies

    private struct Comparison: Decodable {
        let differences: String
        let recommended: Int
        let reason: String
    }

    static func compareCopies(skill: String, copies: [URL], vault: VaultLayout?, ask: Ask) async throws -> AssistResult {
        let shown = Array(copies.prefix(3))
        var parts: [String] = []
        for (i, copy) in shown.enumerated() {
            let text = (try? String(contentsOf: copy.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
            let changed = (try? copy.appendingPathComponent("SKILL.md").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            parts.append("### Copy \(i + 1) — \(MemoryScanner.tilde(copy))\(changed.map { ", changed " + ISO8601DateFormatter.dateOnly.string(from: $0) } ?? "")\n\(text.prefix(6000))")
        }
        let system = """
        You compare copies of one Agent Skill that have drifted apart. Say briefly what each copy has that the others don't (rules, steps, links), then recommend the copy to keep — usually the most complete and correct, not simply the newest.
        `differences` and `reason`: short, in \(AppLanguage.modelInstruction). `recommended`: the copy number, starting at 1.
        """
        let schema: [String: Any] = ["type": "object", "required": ["differences", "recommended", "reason"],
            "properties": ["differences": ["type": "string"], "recommended": ["type": "integer"], "reason": ["type": "string"]]]
        let c: Comparison = try decode(try await ask(system, "Skill: \(skill)\n\n" + parts.joined(separator: "\n\n"), schema, 32768))
        let pick = min(max(c.recommended, 1), shown.count)
        var result = AssistResult(text: c.differences + "\n\n" + L("Recommended: copy \(pick) — \(c.reason)"))
        if let vault {
            for (i, copy) in shown.enumerated() {
                let others = copies.filter { $0 != copy }
                result.choices.append((label: L("Keep copy \(i + 1)") + (i + 1 == pick ? " ★" : ""),
                                       fix: .keepCopy(skill: skill, chosen: copy, others: others,
                                                      baseFolder: Self.baseFolder(of: skill, in: vault))))
            }
        }
        return result
    }

    /// Where the skill lives in the base, or where it will: an existing own/ or adopted/
    /// folder of that name, else adopted/.
    static func baseFolder(of skill: String, in vault: VaultLayout) -> URL {
        let own = vault.ownSkills.appendingPathComponent(skill)
        if FileManager.default.fileExists(atPath: own.path) { return own }
        return vault.adoptedSkills.appendingPathComponent(skill)
    }

    // MARK: H03 — clashing name

    private struct Names: Decodable { let names: [String]; let reason: String }

    static func suggestNames(skill: String, file: URL, ask: Ask) async throws -> AssistResult {
        let fm = MemoryScanner.parseFrontmatter((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        let system = """
        An Agent Skill has the same name as a skill bundled with Codex, so Codex may pick either. Suggest three other names that say what this skill is for: lowercase letters, digits and single hyphens, up to 40 characters, distinct from the original.
        `reason`: one sentence in \(AppLanguage.modelInstruction).
        """
        let schema: [String: Any] = ["type": "object", "required": ["names", "reason"],
            "properties": ["names": ["type": "array", "items": ["type": "string"]], "reason": ["type": "string"]]]
        let n: Names = try decode(try await ask(system, "Name: \(skill)\nDescription: \(fm.description ?? "")", schema, 8192))
        let valid = n.names.filter { $0.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil && $0 != skill }
        return AssistResult(text: L("Names that don't clash: \(valid.joined(separator: ", ")). \(n.reason) To rename, change the skill's folder and the name in its SKILL.md, then publish again."))
    }
}
