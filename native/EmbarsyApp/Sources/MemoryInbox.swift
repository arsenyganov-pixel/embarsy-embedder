import CryptoKit
import Foundation

// What agents proposed to remember, and what the user decides about it
// (docs/memory-spec.md §5.8). Nothing becomes memory without the user: accepting writes the
// note, rejecting moves the proposal to archive/, and every decision is logged so later
// suggestions can learn from it.

struct InboxItem: Identifiable, Hashable {
    let url: URL
    /// The inbox folder it came from: claude, codex, roo or manual.
    let agent: String
    let title: String
    let created: String
    let proposedType: String
    let proposedPath: String
    let mergeWith: [String]
    let reason: String
    let confidence: String
    let text: String
    /// Written by Claude Code's own auto-memory rather than through `remember`.
    let isClaudeAutoMemory: Bool
    let modified: Date?

    var id: String { url.path }

    var agentLabel: String {
        switch agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "roo": return "Zoo / Roo"
        default: return "Added by hand"
        }
    }

    /// `agentLabel` for the screen. `agentLabel` itself stays English: it is written into notes.
    var agentDisplayLabel: String {
        switch agent {
        case "claude", "codex", "roo": return agentLabel
        default: return L("Added by hand")
        }
    }
}

enum InboxDestination: Hashable {
    /// A note in knowledge/, experience/ or people/ — created, or extended if it exists.
    case note(path: String)
    /// One more line in the core rules.
    case coreRule
    /// Added to "Anything else about you" in the core.
    case aboutMe

    var label: String {
        switch self {
        case .note(let path): return path
        case .coreRule: return "Core → Rules"
        case .aboutMe: return "Core → About you"
        }
    }
}

struct MemoryInbox {
    let layout: VaultLayout
    private var fm: FileManager { .default }

    static let agentFolders = ["claude", "codex", "roo", "manual"]
    static let noteSections = ["knowledge", "experience", "people"]

    // MARK: Reading

    func items() -> [InboxItem] {
        var out: [InboxItem] = []
        for agent in Self.agentFolders {
            let folder = layout.inbox.appendingPathComponent(agent)
            let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".md") && $0 != "MEMORY.md" && !$0.hasPrefix(".") }
            for name in names {
                let url = folder.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.append(Self.parse(text, url: url, agent: agent))
            }
        }
        return out.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    static func parse(_ text: String, url: URL, agent: String) -> InboxItem {
        let file = CoreFile.parse(text)
        let f = file.fields
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // Claude Code's auto-memory: name / description, and a type of its own.
        let isClaude = f["type"] != "inbox" && (f["name"] != nil || f["description"] != nil)
        let proposedType: String
        if isClaude {
            switch f["type"] ?? "" {
            case "user": proposedType = "person"
            case "feedback": proposedType = "core"
            default: proposedType = "knowledge"
            }
        } else {
            proposedType = f["proposed_type"] ?? "knowledge"
        }
        let firstLine = file.body.components(separatedBy: "\n").first { !$0.trimmed.isEmpty } ?? url.lastPathComponent
        // Claude's `description` is a readable one-line summary and its `name` a slug: the
        // summary makes the better title, the slug the better file name.
        let title: String
        var proposedPath = f["proposed_path"] ?? ""
        if isClaude {
            title = (f["description"] ?? f["name"] ?? "").trimmed.isEmpty ? String(firstLine.prefix(80)) : (f["description"] ?? f["name"]!)
            if proposedType == "knowledge", let name = f["name"], !name.trimmed.isEmpty {
                proposedPath = "knowledge/\(slug(name)).md"
            }
        } else {
            title = (f["title"] ?? "").trimmed.isEmpty ? String(firstLine.prefix(80)) : f["title"]!
        }
        return InboxItem(
            url: url,
            agent: agent,
            title: title,
            created: f["created"] ?? modified.map { ISO8601DateFormatter.dateOnly.string(from: $0) } ?? "",
            proposedType: proposedType,
            proposedPath: proposedPath,
            mergeWith: (f["merge_with"] ?? "").split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty },
            reason: isClaude ? "" : (f["reason"] ?? ""),
            confidence: f["confidence"] ?? (isClaude ? "" : "inferred"),
            text: file.body,
            isClaudeAutoMemory: isClaude,
            modified: modified
        )
    }

    // MARK: Suggesting

    /// Where the proposal most likely belongs, before the user changes anything.
    func suggestedDestination(for item: InboxItem, today: Date = Date()) -> InboxDestination {
        if let merge = item.mergeWith.first(where: { isValidNotePath($0) && fm.fileExists(atPath: layout.root.appendingPathComponent($0).path) }) {
            return .note(path: merge)
        }
        if isValidNotePath(item.proposedPath) { return .note(path: item.proposedPath) }
        return defaultDestination(type: item.proposedType, title: item.title, today: today)
    }

    func defaultDestination(type: String, title: String, today: Date = Date()) -> InboxDestination {
        let slug = Self.slug(title)
        switch type {
        case "core": return .coreRule
        case "experience":
            let date = ISO8601DateFormatter.dateOnly.string(from: today)
            return .note(path: "experience/\(date.prefix(4))/\(date)-\(slug).md")
        case "person":
            let name = title.trimmed.replacingOccurrences(of: "/", with: "-")
            return .note(path: "people/\(name.isEmpty ? slug : name).md")
        default:
            return .note(path: "knowledge/\(slug).md")
        }
    }

    /// A relative path to a markdown note inside knowledge/, experience/ or people/.
    func isValidNotePath(_ path: String) -> Bool {
        let p = path.trimmed
        guard p.hasSuffix(".md"), !p.hasPrefix("/"), !p.contains(".."), let first = p.split(separator: "/").first else { return false }
        return Self.noteSections.contains(String(first)) && p.split(separator: "/").count >= 2
    }

    // MARK: Deciding

    enum InboxError: LocalizedError {
        case badPath(String)
        var errorDescription: String? {
            switch self {
            case .badPath(let path):
                return L("\(path) isn't a place for a note. Use a .md path inside knowledge/, experience/ or people/.")
            }
        }
    }

    /// Writes the fact where the user chose. Returns the new core profile when the core changed.
    func accept(_ item: InboxItem, to destination: InboxDestination, profile: CoreProfile, home: URL, now: Date = Date()) throws -> CoreProfile? {
        let fact = item.text.trimmed
        var newProfile: CoreProfile?
        switch destination {
        case .note(let path):
            guard isValidNotePath(path) else { throw InboxError.badPath(path) }
            let url = layout.root.appendingPathComponent(path.trimmed)
            if fm.fileExists(atPath: url.path) {
                try merge(fact, from: item, into: url, now: now)
            } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try newNote(fact, from: item, path: path, now: now).write(to: url, atomically: true, encoding: .utf8)
            }
        case .coreRule:
            var p = profile
            p.customRules = [p.customRules.trimmed, fact.replacingOccurrences(of: "\n", with: " ")]
                .filter { !$0.isEmpty }.joined(separator: "\n")
            try p.write(to: layout)
            try VaultCreator.writeAgentsMd(layout: layout, profile: p, home: home)
            newProfile = p
        case .aboutMe:
            var p = profile
            p.aboutMe = [p.aboutMe.trimmed, fact].filter { !$0.isEmpty }.joined(separator: "\n\n")
            try p.write(to: layout)
            try VaultCreator.writeAgentsMd(layout: layout, profile: p, home: home)
            newProfile = p
        }
        try removeFromInbox(item)
        log(item, decision: "accepted", destination: destination.label, now: now)
        return newProfile
    }

    /// Kept, not deleted: archive/ is outside recall but still in the base and its history.
    func reject(_ item: InboxItem, now: Date = Date()) throws {
        let folder = layout.archive.appendingPathComponent("inbox-rejected").appendingPathComponent(item.agent)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appendingPathComponent(item.url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + "-\(n).md")
            n += 1
        }
        try fm.moveItem(at: item.url, to: target)
        if item.isClaudeAutoMemory { removeFromClaudeIndex(item) }
        log(item, decision: "rejected", destination: nil, now: now)
    }

    private func newNote(_ fact: String, from item: InboxItem, path: String, now: Date) -> String {
        let date = ISO8601DateFormatter.dateOnly.string(from: now)
        let section = String(path.split(separator: "/").first ?? "knowledge")
        let type = section == "people" ? "person" : section
        var lines = ["---", "type: \(type)", "title: \(CoreFile.jsonString(item.title))", "created: \(date)", "updated: \(date)"]
        // Only what was checked counts as verified; the user saying so is not verification of the world.
        if item.confidence == "observed" { lines.append("verified_at: \(date)") }
        lines += [
            "source:",
            "  kind: agent",
            "  agent: \(item.agent)",
            "  ref: \(CoreFile.jsonString("inbox/\(item.agent)/\(item.url.lastPathComponent)"))",
            "confidence: \(item.confidence.isEmpty ? "inferred" : item.confidence)",
            "status: active",
            "---",
            "",
            "# \(item.title)",
            "",
            fact,
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// Adds the fact as a dated section, so what was there stays and the history reads in order.
    private func merge(_ fact: String, from item: InboxItem, into url: URL, now: Date) throws {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let date = ISO8601DateFormatter.dateOnly.string(from: now)
        if let range = text.range(of: #"(?m)^updated: .*$"#, options: .regularExpression) {
            text.replaceSubrange(range, with: "updated: \(date)")
        }
        if !text.hasSuffix("\n") { text += "\n" }
        text += "\n## \(date) — from \(item.agentLabel)\n\n\(fact)\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeFromInbox(_ item: InboxItem) throws {
        try fm.removeItem(at: item.url)
        if item.isClaudeAutoMemory { removeFromClaudeIndex(item) }
    }

    /// Claude Code lists its memory files in MEMORY.md and loads that index every session; a
    /// line pointing at a file that is gone would only confuse it.
    private func removeFromClaudeIndex(_ item: InboxItem) {
        let index = item.url.deletingLastPathComponent().appendingPathComponent("MEMORY.md")
        guard let text = try? String(contentsOf: index, encoding: .utf8) else { return }
        let name = item.url.lastPathComponent
        let kept = text.components(separatedBy: "\n").filter { !$0.contains("(\(name))") && !$0.contains("[[\(item.url.deletingPathExtension().lastPathComponent)]]") }
        try? kept.joined(separator: "\n").write(to: index, atomically: true, encoding: .utf8)
    }

    /// One line per decision in .embarsy/decisions.jsonl — never committed, never shared.
    private func log(_ item: InboxItem, decision: String, destination: String?, now: Date) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: now),
            "agent": item.agent,
            "title": item.title,
            "text": String(item.text.trimmed.prefix(500)),
            "proposed_type": item.proposedType,
            "decision": decision,
        ]
        if let destination { entry["destination"] = destination }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        let url = layout.service.appendingPathComponent("decisions.jsonl")
        try? fm.createDirectory(at: layout.service, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().precomposedStringWithCanonicalMapping
        var out = ""
        var lastDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out += "-"
                lastDash = true
            }
            if out.count >= 48 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "note" : out
    }
}

// MARK: - Finding similar notes

/// Where the Embarsy API and its Qdrant proxy are, for the app's own searches.
struct MemorySearchConfig {
    let embeddingsURL: URL
    let apiKey: String
    let qdrantURL: URL
    let qdrantKey: String
    let model: String
}

struct SimilarNote: Identifiable, Hashable {
    let path: String
    let title: String
    let heading: String
    let score: Double
    var id: String { path + "|" + heading }
}

enum MemorySearch {
    /// Overridable for tests, so they never read or write the real index.
    static var collection = "embarsy-memory"

    struct Hit: Identifiable, Hashable {
        let path: String
        let title: String
        let heading: String
        let snippet: String
        let score: Double
        var id: String { path + "|" + heading + "|" + String(score) }
    }

    /// The whole base by meaning, the way recall searches it — passages, best first.
    static func search(_ query: String, config: MemorySearchConfig, limit: Int = 12) async -> [Hit] {
        guard let raw = await rawSearch(query, config: config, limit: limit * 3) else { return [] }
        var seen = Set<String>()
        var out: [Hit] = []
        for hit in raw {
            // One entry per note, its best passage: several passages of one file read as noise.
            guard let payload = hit["payload"] as? [String: Any], let path = payload["file_path"] as? String,
                  let score = hit["score"] as? Double, score >= 0.3, seen.insert(path).inserted else { continue }
            out.append(Hit(path: path, title: payload["title"] as? String ?? path, heading: payload["heading"] as? String ?? "",
                           snippet: plain(payload["text"] as? String ?? ""), score: score))
            if out.count == limit { break }
        }
        return out
    }

    /// One text's embedding from the Embarsy API, or nil when it can't be reached.
    static func embed(_ text: String, config: MemorySearchConfig) async -> [Double]? {
        var request = URLRequest(url: config.embeddingsURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("embarsy-app", forHTTPHeaderField: "X-Embarsy-Client")
        request.setValue("search", forHTTPHeaderField: "X-Embarsy-Tool")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": config.model, "input": [String(text.prefix(4000))]])
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first else { return nil }
        return first["embedding"] as? [Double]
    }

    /// Every passage's file and vector in the memory index, for comparing whole notes.
    /// Every passage of the notes H11 checks, with its text and vector.
    static func allPassages(config: MemorySearchConfig) async -> [Contradictions.Passage]? {
        var out: [Contradictions.Passage] = []
        var offset: Any? = nil
        repeat {
            var request = URLRequest(url: config.qdrantURL.appendingPathComponent("collections/\(collection)/points/scroll"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(config.qdrantKey, forHTTPHeaderField: "api-key")
            request.setValue("embarsy-app", forHTTPHeaderField: "X-Embarsy-Client")
            request.setValue("search", forHTTPHeaderField: "X-Embarsy-Tool")
            var body: [String: Any] = ["limit": 256, "with_payload": ["file_path", "text"], "with_vector": true]
            if let offset { body["offset"] = offset }
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            request.httpBody = data
            request.timeoutInterval = 30
            guard let (reply, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["result"] as? [String: Any],
                  let points = result["points"] as? [[String: Any]] else { return nil }
            for point in points {
                guard let payload = point["payload"] as? [String: Any], let path = payload["file_path"] as? String,
                      Contradictions.isChecked(path), let text = payload["text"] as? String,
                      let vector = point["vector"] as? [Double] else { continue }
                out.append(.init(path: path, text: text, vector: vector))
            }
            offset = result["next_page_offset"].flatMap { $0 is NSNull ? nil : $0 }
        } while offset != nil
        return out
    }

    static func allVectors(config: MemorySearchConfig) async -> [(String, [Double])]? {
        var out: [(String, [Double])] = []
        var offset: Any? = nil
        repeat {
            var request = URLRequest(url: config.qdrantURL.appendingPathComponent("collections/\(collection)/points/scroll"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(config.qdrantKey, forHTTPHeaderField: "api-key")
            request.setValue("embarsy-app", forHTTPHeaderField: "X-Embarsy-Client")
            request.setValue("search", forHTTPHeaderField: "X-Embarsy-Tool")
            var body: [String: Any] = ["limit": 256, "with_payload": ["file_path"], "with_vector": true]
            if let offset { body["offset"] = offset }
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            request.httpBody = data
            request.timeoutInterval = 30
            guard let (reply, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["result"] as? [String: Any],
                  let points = result["points"] as? [[String: Any]] else { return nil }
            for point in points {
                guard let path = (point["payload"] as? [String: Any])?["file_path"] as? String,
                      let vector = point["vector"] as? [Double] else { continue }
                out.append((path, vector))
            }
            offset = result["next_page_offset"].flatMap { $0 is NSNull ? nil : $0 }
        } while offset != nil
        return out
    }

    /// A passage as readable text: no heading marks, link targets or emphasis characters.
    static func plain(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("```") && !$0.hasPrefix("|---") }
        var text = lines.joined(separator: " ")
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`]{1,2}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
        return String(text.prefix(220))
    }

    private static func rawSearch(_ text: String, config: MemorySearchConfig, limit: Int) async -> [[String: Any]]? {
        do {
            var embed = URLRequest(url: config.embeddingsURL.appendingPathComponent("embeddings"))
            embed.httpMethod = "POST"
            embed.setValue("application/json", forHTTPHeaderField: "Content-Type")
            embed.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            embed.setValue("embarsy-app", forHTTPHeaderField: "X-Embarsy-Client")
            embed.setValue("search", forHTTPHeaderField: "X-Embarsy-Tool")
            embed.httpBody = try JSONSerialization.data(withJSONObject: ["model": config.model, "input": [String(text.prefix(4000))]])
            embed.timeoutInterval = 20
            let (embedData, _) = try await URLSession.shared.data(for: embed)
            guard let json = try JSONSerialization.jsonObject(with: embedData) as? [String: Any],
                  let first = (json["data"] as? [[String: Any]])?.first,
                  let vector = first["embedding"] as? [Double] else { return nil }
            var search = URLRequest(url: config.qdrantURL.appendingPathComponent("collections/\(collection)/points/search"))
            search.httpMethod = "POST"
            search.setValue("application/json", forHTTPHeaderField: "Content-Type")
            search.setValue(config.qdrantKey, forHTTPHeaderField: "api-key")
            search.setValue("embarsy-app", forHTTPHeaderField: "X-Embarsy-Client")
            search.setValue("search", forHTTPHeaderField: "X-Embarsy-Tool")
            search.httpBody = try JSONSerialization.data(withJSONObject: ["vector": vector, "limit": limit, "with_payload": true])
            search.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: search)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [[String: Any]]
        } catch {
            return nil
        }
    }

    /// Notes that read like this text. Empty when the stack is down or the base hasn't been
    /// indexed yet — the bridge indexes it the first time an agent recalls something.
    static func similar(to text: String, config: MemorySearchConfig, limit: Int = 4) async -> [SimilarNote] {
        do {
            var embed = URLRequest(url: config.embeddingsURL.appendingPathComponent("embeddings"))
            embed.httpMethod = "POST"
            embed.setValue("application/json", forHTTPHeaderField: "Content-Type")
            embed.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            embed.setValue("embarsy-app", forHTTPHeaderField: "X-Embarsy-Client")
            embed.setValue("search", forHTTPHeaderField: "X-Embarsy-Tool")
            embed.httpBody = try JSONSerialization.data(withJSONObject: ["model": config.model, "input": [String(text.prefix(4000))]])
            embed.timeoutInterval = 20
            let (embedData, _) = try await URLSession.shared.data(for: embed)
            guard let json = try JSONSerialization.jsonObject(with: embedData) as? [String: Any],
                  let first = (json["data"] as? [[String: Any]])?.first,
                  let vector = first["embedding"] as? [Double] else { return [] }

            var search = URLRequest(url: config.qdrantURL.appendingPathComponent("collections/\(collection)/points/search"))
            search.httpMethod = "POST"
            search.setValue("application/json", forHTTPHeaderField: "Content-Type")
            search.setValue(config.qdrantKey, forHTTPHeaderField: "api-key")
            search.setValue("embarsy-app", forHTTPHeaderField: "X-Embarsy-Client")
            search.setValue("search", forHTTPHeaderField: "X-Embarsy-Tool")
            search.httpBody = try JSONSerialization.data(withJSONObject: ["vector": vector, "limit": limit * 3, "with_payload": true])
            search.timeoutInterval = 20
            let (searchData, response) = try await URLSession.shared.data(for: search)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = (try JSONSerialization.jsonObject(with: searchData) as? [String: Any])?["result"] as? [[String: Any]]
            else { return [] }

            var seen = Set<String>()
            var out: [SimilarNote] = []
            for hit in result {
                guard let payload = hit["payload"] as? [String: Any],
                      let path = payload["file_path"] as? String,
                      MemoryInbox.noteSections.contains(String(path.split(separator: "/").first ?? "")),
                      let score = hit["score"] as? Double, score >= 0.55,
                      seen.insert(path).inserted else { continue }
                out.append(SimilarNote(path: path, title: payload["title"] as? String ?? path,
                                       heading: payload["heading"] as? String ?? "", score: score))
                if out.count == limit { break }
            }
            return out
        } catch {
            return []
        }
    }
}

// MARK: - Learning from earlier decisions

/// What the user did with proposals like this one before, for the Inbox to suggest.
struct DecisionHint: Equatable {
    enum Kind: Equatable {
        /// Similar facts went into this folder.
        case folder(String)
        /// Similar proposals were rejected.
        case rejected
    }
    let kind: Kind
    /// How many of the nearest earlier decisions agree.
    let count: Int
    /// Their titles, to show why.
    let examples: [String]
}

enum MemoryDecisions {
    struct Entry: Decodable {
        let agent: String?
        let title: String?
        let text: String?
        let decision: String
        let destination: String?
    }

    /// Below this, an earlier decision is about something else and says nothing about this one.
    /// Measured on short Russian facts: related decisions scored 0.56-0.71, unrelated ones at
    /// most 0.48. Below it, nothing is suggested at all.
    static let similarity = 0.55
    static let neighbours = 5

    static func entries(_ layout: VaultLayout) -> [Entry] {
        guard let text = try? String(contentsOf: layout.service.appendingPathComponent("decisions.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
    }

    /// The folder (or rejection) most of the nearest earlier decisions agree on, if any.
    /// No model is trained: earlier decisions are compared with the new proposal by meaning,
    /// each embedded once and kept in .embarsy/decision-vectors.json.
    static func hint(for item: InboxItem, layout: VaultLayout, config: MemorySearchConfig) async -> DecisionHint? {
        let past = entries(layout).filter { !($0.text ?? "").isEmpty }
        guard !past.isEmpty, let query = await MemorySearch.embed(item.title + "\n" + item.text, config: config) else { return nil }

        let cacheURL = layout.service.appendingPathComponent("decision-vectors.json")
        var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: [Double]].self, from: $0) } ?? [:]
        var scored: [(Double, Entry)] = []
        for entry in past {
            let text = (entry.title ?? "") + "\n" + (entry.text ?? "")
            let key = SHA256Hex.of(text)
            var vector = cache[key]
            if vector == nil {
                vector = await MemorySearch.embed(text, config: config)
                cache[key] = vector
            }
            guard let vector else { continue }
            scored.append((cosine(query, vector), entry))
        }
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }

        let near = scored.filter { $0.0 >= similarity }.sorted { $0.0 > $1.0 }.prefix(neighbours)
        guard !near.isEmpty else { return nil }
        var votes: [DecisionHint.Kind: [String]] = [:]
        for (_, entry) in near {
            let kind: DecisionHint.Kind
            if entry.decision == "rejected" {
                kind = .rejected
            } else if let destination = entry.destination, destination.hasSuffix(".md") {
                kind = .folder((destination as NSString).deletingLastPathComponent)
            } else {
                continue   // into the core: too personal a call to suggest from
            }
            votes[kind, default: []].append(entry.title ?? "")
        }
        // A suggestion needs a majority of the near decisions, so one odd case doesn't steer.
        guard let best = votes.max(by: { $0.value.count < $1.value.count }), best.value.count * 2 > near.count else { return nil }
        return DecisionHint(kind: best.key, count: best.value.count, examples: Array(best.value.prefix(3)))
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
}

extension DecisionHint.Kind: Hashable {}

enum SHA256Hex {
    static func of(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
