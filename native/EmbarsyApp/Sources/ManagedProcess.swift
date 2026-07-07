import Foundation

struct ProcessSpec {
    let service: ManagedService
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let logFile: URL
    let workingDirectory: URL?
}

/// Exit information captured by the termination handler — used to tell "process died at
/// startup" apart from "process is alive but not healthy yet", and to name kernel kills
/// (SIGKILL / Code Signature Invalid) instead of a generic health-check message.
struct ProcessExit {
    let status: Int32
    let reason: Process.TerminationReason
    let date: Date

    var isSignalKill: Bool { reason == .uncaughtSignal && status == SIGKILL }

    var summary: String {
        switch reason {
        case .uncaughtSignal:
            "terminated by signal \(status)\(status == SIGKILL ? " (SIGKILL — possibly killed by macOS code-signing enforcement)" : "")"
        default:
            "exited with code \(status)"
        }
    }
}

final class ManagedProcess {
    let spec: ProcessSpec
    private(set) var process: Process?

    /// Exit info of the most recently started process, set from the termination handler.
    /// Read from the main actor; written from the handler's arbitrary thread via the lock.
    /// The generation counter keeps a LATE handler from a previous process (waitUntilExit
    /// does not wait for the termination handler) from poisoning the next start's exit info.
    private let exitLock = NSLock()
    private var _lastExit: ProcessExit?
    private var startGeneration = 0
    var lastExit: ProcessExit? {
        exitLock.lock()
        defer { exitLock.unlock() }
        return _lastExit
    }

    /// Byte size of the log file at the moment the process was last started — lets callers
    /// read back exactly what the child wrote during a failed startup.
    private(set) var logOffsetAtStart: UInt64 = 0

    /// Rotate the child log once it exceeds this size (keep one previous generation).
    private static let maxLogBytes: UInt64 = 10 * 1024 * 1024

    init(spec: ProcessSpec) {
        self.spec = spec
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    /// PID of the running process (nil when not running) — used for live CPU/memory sampling.
    var pid: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    func start() throws {
        guard !isRunning else { return }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: spec.logFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        rotateLogIfNeeded()
        if !fileManager.fileExists(atPath: spec.logFile.path) {
            fileManager.createFile(atPath: spec.logFile.path, contents: nil)
        }

        // O_APPEND (not seekToEnd) so the child's writes always land at the current end of
        // file — this keeps the log correct across rotation/truncation while running.
        let fd = open(spec.logFile.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Cannot open log file at \(spec.logFile.path)",
            ])
        }
        let logHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        logOffsetAtStart = (try? fileManager.attributesOfItem(atPath: spec.logFile.path)[.size] as? UInt64) ?? 0

        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, new in new }
        process.currentDirectoryURL = spec.workingDirectory
        process.standardOutput = logHandle
        process.standardError = logHandle

        exitLock.lock()
        _lastExit = nil
        startGeneration += 1
        let generation = startGeneration
        exitLock.unlock()
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let exit = ProcessExit(
                status: finished.terminationStatus,
                reason: finished.terminationReason,
                date: Date()
            )
            self.exitLock.lock()
            if self.startGeneration == generation {
                self._lastExit = exit
            }
            self.exitLock.unlock()
        }

        try process.run()
        self.process = process
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
        self.process = nil
    }

    /// Tail of everything the child appended to its log since the last start (capped).
    /// Returns nil when the log cannot be read; an empty string means "wrote nothing".
    func logTailSinceStart(maxBytes: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: spec.logFile) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        guard end > logOffsetAtStart else { return "" }
        let available = end - logOffsetAtStart
        let readFrom = available > UInt64(maxBytes) ? end - UInt64(maxBytes) : logOffsetAtStart
        try? handle.seek(toOffset: readFrom)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8) ?? "<non-UTF8 output, \(data.count) bytes>"
    }

    /// Copy-truncate rotation for a RUNNING child: copy the newest tail into `<name>.1.log`,
    /// then truncate the live file to zero. Safe because the child writes with O_APPEND —
    /// after truncation its next write lands at the new end of file. Returns true if rotated.
    @discardableResult
    func capLogWhileRunning(keepTailBytes: Int = 1024 * 1024) -> Bool {
        let fileManager = FileManager.default
        guard
            isRunning,
            let size = (try? fileManager.attributesOfItem(atPath: spec.logFile.path)[.size]) as? UInt64,
            size > Self.maxLogBytes,
            let reader = try? FileHandle(forReadingFrom: spec.logFile)
        else { return false }
        defer { try? reader.close() }
        try? reader.seek(toOffset: size > UInt64(keepTailBytes) ? size - UInt64(keepTailBytes) : 0)
        let tail = (try? reader.readToEnd()) ?? Data()
        try? fileManager.removeItem(at: rotatedLogURL)
        try? tail.write(to: rotatedLogURL)
        truncate(spec.logFile.path, 0)
        // The startup-failure tail now starts at the file's new beginning.
        logOffsetAtStart = 0
        return true
    }

    private var rotatedLogURL: URL {
        spec.logFile.deletingPathExtension()
            .appendingPathExtension("1")
            .appendingPathExtension(spec.logFile.pathExtension)
    }

    /// Rename an oversized log to `<name>.1` (replacing the previous generation) so child
    /// logs cannot grow unbounded across restarts. Called only while the process is stopped.
    private func rotateLogIfNeeded() {
        let fileManager = FileManager.default
        guard
            let size = (try? fileManager.attributesOfItem(atPath: spec.logFile.path)[.size]) as? UInt64,
            size > Self.maxLogBytes
        else { return }
        try? fileManager.removeItem(at: rotatedLogURL)
        try? fileManager.moveItem(at: spec.logFile, to: rotatedLogURL)
    }
}
