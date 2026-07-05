import Foundation

struct ProcessRunner {
    struct Result {
        let exitCode: Int32
        let output: String
    }

    enum RunnerError: LocalizedError {
        case timedOut(command: String, seconds: TimeInterval, output: String)

        var errorDescription: String? {
            switch self {
            case .timedOut(let command, let seconds, let output):
                "\(command) timed out after \(Int(seconds)) seconds. Output: \(output)"
            }
        }
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> Result {
        let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")

        return try await withCheckedThrowingContinuation { continuation in
            let state = RunnerState<Result>(continuation: continuation)

            do {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                process.currentDirectoryURL = workingDirectory
                process.standardOutput = pipe
                process.standardError = pipe

                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    state.append(data)
                    if let onOutput, let output = String(data: data, encoding: .utf8), !output.isEmpty {
                        onOutput(output)
                    }
                }

                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let finalData = pipe.fileHandleForReading.readDataToEndOfFile()
                    state.append(finalData)
                    if let onOutput, let output = String(data: finalData, encoding: .utf8), !output.isEmpty {
                        onOutput(output)
                    }
                    state.resume(.success(Result(exitCode: process.terminationStatus, output: state.outputString())))
                }
                try process.run()

                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        let shouldTerminate = !state.hasResumed && process.isRunning
                        guard shouldTerminate else { return }
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if process.isRunning { process.interrupt() }
                        }
                        state.resume(.failure(RunnerError.timedOut(
                            command: command,
                            seconds: timeout,
                            output: state.outputString()
                        )))
                    }
                }
            } catch {
                state.resume(.failure(error))
            }
        }
    }
}

private final class RunnerState<Success>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var output = Data()
    private let continuation: CheckedContinuation<Success, Error>

    init(continuation: CheckedContinuation<Success, Error>) {
        self.continuation = continuation
    }

    var hasResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didResume
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        output.append(data)
        lock.unlock()
    }

    func outputString() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: output, encoding: .utf8) ?? ""
    }

    func resume(_ result: Swift.Result<Success, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
