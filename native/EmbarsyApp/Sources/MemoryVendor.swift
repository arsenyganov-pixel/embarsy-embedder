import CryptoKit
import Foundation

/// Someone else's skills in `skills/vendor/` and their record, `skills/vendor.lock.yaml`
/// (docs/memory-spec.md §5.6). A vendor skill isn't edited: the record holds the hash of its
/// files as installed, so H07 can tell when it changed, and where it came from, so H08 can tell
/// when that source has moved on.
struct VendorLockEntry: Equatable {
    var name: String
    /// Relative to `skills/`.
    var path: String
    var sourceKind: String = "unknown"
    var sourcePath: String = ""
    var sourceURL: String = ""
    var author: String = ""
    var treeHash: String = ""
    var installedAt: String = ""
}

enum VendorLock {
    /// Reads the record. The file is Embarsy's own, in the shape it writes, so a small
    /// indentation-based reader is enough.
    static func read(_ layout: VaultLayout) -> [VendorLockEntry] {
        guard let text = try? String(contentsOf: layout.vendorLock, encoding: .utf8) else { return [] }
        var entries: [VendorLockEntry] = []
        var current: VendorLockEntry?
        var inSource = false
        for raw in text.components(separatedBy: "\n") {
            let indent = raw.prefix(while: { $0 == " " }).count
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
                value = decoded
            }
            switch indent {
            case 2:
                if let entry = current { entries.append(entry) }
                current = VendorLockEntry(name: key, path: "")
                inSource = false
            case 4:
                inSource = key == "source"
                switch key {
                case "path": current?.path = value
                case "author": current?.author = value
                case "tree_sha256": current?.treeHash = value
                case "installed_at": current?.installedAt = value
                default: break
                }
            case 6 where inSource:
                switch key {
                case "kind": current?.sourceKind = value
                case "path": current?.sourcePath = value
                case "url": current?.sourceURL = value
                default: break
                }
            default: break
            }
        }
        if let entry = current { entries.append(entry) }
        return entries.filter { !$0.path.isEmpty }
    }

    /// Hash of every file under the folder: relative path and bytes, Finder litter left out —
    /// the same recipe the migration used when it wrote the record.
    static func treeHash(_ folder: URL) -> String {
        var hasher = SHA256()
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent != ".DS_Store",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append(url)
        }
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(MemoryScanner.relativePath(of: file, in: folder).utf8))
            if let data = try? Data(contentsOf: file) { hasher.update(data: data) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// H07 and H08 for every recorded vendor skill.
    static func findings(_ layout: VaultLayout) -> [HealthFinding] {
        var out: [HealthFinding] = []
        for entry in read(layout) {
            let folder = layout.skills.appendingPathComponent(entry.path)
            guard FileManager.default.fileExists(atPath: folder.path), !entry.treeHash.isEmpty else { continue }
            let hash = treeHash(folder)
            if hash != entry.treeHash {
                out.append(HealthFinding(
                    code: "H07", severity: .error,
                    title: L("\(entry.name) was changed, but it's someone else's skill"),
                    detail: L("Vendor skills are kept exactly as their author made them, so an update can replace them cleanly. Put your own additions in a skill of your own that builds on this one. Embarsy can put \(entry.name) back the way it was installed; your changes stay in the base's history."),
                    paths: [folder], fix: .revertVendor(name: entry.name, folder: folder, recordedHash: entry.treeHash)))
                continue
            }
            // H08 — the recorded source is a real folder outside the base and now holds
            // something else. (A source that became a link into the base is the base itself.)
            guard entry.sourceKind == "path", !entry.sourcePath.isEmpty else { continue }
            let source = URL(fileURLWithPath: entry.sourcePath)
            let resolved = source.resolvingSymlinksInPath().path
            guard FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path),
                  !resolved.hasPrefix(layout.root.resolvingSymlinksInPath().path + "/") else { continue }
            let sourceHash = treeHash(source.resolvingSymlinksInPath())
            guard sourceHash != entry.treeHash else { continue }
            out.append(HealthFinding(
                code: "H08", severity: .info,
                title: L("A newer \(entry.name) is available"),
                detail: L("The folder \(entry.name) was installed from has changed since. Updating copies it into the base; the version you have stays in the base's history."),
                paths: [source, folder], fix: .updateVendor(name: entry.name, from: source, folder: folder)))
        }
        return out
    }

    /// Restores the skill's files from the commit that recorded its hash.
    static func revert(name: String, folder: URL, recordedHash: String, layout: VaultLayout) throws {
        let git = MemoryGit(root: layout.root)
        let lockRel = MemoryScanner.relativePath(of: layout.vendorLock, in: layout.root)
        let rel = MemoryScanner.relativePath(of: folder, in: layout.root)
        let found = git.run(["log", "-1", "--format=%H", "-S", recordedHash, "--", lockRel])
        let commit = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard found.status == 0, !commit.isEmpty else {
            throw NSError(domain: "Embarsy", code: 1, userInfo: [NSLocalizedDescriptionKey: L("The base's history has no record of \(name) as installed, so it can't be put back.")])
        }
        // The edited version is already committed (fixes start by recording outside changes),
        // so clearing the folder loses nothing.
        try? FileManager.default.removeItem(at: folder)
        let restored = git.run(["checkout", commit, "--", rel])
        guard restored.status == 0, treeHash(folder) == recordedHash else {
            throw NSError(domain: "Embarsy", code: 1, userInfo: [NSLocalizedDescriptionKey: L("\(name) couldn't be put back as installed: \(restored.output)")])
        }
    }

    /// Copies the source's current version in and records its hash.
    static func update(name: String, from source: URL, folder: URL, layout: VaultLayout) throws {
        let fm = FileManager.default
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".\(name).updating")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source.resolvingSymlinksInPath(), to: staging)
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: staging, to: folder)
        let hash = treeHash(folder)
        guard var text = try? String(contentsOf: layout.vendorLock, encoding: .utf8) else { return }
        // Only this entry's hash and date change; the rest of the record stays as written.
        var lines = text.components(separatedBy: "\n")
        var inEntry = false
        for i in lines.indices {
            let indent = lines[i].prefix(while: { $0 == " " }).count
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if indent == 2 { inEntry = trimmed == name + ":" }
            guard inEntry, indent == 4 else { continue }
            if trimmed.hasPrefix("tree_sha256:") { lines[i] = "    tree_sha256: \(hash)" }
            if trimmed.hasPrefix("installed_at:") { lines[i] = "    installed_at: \(ISO8601DateFormatter.dateOnly.string(from: Date()))" }
        }
        text = lines.joined(separator: "\n")
        try text.write(to: layout.vendorLock, atomically: true, encoding: .utf8)
    }
}

/// H06 — the core every agent loads in every session has outgrown its budget.
enum CoreBudget {
    static let limit = 4096

    static func finding(_ layout: VaultLayout) -> HealthFinding? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: layout.agentsMd.path))?[.size] as? Int,
              size > limit else { return nil }
        var finding = HealthFinding(
            code: "H06", severity: .warning,
            title: L("The core is \(size / 1024) KB — over its 4 KB budget"),
            detail: L("Every agent reads AGENTS.md at the start of every session, so each extra line costs every conversation. Shorten Memory → Core: keep only what must hold always, and move the rest into knowledge notes, which agents find with recall."),
            paths: [layout.agentsMd])
        finding.assist = .shortenCore
        return finding
    }
}
