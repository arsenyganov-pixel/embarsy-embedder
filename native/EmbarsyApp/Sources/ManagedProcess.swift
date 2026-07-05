import Foundation

struct ProcessSpec {
    let service: ManagedService
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let logFile: URL
    let workingDirectory: URL?
}

final class ManagedProcess {
    let spec: ProcessSpec
    private(set) var process: Process?

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
        if !fileManager.fileExists(atPath: spec.logFile.path) {
            fileManager.createFile(atPath: spec.logFile.path, contents: nil)
        }

        let logHandle = try FileHandle(forWritingTo: spec.logFile)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, new in new }
        process.currentDirectoryURL = spec.workingDirectory
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        self.process = process
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
        self.process = nil
    }
}
