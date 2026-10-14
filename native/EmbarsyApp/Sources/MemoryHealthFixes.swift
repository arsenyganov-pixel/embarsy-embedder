import Foundation

// Fixes Health can make by itself. Only inside the memory base, which is Embarsy's to edit —
// files elsewhere are reported, never changed — and for leftover copies in folders no agent
// reads, which are moved to the backups rather than deleted.

struct LinkRepair: Hashable {
    /// The link target as written, e.g. `../../memory/references/experience.md:1`.
    let original: String
    /// What it becomes; nil drops the link and keeps its text.
    let replacement: String?
    /// How the replacement was found, for the person deciding.
    let how: String
}

enum HealthFix: Hashable {
    case moveLeftovers([URL])
    case repairLinks(file: URL, repairs: [LinkRepair])
    case stripLineNumbers(files: [URL], count: Int)
    /// `absorb`'s text appended to `keep` as a section; `absorb` to archive/; links follow.
    case mergeNotes(keep: URL, absorb: URL)
    /// H07: the vendor skill's files back as they were recorded in vendor.lock.yaml.
    case revertVendor(name: String, folder: URL, recordedHash: String)
    /// H08: the source's newer version copied in, and the record updated.
    case updateVendor(name: String, from: URL, folder: URL)
    /// H01: frontmatter values a strict YAML parser rejects, rewritten as quoted strings.
    case quoteFrontmatter(file: URL, keys: [String])
    /// H01: `name:` set to the folder's name (inside the base the folder is the skill's identity).
    case setSkillName(file: URL, name: String)
    /// H01: a description the assistant shortened, after the person read it.
    case setDescription(file: URL, text: String)
    /// H14 / H18: the skill copied into the base's adopted/ and published; with
    /// `replaceOriginal`, the agent's own copy goes to the backups and becomes a link.
    case adoptSkill(from: URL, name: String, replaceOriginal: Bool)
    /// H02: one copy becomes the base's; every other copy becomes a link to it.
    case keepCopy(skill: String, chosen: URL, others: [URL], baseFolder: URL)
    /// H16 / H19: publish the base to the agents.
    case publish

    var buttonTitle: String {
        switch self {
        case .moveLeftovers(let paths): return L("Move \(paths.count) to backups")
        case .repairLinks(_, let repairs):
            let fixed = repairs.filter { $0.replacement != nil }.count
            return fixed == repairs.count ? L("Fix \(fixed) links") : L("Fix links")
        case .stripLineNumbers(_, let count): return L("Remove \(count) line numbers")
        case .mergeNotes(let keep, let absorb): return L("Merge \(absorb.lastPathComponent) into \(keep.lastPathComponent)")
        case .revertVendor(let name, _, _): return L("Put \(name) back as installed")
        case .updateVendor(let name, _, _): return L("Update \(name)")
        case .quoteFrontmatter(_, let keys): return L("Quote \(keys.joined(separator: ", "))")
        case .setSkillName(_, let name): return L("Set name to \(name)")
        case .setDescription: return L("Use this description")
        case .adoptSkill: return L("Bring into the base")
        case .keepCopy: return L("Keep this copy")
        case .publish: return L("Publish")
        }
    }

    var summary: String {
        switch self {
        case .moveLeftovers(let paths):
            return L("Moves \(paths.count) folders to Embarsy's backups. No agent reads them, so nothing changes for your agents; Undo setup in Memory → Core puts them back.")
        case .repairLinks(let file, _):
            return L("Rewrites links in \(file.lastPathComponent). The previous version stays in the base's history.")
        case .mergeNotes(let keep, let absorb):
            return L("Adds the text of \(absorb.lastPathComponent) to \(keep.lastPathComponent) as its own section, moves \(absorb.lastPathComponent) to archive/ and points every link to it at \(keep.lastPathComponent). Nothing is lost: the archived note and the history keep both versions.")
        case .stripLineNumbers(let files, _):
            return L("Turns links like file.md:36 into file.md in \(files.count) files: they keep pointing at the file, just not at a line that moves with every edit. The previous version stays in the base's history.")
        case .revertVendor(let name, _, _):
            return L("Restores every file of \(name) from the base's history, as it was when it was installed. The changed version is kept in the history first.")
        case .updateVendor(let name, let from, _):
            return L("Copies \(name) from \(MemoryScanner.tilde(from)) into the base and records the new version. The version you have now stays in the base's history.")
        case .setSkillName(let file, let name):
            return L("Sets name: in \(file.deletingLastPathComponent().lastPathComponent)/SKILL.md to \(name), the folder's name, so every agent accepts it. The previous version stays in the base's history.")
        case .setDescription(let file, _):
            return L("Replaces the description in \(file.deletingLastPathComponent().lastPathComponent)/SKILL.md with the shorter one above. The previous version stays in the base's history.")
        case .adoptSkill(let from, let name, let replaceOriginal):
            return replaceOriginal
                ? L("Copies \(name) from \(MemoryScanner.tilde(from)) into the base and publishes it to every agent. The folder it was in goes to Embarsy's backups and becomes a link to the base; Undo setup in Memory → Core puts it back.")
                : L("Copies \(name) from \(MemoryScanner.tilde(from)) into the base and publishes it to every agent. The original stays where it is.")
        case .keepCopy(let skill, let chosen, _, _):
            return L("Makes the copy in \(MemoryScanner.tilde(chosen)) the base's version of \(skill), and turns every other copy into a link to it. Other copies go to Embarsy's backups first; earlier versions in the base stay in its history.")
        case .publish:
            return L("Publishes the base: links your skills and the core into each agent's folders, the same as Publish in Memory → Core. Agents' own files stay as they are.")
        case .quoteFrontmatter(let file, let keys):
            return L("Puts \(keys.joined(separator: ", ")) in \(file.deletingLastPathComponent().lastPathComponent)/SKILL.md in double quotes. The text stays the same; every agent can then read it. The previous version stays in the base's history.")
        }
    }
}

// MARK: - Where migrated files came from

/// Original location → path inside the base, so a link written relative to where a file used
/// to live can be followed to where its target lives now.
struct MigrationMap: Codable {
    var entries: [String: String] = [:]
    /// Notes cut out of a journal: their links were written relative to the journal.
    var origins: [String: String] = [:]
    /// Copies of one skill in different places: a file in one copy stands for the same file
    /// in the others (a journal in ~/.agents linking into "its" knowledge skill means the
    /// knowledge that came over from a personal copy).
    var aliases: [String: [String]] = [:]
    /// The folders the migration read. A file still there is a copy the migration left
    /// behind: links to it should follow its content into the base, not point back at it.
    var sourceRoots: [String] = []

    private enum CodingKeys: String, CodingKey { case entries, origins, aliases, sourceRoots }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([String: String].self, forKey: .entries) ?? [:]
        origins = try c.decodeIfPresent([String: String].self, forKey: .origins) ?? [:]
        aliases = try c.decodeIfPresent([String: [String]].self, forKey: .aliases) ?? [:]
        sourceRoots = try c.decodeIfPresent([String].self, forKey: .sourceRoots) ?? []
    }

    static func file(_ layout: VaultLayout) -> URL { layout.service.appendingPathComponent("migration-map.json") }

    static func load(layout: VaultLayout, home: URL) -> MigrationMap {
        if let data = try? Data(contentsOf: file(layout)),
           let map = try? JSONDecoder().decode(MigrationMap.self, from: data) {
            return map
        }
        // A base created before the map was written: rebuild it from the applied migration.
        return rebuild(layout: layout, home: home)
    }

    static func rebuild(layout: VaultLayout, home: URL) -> MigrationMap {
        let fm = FileManager.default
        let folder = MigrationStaging.folder(home: home)
        var map = MigrationMap()
        for name in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
            let staging = MigrationStaging(root: folder.appendingPathComponent(name))
            guard fm.fileExists(atPath: staging.root.appendingPathComponent("applied").path),
                  let stateData = try? Data(contentsOf: staging.state),
                  let state = try? JSONDecoder().decode(MigrationState.self, from: stateData),
                  URL(fileURLWithPath: state.vaultPath).standardizedFileURL.path == layout.root.standardizedFileURL.path,
                  let plan = try? MigrationPlan.load(staging.plan) else { continue }
            let inventory = (try? Data(contentsOf: staging.inventory)).flatMap { try? JSONDecoder().decode(MigrationInventory.self, from: $0) }
            map.add(plan: plan, inventory: inventory, layout: layout, sources: state.sources.map(\.path))
        }
        return map
    }

    mutating func add(plan: MigrationPlan, inventory: MigrationInventory?, layout: VaultLayout, sources: [String] = []) {
        let fm = FileManager.default
        sourceRoots = Array(Set(sourceRoots + sources.map(Self.key))).sorted()
        for skill in plan.skills ?? [] {
            guard let from = skill.from, let rel = Self.skillFolder(named: skill.name, in: layout) else { continue }
            entries[Self.key(from)] = rel
        }
        let journalOf = Dictionary((inventory?.experienceEntries ?? []).map { (Self.key($0.file), $0.from) }, uniquingKeysWith: { a, _ in a })
        for note in plan.notes ?? [] {
            guard let from = note.from, fm.fileExists(atPath: layout.root.appendingPathComponent(note.path).path) else { continue }
            if let journal = journalOf[Self.key(from)] {
                origins[note.path] = journal
            } else {
                entries[Self.key(from)] = note.path
            }
        }
        for skill in inventory?.skills ?? [] {
            let dirs = Array(Set(skill.copies.map { Self.key($0.resolved) }))
            guard dirs.count > 1 else { continue }
            for dir in dirs { aliases[dir] = dirs.filter { $0 != dir } }
        }
        // A journal was cut into entries; links to it now mean the experience folder.
        for entry in inventory?.experienceEntries ?? [] where entries[Self.key(entry.from)] == nil {
            entries[Self.key(entry.from)] = "experience"
        }
        // What each item was put together from: a file that went into a skill, a note or the
        // core lives on there, even when the item wasn't a straight copy of it.
        func claim(_ source: String, _ target: String) {
            let k = Self.key(source)
            if entries[k] == nil { entries[k] = target }
        }
        for skill in plan.skills ?? [] {
            guard let rel = Self.skillFolder(named: skill.name, in: layout) else { continue }
            for source in skill.sources ?? [] {
                var dir: ObjCBool = false
                let isDir = fm.fileExists(atPath: source, isDirectory: &dir) && dir.boolValue
                claim(source, isDir ? rel : rel + "/SKILL.md")
            }
        }
        for note in plan.notes ?? [] where fm.fileExists(atPath: layout.root.appendingPathComponent(note.path).path) {
            for source in note.sources ?? [] { claim(source, note.path) }
        }
        for source in plan.core?.sources ?? [] { claim(source, "AGENTS.md") }
    }

    func save(_ layout: VaultLayout) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: layout.service, withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: Self.file(layout), options: .atomic)
    }

    static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func skillFolder(named name: String, in layout: VaultLayout) -> String? {
        let fm = FileManager.default
        for base in [layout.ownSkills, layout.adoptedSkills] where fm.fileExists(atPath: base.appendingPathComponent(name).path) {
            return "skills/\(base.lastPathComponent)/\(name)"
        }
        for source in (try? fm.contentsOfDirectory(atPath: layout.vendorSkills.path)) ?? []
        where fm.fileExists(atPath: layout.vendorSkills.appendingPathComponent(source).appendingPathComponent(name).path) {
            return "skills/vendor/\(source)/\(name)"
        }
        return nil
    }

    /// Inside a folder the migration read, outside the base: a copy left behind.
    func isLeftBehind(_ path: String, vault: VaultLayout) -> Bool {
        let p = Self.key(path)
        let root = Self.key(vault.root.path)
        guard !p.hasPrefix(root + "/") else { return false }
        return sourceRoots.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// Where a file in the base used to live, if it came from a migration.
    func original(of rel: String) -> String? {
        if let journal = origins[rel] { return journal }
        if let exact = entries.first(where: { $0.value == rel }) { return exact.key }
        if let folder = entries.first(where: { rel.hasPrefix($0.value + "/") }) {
            return folder.key + "/" + rel.dropFirst(folder.value.count + 1)
        }
        return nil
    }

    /// Where something that used to live at `path` lives in the base now.
    func current(of path: String) -> String? {
        if let found = direct(path) { return found }
        for (dir, others) in aliases where path.hasPrefix(dir + "/") {
            let rest = path.dropFirst(dir.count)
            for other in others { if let found = direct(other + rest) { return found } }
        }
        return nil
    }

    private func direct(_ path: String) -> String? {
        if let exact = entries[path] { return exact }
        if let folder = entries.first(where: { path.hasPrefix($0.key + "/") }) {
            return folder.value + "/" + path.dropFirst(folder.key.count + 1)
        }
        return nil
    }
}

// MARK: - Finding the right target

struct LinkResolver {
    let layout: VaultLayout
    let home: URL
    let map: MigrationMap

    /// Repairs for every broken link in one file. Two passes: a link found by its path tail
    /// reveals the folder the file's links were written against, which then resolves the
    /// links Spotlight can't see (hidden files such as .env).
    func repairs(for targets: [String], in file: URL) -> [LinkRepair] {
        var first = targets.map { repair(for: $0, in: file) }
        let bases = Set(zip(targets, first).compactMap { target, repair -> String? in
            guard let replacement = repair.replacement, replacement.hasPrefix("/") else { return nil }
            let tail = Self.tail(of: target)
            return replacement.hasSuffix("/" + tail) ? String(replacement.dropLast(tail.count)) : nil
        })
        for (i, repair) in first.enumerated() where repair.replacement == nil {
            let tail = Self.tail(of: targets[i])
            if let base = bases.first(where: { FileManager.default.fileExists(atPath: $0 + tail) }) {
                first[i] = LinkRepair(original: targets[i], replacement: base + tail,
                                      how: L("Found next to the other links in this file, in \(MemoryScanner.tilde(URL(fileURLWithPath: base)))"))
            }
        }
        return first
    }

    static func tail(of target: String) -> String {
        var path = target
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if let range = path.range(of: #":\d+$"#, options: .regularExpression) { path.removeSubrange(range) }
        let decoded = path.removingPercentEncoding ?? path
        return decoded.split(separator: "/").drop { $0 == ".." || $0 == "." }.joined(separator: "/")
    }

    /// A replacement for a broken link in a file inside the base, or a "drop the link" repair
    /// when nothing convincing is found.
    func repair(for target: String, in file: URL) -> LinkRepair {
        var path = target
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if let range = path.range(of: #":\d+$"#, options: .regularExpression) { path.removeSubrange(range) }
        let decoded = path.removingPercentEncoding ?? path
        let fm = FileManager.default
        let fileDir = file.deletingLastPathComponent()

        // 1. Followed from where the file used to live, before the migration moved it.
        let rel = MemoryScanner.relativePath(of: file, in: layout.root)
        if !decoded.hasPrefix("/"), let original = map.original(of: rel) {
            let old = URL(fileURLWithPath: original).deletingLastPathComponent().appendingPathComponent(decoded)
                .standardizedFileURL.path
            if let now = map.current(of: MigrationMap.key(old)),
               fm.fileExists(atPath: layout.root.appendingPathComponent(now).path) {
                return LinkRepair(original: target,
                                  replacement: Self.relative(from: fileDir, to: layout.root.appendingPathComponent(now)),
                                  how: L("Its target moved into the base with the migration."))
            }
            if map.isLeftBehind(old, vault: layout) {
                return LinkRepair(original: target, replacement: nil,
                                  how: L("It pointed at \(MemoryScanner.tilde(URL(fileURLWithPath: old))), which the migration didn't bring into the base. The link is removed, its text stays."))
            }
            if fm.fileExists(atPath: old) {
                return LinkRepair(original: target, replacement: old, how: L("Its target is still where it was before the migration."))
            }
        }

        // 2. The same path tail somewhere on this Mac (Spotlight), when there is exactly one.
        let tail = decoded.split(separator: "/").drop { $0 == ".." || $0 == "." }.joined(separator: "/")
        if tail.split(separator: "/").count >= 2 {
            var found = Self.spotlight(name: URL(fileURLWithPath: tail).lastPathComponent, under: home)
                .filter { $0.hasSuffix("/" + tail) && !$0.contains("/Library/") }
            // Several matches, one of them in the base: the base's is the one meant.
            let inBase = found.filter { $0.hasPrefix(layout.root.path + "/") }
            if found.count > 1, inBase.count == 1 { found = inBase }
            if found.count == 1, let match = found.first {
                let url = URL(fileURLWithPath: match)
                let inside = match.hasPrefix(layout.root.path + "/")
                return LinkRepair(original: target,
                                  replacement: inside ? Self.relative(from: fileDir, to: url) : match,
                                  how: L("Found \(MemoryScanner.tilde(url)) — the only file on this Mac with this path."))
            }
            if found.count > 1 {
                return LinkRepair(original: target, replacement: nil,
                                  how: L("\(found.count) files on this Mac match; Embarsy can't tell which one. The link is removed, its text stays."))
            }
        }
        return LinkRepair(original: target, replacement: nil,
                          how: L("The target isn't anywhere Embarsy can find. The link is removed, its text stays."))
    }

    /// A link that works but points at a copy the migration left behind: it should point at
    /// where that content lives in the base now, or nowhere. Nil when the link is fine.
    func leftBehindRepair(for target: String, in file: URL) -> LinkRepair? {
        var path = target
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if let range = path.range(of: #":\d+$"#, options: .regularExpression) { path.removeSubrange(range) }
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.isEmpty, !decoded.contains("://") else { return nil }
        let absolute = decoded.hasPrefix("/") ? decoded
            : file.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL.path
        guard map.isLeftBehind(absolute, vault: layout) else { return nil }
        if let now = map.current(of: MigrationMap.key(absolute)),
           FileManager.default.fileExists(atPath: layout.root.appendingPathComponent(now).path) {
            return LinkRepair(original: target,
                              replacement: Self.relative(from: file.deletingLastPathComponent(), to: layout.root.appendingPathComponent(now)),
                              how: L("Its content went into \(now) with the migration."))
        }
        return LinkRepair(original: target, replacement: nil,
                          how: L("The migration didn't bring this file into the base. The link is removed, its text stays."))
    }

    static func spotlight(name: String, under home: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", home.path, "-name", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// `to` as seen from the folder `from`, e.g. "../../experience".
    static func relative(from: URL, to: URL) -> String {
        let a = from.standardizedFileURL.pathComponents
        let b = to.standardizedFileURL.pathComponents
        var common = 0
        while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
        let ups = Array(repeating: "..", count: a.count - common)
        let parts = ups + b[common...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}

// MARK: - Applying

enum HealthFixer {
    /// Carries out one fix. Edits only files inside the base.
    static func apply(_ fix: HealthFix, layout: VaultLayout, home: URL) throws {
        let inside = { (url: URL) in url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(layout.root.standardizedFileURL.resolvingSymlinksInPath().path + "/") }
        switch fix {
        case .moveLeftovers(let paths):
            let problems = MemoryPublisher(layout: layout, home: home).moveAsideLeftovers(paths)
            if !problems.isEmpty {
                throw NSError(domain: "Embarsy", code: 1, userInfo: [NSLocalizedDescriptionKey: problems.joined(separator: " ")])
            }

        case .repairLinks(let file, let repairs):
            guard inside(file), var text = try? String(contentsOf: file, encoding: .utf8) else { return }
            for repair in repairs {
                if let replacement = repair.replacement {
                    text = text.replacingOccurrences(of: "](\(repair.original))", with: "](\(replacement))")
                } else {
                    let pattern = #"\[([^\]]*)\]\("# + NSRegularExpression.escapedPattern(for: repair.original) + #"\)"#
                    text = text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
                }
            }
            try text.write(to: file, atomically: true, encoding: .utf8)

        case .setSkillName(let file, let name):
            guard inside(file) else { return }
            try FrontmatterEdit.set("name", to: name, quoted: false, in: file)

        case .setDescription(let file, let text):
            guard inside(file) else { return }
            try FrontmatterEdit.set("description", to: text, quoted: true, in: file)

        case .adoptSkill(let from, let name, _):
            let target = layout.adoptedSkills.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw NSError(domain: "Embarsy", code: 1, userInfo: [NSLocalizedDescriptionKey: L("The base already has a skill named \(name).")])
            }
            try FileManager.default.createDirectory(at: layout.adoptedSkills, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: from.resolvingSymlinksInPath(), to: target)

        case .keepCopy(_, let chosen, _, let baseFolder):
            guard inside(baseFolder) else { return }
            let source = chosen.resolvingSymlinksInPath()
            guard source.path != baseFolder.resolvingSymlinksInPath().path else { return }
            // The base's own version is already committed (fixes start by recording outside
            // changes), so replacing it loses nothing.
            let staging = baseFolder.deletingLastPathComponent().appendingPathComponent(".\(baseFolder.lastPathComponent).keeping")
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: baseFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: staging)
            try? FileManager.default.removeItem(at: baseFolder)
            try FileManager.default.moveItem(at: staging, to: baseFolder)

        case .publish:
            break   // MemoryService publishes once, after the file fixes.

        case .quoteFrontmatter(let file, let keys):
            guard inside(file), let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            var lines = text.components(separatedBy: "\n")
            guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
                  let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return }
            for i in 1..<end {
                let line = lines[i]
                guard line.first != " ", line.first != "\t", let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard keys.contains(key), MemoryScanner.breaksStrictYAML(value) else { continue }
                lines[i] = "\(key): \(CoreFile.jsonString(value))"
            }
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        case .revertVendor(let name, let folder, let hash):
            guard inside(folder) else { return }
            try VendorLock.revert(name: name, folder: folder, recordedHash: hash, layout: layout)

        case .updateVendor(let name, let from, let folder):
            guard inside(folder) else { return }
            try VendorLock.update(name: name, from: from, folder: folder, layout: layout)

        case .mergeNotes(let keep, let absorb):
            guard inside(keep), inside(absorb),
                  var kept = try? String(contentsOf: keep, encoding: .utf8),
                  let absorbed = try? String(contentsOf: absorb, encoding: .utf8) else { return }
            let parts = MarkdownRenderer.split(absorbed)
            let title = parts.fields.first { $0.0 == "title" }?.1 ?? absorb.deletingPathExtension().lastPathComponent
            let date = ISO8601DateFormatter.dateOnly.string(from: Date())
            // The absorbed note's own top heading would repeat the section title.
            var body = parts.body.trimmed
            if body.hasPrefix("# "), let newline = body.firstIndex(of: "\n") { body = String(body[newline...]).trimmed }
            if let range = kept.range(of: #"(?m)^updated: .*$"#, options: .regularExpression) { kept.replaceSubrange(range, with: "updated: \(date)") }
            if !kept.hasSuffix("\n") { kept += "\n" }
            kept += "\n## \(title) (merged \(date))\n\n\(body)\n"
            try kept.write(to: keep, atomically: true, encoding: .utf8)

            // Links to the absorbed note now lead to the one that holds its text.
            let enumerator = FileManager.default.enumerator(at: layout.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension.lowercased() == "md", file != absorb,
                      !file.path.hasPrefix(layout.archive.path + "/"),
                      var text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                var changed = false
                for target in Set(MemoryScanner.markdownLinkTargets(in: text)) {
                    var path = target
                    if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
                    let resolved = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : file.deletingLastPathComponent().appendingPathComponent(path)).standardizedFileURL
                    guard resolved.path == absorb.standardizedFileURL.path else { continue }
                    text = text.replacingOccurrences(of: "](\(target))", with: "](\(LinkResolver.relative(from: file.deletingLastPathComponent(), to: keep)))")
                    changed = true
                }
                if changed { try text.write(to: file, atomically: true, encoding: .utf8) }
            }
            let archived = layout.archive.appendingPathComponent("merged").appendingPathComponent(MemoryScanner.relativePath(of: absorb, in: layout.root))
            try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: archived.path) { try FileManager.default.removeItem(at: archived) }
            try FileManager.default.moveItem(at: absorb, to: archived)

        case .stripLineNumbers(let files, _):
            for file in files where inside(file) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let stripped = text.replacingOccurrences(of: #"(\]\([^)\s]+?):\d+\)"#, with: "$1)", options: .regularExpression)
                if stripped != text { try stripped.write(to: file, atomically: true, encoding: .utf8) }
            }
        }
    }
}

// MARK: - Near-duplicate notes (H10)

enum NearDuplicates {
    /// Which of two duplicates stays: the one the base links to more (moving it would break
    /// fewer links), then the older one (the original, not the copy), then the longer one.
    static func chooseKeep(_ a: URL, _ b: URL, vault: VaultLayout) -> (keep: URL, absorb: URL) {
        func inbound(_ note: URL) -> Int {
            let target = note.standardizedFileURL.path
            var count = 0
            let enumerator = FileManager.default.enumerator(at: vault.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension.lowercased() == "md", file.standardizedFileURL.path != target,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                count += MemoryScanner.markdownLinkTargets(in: text).filter { link in
                    var path = link
                    if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
                    let resolved = path.hasPrefix("/") ? URL(fileURLWithPath: path) : file.deletingLastPathComponent().appendingPathComponent(path)
                    return resolved.standardizedFileURL.path == target
                }.count
            }
            return count
        }
        let created = { (url: URL) in (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture }
        let size = { (url: URL) in (try? Data(contentsOf: url).count) ?? 0 }
        let (la, lb) = (inbound(a), inbound(b))
        if la != lb { return la > lb ? (a, b) : (b, a) }
        let (ca, cb) = (created(a), created(b))
        if ca != cb { return ca < cb ? (a, b) : (b, a) }
        return size(a) >= size(b) ? (a, b) : (b, a)
    }

    /// Two notes this alike say the same thing. Measured on a real base: related but
    /// different notes topped out at 0.86; an edited copy of a note scores ~0.98.
    static let threshold = 0.92

    /// Pairs of knowledge / people notes whose overall meaning (the mean of their passages'
    /// vectors) is nearly the same. Experience is left out: notes on similar work are alike
    /// by nature, and that's not duplication.
    static func find(config: MemorySearchConfig, vault: VaultLayout) async -> [HealthFinding] {
        guard let points = await MemorySearch.allVectors(config: config) else { return [] }
        var sums: [String: [Double]] = [:]
        for (path, vector) in points where path.hasPrefix("knowledge/") || path.hasPrefix("people/") {
            if var sum = sums[path] {
                for i in sum.indices where i < vector.count { sum[i] += vector[i] }
                sums[path] = sum
            } else {
                sums[path] = vector
            }
        }
        let centroids = sums.mapValues { v -> [Double] in
            let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return n > 0 ? v.map { $0 / n } : v
        }
        let paths = centroids.keys.sorted()
        var out: [HealthFinding] = []
        for i in paths.indices {
            for j in paths.indices where j > i {
                let a = centroids[paths[i]]!, b = centroids[paths[j]]!
                var dot = 0.0
                for k in 0..<min(a.count, b.count) { dot += a[k] * b[k] }
                guard dot >= threshold else { continue }
                let first = vault.root.appendingPathComponent(paths[i]), second = vault.root.appendingPathComponent(paths[j])
                guard FileManager.default.fileExists(atPath: first.path), FileManager.default.fileExists(atPath: second.path) else { continue }
                let (keep, absorb) = chooseKeep(first, second, vault: vault)
                out.append(HealthFinding(code: "H10", severity: .warning,
                                         title: L("\(paths[i]) and \(paths[j]) say nearly the same"),
                                         detail: L("Their meaning matches at \(String(format: "%.2f", dot)). Two notes on one subject drift apart: an agent may recall the older one. Merge them, or make each about something distinct."),
                                         paths: [first, second], weight: Int(dot * 100),
                                         fix: .mergeNotes(keep: keep, absorb: absorb)))
            }
        }
        return out
    }
}

/// Rewrites one top-level frontmatter field of a SKILL.md, block scalars included.
enum FrontmatterEdit {
    static func set(_ key: String, to value: String, quoted: Bool, in file: URL) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return }
        let rendered = "\(key): " + (quoted ? CoreFile.jsonString(value) : value)
        guard let start = (1..<end).first(where: { lines[$0].hasPrefix(key + ":") }) else {
            lines.insert(rendered, at: 1)
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            return
        }
        // The old value may continue on indented lines (a | or > block): they go too.
        var stop = start + 1
        while stop < end, let first = lines[stop].first, first == " " || first == "\t" || lines[stop].trimmingCharacters(in: .whitespaces).isEmpty {
            stop += 1
        }
        lines.replaceSubrange(start..<stop, with: [rendered])
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
