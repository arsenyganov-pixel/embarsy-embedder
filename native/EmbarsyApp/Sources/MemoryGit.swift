import Foundation

/// History of the memory base, for agents (docs/memory-spec.md §14, "Git — история базы").
///
/// Never shown in the UI. Embarsy commits only in a repository it created itself (marked
/// inside .git, so the marker is never committed); a repository the user made is read, not
/// written. On a Mac without Command Line Tools there is no history at all — calling
/// /usr/bin/git there would pop the system's "install developer tools" dialog.
struct MemoryGit {
    let root: URL

    static let markerName = "embarsy-managed"
    private static let candidates = ["/Library/Developer/CommandLineTools/usr/bin/git",
                                     "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
                                     "/opt/homebrew/bin/git", "/usr/local/bin/git"]

    /// A git binary that runs without prompting to install anything.
    static var executable: URL? {
        candidates.lazy.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private var gitDir: URL { root.appendingPathComponent(".git") }
    private var marker: URL { gitDir.appendingPathComponent(Self.markerName) }

    var hasRepository: Bool { FileManager.default.fileExists(atPath: gitDir.path) }
    var isManaged: Bool { FileManager.default.fileExists(atPath: marker.path) }

    /// Creates the repository and the first commit. Does nothing if git is missing or a
    /// repository already exists.
    @discardableResult
    func initialize(message: String) -> Bool {
        guard Self.executable != nil, !hasRepository else { return false }
        guard run(["init", "--quiet", "--initial-branch=main"]).status == 0 else { return false }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        return commit(message: message, trailers: ["Approved-by": "user"]) != .failed
    }

    enum CommitResult: Equatable {
        case committed
        case nothingToCommit
        case skippedNotManaged
        case blockedBySecret(String)
        case failed
    }

    /// Commits everything that changed. Refuses if a changed file looks like it holds a
    /// secret: once in history it can't be taken back out.
    @discardableResult
    func commit(message: String, trailers: [String: String]) -> CommitResult {
        guard Self.executable != nil, isManaged else { return .skippedNotManaged }
        let status = run(["status", "--porcelain", "-z", "--untracked-files=all"])
        guard status.status == 0 else { return .failed }
        let changed = Self.changedPaths(fromPorcelainZ: status.output)
        guard !changed.isEmpty else { return .nothingToCommit }

        for path in changed {
            let url = root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (kind, pattern) in MemoryScanner.secretPatterns where text.range(of: pattern, options: .regularExpression) != nil {
                return .blockedBySecret(L("\(path) looks like it contains a \(kind)"))
            }
        }

        guard run(["add", "--all"]).status == 0 else { return .failed }
        let trailerText = trailers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        let full = trailerText.isEmpty ? message : message + "\n\n" + trailerText
        return run(["commit", "--quiet", "--no-verify", "-m", full]).status == 0 ? .committed : .failed
    }

    /// Edits made outside Embarsy since the last commit, recorded before Embarsy's own
    /// change so history shows who changed what.
    func commitExternalChanges() {
        _ = commit(message: "External changes", trailers: ["Agent": "unknown"])
    }

    static func changedPaths(fromPorcelainZ output: String) -> [String] {
        // Entries are "XY path\0"; a rename adds the old path as an extra entry.
        var paths: [String] = []
        var skipNext = false
        for entry in output.split(separator: "\0", omittingEmptySubsequences: true) {
            if skipNext { skipNext = false; continue }
            guard entry.count > 3 else { continue }
            let code = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))
            if code.contains("R") || code.contains("C") { skipNext = true }
        }
        return paths
    }

    // MARK: Running git

    struct Output {
        let status: Int32
        let output: String
    }

    @discardableResult
    func run(_ arguments: [String]) -> Output {
        guard let git = Self.executable else { return Output(status: -1, output: "") }
        let process = Process()
        process.executableURL = git
        // Identity is passed per call so the user's global git config is never needed or touched.
        process.arguments = ["-C", root.path, "-c", "user.name=Embarsy", "-c", "user.email=embarsy@localhost",
                             "-c", "commit.gpgsign=false", "-c", "core.quotepath=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Output(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
