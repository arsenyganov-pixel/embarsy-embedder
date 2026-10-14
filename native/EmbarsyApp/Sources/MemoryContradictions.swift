import Foundation

/// H11 — notes that disagree (docs/memory-spec.md §11). Run on request, by the local model:
/// the index pairs passages that talk about the same thing, the model — the assistant — checks whether they
/// state different values for the same fact, and the person decides which one is right.
///
/// Verdicts are kept in `.embarsy/contradictions.json`, keyed by both passages' text, so a
/// second check only asks about passages that changed, and a pair dismissed once stays quiet.
struct ContradictionRecord: Codable, Hashable, Identifiable {
    enum Status: String, Codable { case open, dismissed, resolved }

    var key: String
    var aPath: String
    var bPath: String
    var aText: String
    var bText: String
    var contradiction: Bool
    var aSays: String
    var bSays: String
    var explanation: String
    var status: Status
    var checkedAt: String

    var id: String { key }
}

struct ContradictionStore: Codable {
    var checkedAt: String?
    var records: [String: ContradictionRecord] = [:]

    static func url(_ vault: VaultLayout) -> URL {
        vault.root.appendingPathComponent(".embarsy/contradictions.json")
    }

    static func load(_ vault: VaultLayout) -> ContradictionStore {
        guard let data = try? Data(contentsOf: url(vault)),
              let store = try? JSONDecoder().decode(ContradictionStore.self, from: data) else { return ContradictionStore() }
        return store
    }

    func save(_ vault: VaultLayout) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: Self.url(vault).deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.url(vault), options: .atomic)
    }
}

enum Contradictions {
    struct Passage: Hashable {
        let path: String
        let text: String
        let vector: [Double]
    }

    /// Passages this alike are about the same thing. Below, measured on a real base, pairs
    /// are mostly neighbours by topic only; above `maxSimilarity` it's the same text (H10).
    static let minSimilarity = 0.65
    static let maxSimilarity = 0.97
    /// Each passage is checked against its closest few in other notes, not against all of them:
    /// a contradiction needs the same subject, and the closest passages are where it lives.
    static let neighbours = 2

    /// Where facts live: knowledge, people, and the core. Experience is a history — an old
    /// episode saying something else is how history works, not a contradiction.
    static func isChecked(_ path: String) -> Bool {
        path.hasPrefix("knowledge/") || path.hasPrefix("people/") || path.hasPrefix("core/")
    }

    static func key(_ a: Passage, _ b: Passage) -> String {
        let ka = SHA256Hex.of(a.path + "\u{1f}" + a.text), kb = SHA256Hex.of(b.path + "\u{1f}" + b.text)
        return ka < kb ? ka + "|" + kb : kb + "|" + ka
    }

    /// Pairs worth asking about, closest first.
    static func candidates(_ passages: [Passage]) -> [(Passage, Passage, Double)] {
        var best: [Int: [(Double, Int)]] = [:]
        for i in passages.indices {
            for j in passages.indices where j > i && passages[i].path != passages[j].path {
                let a = passages[i].vector, b = passages[j].vector
                var dot = 0.0
                for k in 0..<min(a.count, b.count) { dot += a[k] * b[k] }
                guard dot >= minSimilarity, dot < maxSimilarity else { continue }
                best[i, default: []].append((dot, j))
                best[j, default: []].append((dot, i))
            }
        }
        var pairs: [String: (Passage, Passage, Double)] = [:]
        for (i, list) in best {
            for (sim, j) in list.sorted(by: { $0.0 > $1.0 }).prefix(neighbours) {
                let (a, b) = passages[i].path < passages[j].path ? (passages[i], passages[j]) : (passages[j], passages[i])
                pairs[key(a, b)] = (a, b, sim)
            }
        }
        return pairs.values.sorted { $0.2 > $1.2 }
    }

    struct Verdict: Decodable {
        let contradiction: Bool
        let a_says: String
        let b_says: String
        let explanation: String
    }

    static let system = """
    You check a user's memory notes for contradictions. You get two passages from two different notes.
    They contradict only when, read as they are today, they state different values for the same fact — a version, a path, a setting, a number, a decision, a rule — so that an agent trusting one would act against the other.
    NOT a contradiction:
    - passages about different things, or different projects;
    - one more detailed than the other, or one adding to the other;
    - different properties of the same thing — e.g. whether a version is committed vs whether it was released or accepted; the values must be for exactly the same property;
    - a history: a passage that itself says an approach was tried and dropped, or that a later step replaced an earlier one, agrees with a note that states the later outcome;
    - a link or a "see also" — it states nothing.
    `a_says`: ONE sentence or clause copied word for word from passage A — the statement that conflicts. `b_says`: likewise from passage B, about the same single fact. If several facts conflict, pick the clearest one. Never merge two statements into one and never paraphrase.
    `explanation`: one sentence about that one fact only, always filled when they contradict, written in \(AppLanguage.modelInstruction) — the person reads it in Embarsy. The quotes in `a_says` and `b_says` stay exactly as written in the notes. When there is no contradiction, leave those three empty.
    """

    /// The quick first pass over every pair. It only sorts: a pair it isn't sure about goes to
    /// the careful pass like a "yes" does — a missed contradiction is the worse mistake, since
    /// the check then reports the notes as clean.
    static let screenSystem = """
    You screen pairs of passages from a user's memory notes for possible contradictions. You get two passages from two different notes.
    - yes: they clearly state different values for the same fact — a version, a path, a setting, a number, a decision, a rule. Also yes: one recommends or prescribes an approach, a fix or an action, and the other rejects, forbids or calls it wrong.
    - unsure: they might — e.g. both mention the same version, setting, fix, approach or decision, and what they say about it could disagree.
    - no: they are about different things, or they agree, or one only adds detail to the other.
    When in doubt between unsure and no, answer unsure.
    """

    static let screenSchema: [String: Any] = ["type": "object", "required": ["answer"],
        "properties": ["answer": ["type": "string", "enum": ["yes", "unsure", "no"]]]]

    struct Screen: Decodable { let answer: String }

    /// The last check, on the two quotes alone: do they give different values for the same
    /// property? Asked up to three times without thinking; all three must say yes. A single
    /// thinking pass did worse — it talked itself into "not committed" vs "accepted".
    static let verifySystem = """
    Two statements from a user's notes. Answer whether they give different values for exactly the same property of the same thing, so that both cannot be true at the same time.
    Different properties of one thing (e.g. whether a version is committed vs whether it was released or accepted) do not conflict. A rule against an action conflicts with a statement recommending that action.
    """

    static let verifySchema: [String: Any] = ["type": "object", "required": ["conflict"],
        "properties": ["conflict": ["type": "boolean"]]]

    struct Verify: Decodable { let conflict: Bool }

    static func verifyQuestion(_ verdict: Verdict) -> String {
        "A: «\(verdict.a_says)»\nB: «\(verdict.b_says)»"
    }

    static let schema: [String: Any] = ["type": "object",
        "required": ["contradiction", "a_says", "b_says", "explanation"],
        "properties": [
            "contradiction": ["type": "boolean"],
            "a_says": ["type": "string"], "b_says": ["type": "string"], "explanation": ["type": "string"],
        ]]

    /// Whether a quoted statement is really in the passage — the assistant is told to quote word
    /// for word, and a paraphrase is how it glues two facts into one.
    static func isQuoted(_ says: String, in text: String) -> Bool {
        let clean = { (s: String) -> String in
            let stripped = s.lowercased().replacingOccurrences(of: #"[*_`«»"„“”]"#, with: "", options: .regularExpression)
            return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ".;:,!… "))
        }
        let quote = clean(says)
        return !quote.isEmpty && clean(text).contains(quote)
    }

    static func question(_ a: Passage, _ b: Passage) -> String {
        "A — \(a.path):\n\(a.text.prefix(2500))\n\nB — \(b.path):\n\(b.text.prefix(2500))"
    }

    /// Findings for the open verdicts whose passages are still in their notes as they were —
    /// one per pair of notes at a time: the next shows once the first is decided.
    static func findings(_ vault: VaultLayout) -> [HealthFinding] {
        let store = ContradictionStore.load(vault)
        var seenPairs = Set<String>()
        return store.records.values
            .filter { $0.contradiction && $0.status == .open }
            .sorted { $0.key < $1.key }
            .compactMap { record -> HealthFinding? in
                let a = vault.root.appendingPathComponent(record.aPath), b = vault.root.appendingPathComponent(record.bPath)
                guard let ta = try? String(contentsOf: a, encoding: .utf8), let tb = try? String(contentsOf: b, encoding: .utf8),
                      ta.contains(record.aText.prefix(300)), tb.contains(record.bText.prefix(300)),
                      seenPairs.insert(record.aPath + "\u{1f}" + record.bPath).inserted else { return nil }
                let detail = record.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? L("The two notes state different things about the same fact. An agent may trust either one.")
                    : record.explanation
                var finding = HealthFinding(code: "H11", severity: .warning,
                                            title: L("\(record.aPath) and \(record.bPath) disagree"),
                                            detail: detail,
                                            paths: [a, b])
                finding.contradiction = record
                return finding
            }
            .sorted { $0.title < $1.title }
    }

    /// Marks the passage that's wrong where it stands, so every agent that reads it sees the
    /// correction — the note itself isn't rewritten: what to do with the rest of it is the
    /// person's call, and the history keeps the original.
    static func markOutdated(_ record: ContradictionRecord, rightIsA: Bool, vault: VaultLayout) throws {
        let wrongPath = rightIsA ? record.bPath : record.aPath
        let rightPath = rightIsA ? record.aPath : record.bPath
        let wrongSays = rightIsA ? record.bSays : record.aSays
        let rightSays = rightIsA ? record.aSays : record.bSays
        let wrongText = rightIsA ? record.bText : record.aText
        let wrong = vault.root.appendingPathComponent(wrongPath)
        let right = vault.root.appendingPathComponent(rightPath)
        guard var text = try? String(contentsOf: wrong, encoding: .utf8) else {
            throw NSError(domain: "Embarsy", code: 1, userInfo: [NSLocalizedDescriptionKey: L("\(wrongPath) can't be read.")])
        }
        let link = relativeLink(from: wrong, to: right)
        let date = ISO8601DateFormatter.dateOnly.string(from: Date())
        let clean = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".;")) }
        let quote = "> **Outdated (\(date)):** «\(clean(wrongSays))» — [\(right.deletingPathExtension().lastPathComponent)](\(link)) is right: «\(clean(rightSays))»"
        // Right under the line that says the wrong thing, else under the passage (blank lines
        // around, so it's its own block); at the end if neither can be found.
        let said = wrongSays.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !said.isEmpty, let range = text.range(of: said) ?? text.range(of: wrongText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            text.insert(contentsOf: "\n\n" + quote + "\n", at: lineEnd)
        } else {
            text = text.trimmingCharacters(in: .newlines) + "\n\n" + quote + "\n"
        }
        try text.write(to: wrong, atomically: true, encoding: .utf8)
    }

    static func relativeLink(from note: URL, to target: URL) -> String {
        let from = note.deletingLastPathComponent().standardizedFileURL.pathComponents
        let to = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + to[common...]).joined(separator: "/")
    }
}
