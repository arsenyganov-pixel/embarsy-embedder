import CryptoKit
import Foundation

/// Indexes project folders for Claude Code and Codex by running the bridge that ships inside
/// the app bundle — no npm, no terminal, no Node on the user's PATH.
///
/// One run at a time, deliberately: every run embeds through the same local model, and two
/// in parallel do not finish sooner, they just make both slower and the progress meaningless.
@MainActor
final class IndexingService: ObservableObject {
    enum Run: Equatable {
        case running(progress: String)
        case finished(summary: String)
        case failed(message: String)
    }

    /// Keyed by the folder's absolute path.
    @Published private(set) var runs: [String: Run] = [:]
    @Published private(set) var activeFolder: String?

    var isBusy: Bool { activeFolder != nil }

    private let runner = ProcessRunner()

    /// A stable collection name for a folder that has never been indexed.
    ///
    /// The basename alone is not enough: two checkouts called `api` would land in one
    /// collection and silently mix their code. The path hash keeps them apart, and being
    /// deterministic means re-adding the same folder reuses its index instead of duplicating it.
    static func collectionName(for folder: URL) -> String {
        let base = folder.lastPathComponent.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        return "embarsy-\(base.isEmpty ? "project" : base)-\(digest)"
    }

    func index(folder: URL, collection: String, paths: AppPaths, config: EmbarsyConfig) async -> Bool {
        guard !isBusy else { return false }
        let key = folder.standardizedFileURL.path
        activeFolder = key
        runs[key] = .running(progress: "Starting…")
        defer { activeFolder = nil }

        guard FileManager.default.isExecutableFile(atPath: paths.bundledNode.path),
              FileManager.default.fileExists(atPath: paths.bundledBridgeIndex.path) else {
            runs[key] = .failed(message: "This build of Embarsy does not include the editor bridge. Reinstall the latest version.")
            return false
        }

        let tail = OutputTail()
        do {
            let result = try await runner.run(
                executable: paths.bundledNode,
                arguments: [paths.bundledBridgeIndex.path, key, "--collection", collection],
                environment: [
                    // Labels the requests in Activity, so a refresh started from the app is not
                    // mistaken for an editor at work.
                    "EMBARSY_CLIENT": "embarsy-app",
                    "OPENAI_BASE_URL": config.apiBaseURL.appendingPathComponent("v1").absoluteString,
                    "OPENAI_API_KEY": config.embarsyAPIKey,
                    "QDRANT_URL": config.qdrantProxyBaseURL.absoluteString,
                    "QDRANT_API_KEY": config.qdrantAPIKey,
                ],
                workingDirectory: folder,
                timeout: nil,
                onOutput: { [weak self] chunk in
                    tail.append(chunk)
                    guard let progress = Self.progress(from: chunk) else { return }
                    Task { @MainActor in self?.runs[key] = .running(progress: progress) }
                }
            )
            if result.exitCode == 0 {
                runs[key] = .finished(summary: Self.summary(from: result.output) ?? "Indexed")
                return true
            }
            runs[key] = .failed(message: Self.failureLine(from: result.output))
            return false
        } catch {
            let captured = tail.text
            runs[key] = .failed(message: Self.failureLine(from: captured.isEmpty ? error.localizedDescription : captured))
            return false
        }
    }

    // MARK: Reading the bridge's output

    /// `Found 2946 indexable files…` and `indexed 25 files, 300 chunks…` → a short live line.
    static func progress(from chunk: String) -> String? {
        let lines = chunk.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines.reversed() {
            if line.hasPrefix("indexed "), let end = line.firstIndex(of: "…") ?? line.firstIndex(of: ".") {
                return String(line[..<end]).replacingOccurrences(of: "indexed ", with: "Indexed ")
            }
            if line.hasPrefix("Found "), let range = line.range(of: " in ") {
                return String(line[..<range.lowerBound])
            }
        }
        return nil
    }

    /// `Done in 12.3s — 5 indexed, 2942 unchanged, …; 81 chunks upserted into "x".` → the
    /// part a person cares about, without the collection id.
    static func summary(from output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.contains("Done in") })
        else { return nil }
        let text = String(line).trimmingCharacters(in: .whitespaces)
        if let into = text.range(of: " into ") { return String(text[..<into.lowerBound]) }
        return text
    }

    /// The most useful single line of a failure — the bridge prints its reason last.
    static func failureLine(from output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last(where: { $0.localizedCaseInsensitiveContains("fail") || $0.contains("Error") })
            ?? lines.last
            ?? "Indexing stopped without a message."
    }
}

/// The last few KB of a run's output, written from the process's reader thread and read back
/// on the main actor — hence the lock rather than a plain captured string.
private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        buffer = String((buffer + chunk).suffix(4000))
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
