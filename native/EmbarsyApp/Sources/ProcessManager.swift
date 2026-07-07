import Foundation

@MainActor
final class ProcessManager: ObservableObject {
    @Published private(set) var statuses: [ManagedService: ServiceStatus] = Dictionary(
        uniqueKeysWithValues: ManagedService.allCases.map { ($0, .unknown) }
    )
    @Published private(set) var messages: [ManagedService: String] = Dictionary(
        uniqueKeysWithValues: ManagedService.allCases.map { ($0, "Not checked yet.") }
    )

    private let paths: AppPaths
    private var config: EmbarsyConfig
    private let health = HealthService()
    private let debugLog: DebugLogService?
    private var processes: [ManagedService: ManagedProcess] = [:]

    init(paths: AppPaths, config: EmbarsyConfig, debugLog: DebugLogService? = nil) {
        self.paths = paths
        self.config = config
        self.debugLog = debugLog
        configureProcesses()
    }

    /// PIDs of the running managed processes (qdrant / ollama / api) for live metrics.
    var runningPIDs: [Int32] {
        ManagedService.allCases.compactMap { processes[$0]?.pid }
    }

    func updateConfig(_ config: EmbarsyConfig) {
        self.config = config
        configureProcesses()
    }

    func startAll() async {
        for service in [ManagedService.qdrant, .ollama, .api] {
            await start(service)
            if statuses[service] == .failed { break }
        }
    }

    func stopAll() {
        for service in [ManagedService.api, .qdrant, .ollama] {
            stop(service)
        }
    }

    func hardResetCleanup() {
        debugLog?.append("Hard reset cleanup requested", category: "process")
        forceCleanStop(message: "Components removed. Install required.")
    }

    func forceCleanStop(message: String = "Stopped for clean start.") {
        debugLog?.append("Force clean stop requested", category: "process")
        stopAll()
        terminateListenersOnManagedPorts()
        markAllStopped(message: message)
    }

    func markAllStopped(message: String) {
        statuses = Dictionary(uniqueKeysWithValues: ManagedService.allCases.map { ($0, .stopped) })
        messages = Dictionary(uniqueKeysWithValues: ManagedService.allCases.map { ($0, message) })
        debugLog?.append("All service statuses forced to stopped: \(message)", category: "process")
    }

    var allServicesRunning: Bool {
        ManagedService.allCases.allSatisfy { statuses[$0] == .running }
    }

    func validateBinaries() -> [BinaryCheck] {
        let fileManager = FileManager.default
        return [
            BinaryCheck(
                service: .qdrant,
                path: paths.bundledQdrant.path,
                isExecutable: fileManager.isExecutableFile(atPath: paths.bundledQdrant.path)
            ),
            BinaryCheck(
                service: .ollama,
                path: paths.bundledOllama.path,
                isExecutable: fileManager.isExecutableFile(atPath: paths.bundledOllama.path)
            ),
            BinaryCheck(
                service: .api,
                path: paths.bundledAPI.path,
                isExecutable: fileManager.isExecutableFile(atPath: paths.bundledAPI.path)
            ),
        ]
    }

    func start(_ service: ManagedService) async {
        if statuses[service] == .running {
            if await isServiceReady(service) {
                setStatus(service, .running, message: "Already running.")
                debugLog?.append("Skip start for \(service.title): already running with current configuration", category: "process")
                return
            }

            debugLog?.append("\(service.title) was marked Running, but health check failed with current configuration. Restarting listener on port \(managedPort(for: service)).", category: "process")
            terminateListeners(on: managedPort(for: service))
        }
        setStatus(service, .starting, message: "Starting \(service.title)...")
        debugLog?.append("Starting \(service.title)", category: "process")
        do {
            try paths.createDirectories()
            if service == .qdrant {
                try writeQdrantConfig()
            }
            guard validateBinaries().first(where: { $0.service == service })?.isExecutable == true else {
                setStatus(service, .failed, message: "Missing executable binary at \(binaryPath(for: service).path).")
                debugLog?.append(messages[service] ?? "Missing binary for \(service.title)", category: "process.error")
                return
            }
            try processes[service]?.start()
            setMessage(service, "Process started. Waiting for health at \(healthURL(for: service).absoluteString)...")
            debugLog?.append(messages[service] ?? "Waiting health for \(service.title)", category: "process")
            let wait = await waitUntilReady(service)
            if wait == .ready {
                setStatus(service, .running, message: "Running.")
            } else {
                reportStartupFailure(service, outcome: wait)
            }
            debugLog?.append("\(service.title) status after start: \(statuses[service, default: .unknown].title). \(messages[service] ?? "")", category: wait == .ready ? "process" : "process.error")
        } catch {
            setStatus(service, .failed, message: "Failed to start \(service.title): \(error.localizedDescription). Check \(logFile(for: service).path).")
            debugLog?.append(messages[service] ?? error.localizedDescription, category: "process.error")
        }
    }

    func stop(_ service: ManagedService) {
        processes[service]?.stop()
        setStatus(service, .stopped, message: "Stopped.")
        debugLog?.append("Stopped \(service.title)", category: "process")
    }

    func restart(_ service: ManagedService, reason: String) async {
        debugLog?.append("Restarting \(service.title): \(reason)", category: "process")
        stop(service)
        terminateListeners(on: managedPort(for: service))
        setStatus(service, .stopped, message: "Restart requested: \(reason)")
        await start(service)
    }

    func refreshAll() async {
        for service in ManagedService.allCases {
            await refresh(service)
        }
    }

    func refresh(_ service: ManagedService) async {
        let url = healthURL(for: service)
        let isReady = await isServiceReady(service)
        // Keep precise startup-failure diagnostics (exit status, code-signing guidance)
        // on screen: a dead service already reported .failed must not be downgraded to a
        // generic .stopped by the periodic post-start status reconciliation.
        if !isReady, statuses[service] == .failed, processes[service]?.isRunning != true {
            return
        }
        setStatus(
            service,
            isReady ? .running : (processes[service]?.isRunning == true ? .starting : .stopped),
            message: isReady ? "Health check OK." : "Health check is not ready at \(url.absoluteString) with current configuration."
        )
    }

    /// Copy-truncate any oversized log of a running child (ollama's llama-server slot logs
    /// alone can add hundreds of MB per day). Cheap when logs are small — one attribute
    /// read per service — so it can ride the store's periodic sampling tick.
    func capRunningLogs() {
        for service in ManagedService.allCases {
            // Never rotate mid-startup: the startup-failure diagnostics read the log tail
            // relative to the offset captured at start().
            guard statuses[service] != .starting else { continue }
            if processes[service]?.capLogWhileRunning() == true {
                debugLog?.append("Rotated oversized log for \(service.title)", category: "process")
            }
        }
    }

    func logFile(for service: ManagedService) -> URL {
        switch service {
        case .qdrant:
            paths.logsDirectory.appendingPathComponent("qdrant.log")
        case .ollama:
            paths.logsDirectory.appendingPathComponent("ollama.log")
        case .api:
            paths.logsDirectory.appendingPathComponent("api.log")
        }
    }

    enum StartupWaitOutcome: Equatable {
        case ready
        case processDied
        case timedOut
    }

    /// Readiness budget per service. The API is a PyInstaller onefile binary whose FIRST
    /// start after a (re)install can spend ~20s just extracting and code-sign-validating
    /// its bundled dylibs (observed in the 2026-07-07 install incident), so it gets a much
    /// longer budget. The wait below exits early the moment the child process dies, so a
    /// long budget never delays reporting a real crash.
    private func readyAttempts(for service: ManagedService) -> Int {
        switch service {
        case .api: 240      // 240 × 0.5s = up to 120s while the process stays alive
        case .qdrant, .ollama: 60   // up to 30s
        }
    }

    /// Poll health while the child is alive. Fails FAST (not after the full budget) when
    /// the process exits — that is what distinguishes "killed at exec / crashed" from
    /// "still starting"; the blind 15s wait used to hide exactly that difference.
    private func waitUntilReady(_ service: ManagedService) async -> StartupWaitOutcome {
        let attempts = readyAttempts(for: service)
        for _ in 0..<attempts {
            if await isServiceReady(service) { return .ready }
            if processes[service]?.isRunning != true {
                // Give the termination handler a beat to record the exit info.
                try? await Task.sleep(nanoseconds: 200_000_000)
                return .processDied
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .timedOut
    }

    /// Build a precise failure status: what the child wrote, how it exited, and — for the
    /// kernel code-signing kill — what the user should actually do. Also preserves the
    /// child's log tail in the debug log so failure evidence survives log wipes.
    private func reportStartupFailure(_ service: ManagedService, outcome: StartupWaitOutcome) {
        let process = processes[service]
        let exit = process?.lastExit
        let tail = process?.logTailSinceStart()

        var message: String
        switch outcome {
        case .processDied:
            if let exit, exit.isSignalKill {
                message = "\(service.title) was killed by macOS right after launch (code-signature enforcement). "
                    + "Restart your Mac; if it happens again, delete /Applications/Embarsy.app completely "
                    + "and copy the new version fresh instead of overwriting it."
            } else {
                message = "\(service.title) \(exit?.summary ?? "exited during startup"). Check \(logFile(for: service).path)."
            }
        case .timedOut:
            // Leave the process running: a service that turns healthy late is picked up by
            // the post-start status reconciliation (EmbarsyStore) and flips to Running.
            message = "\(service.title) is still starting but did not pass its health check in time. "
                + "It may finish on its own — press Refresh in a minute. Check \(logFile(for: service).path)."
        case .ready:
            return
        }
        setStatus(service, .failed, message: message)

        if let exit {
            debugLog?.append("\(service.title) startup failure: \(exit.summary)", category: "process.error")
        }
        switch tail {
        case .some(let text) where text.isEmpty:
            debugLog?.append("\(service.title) wrote no output during the failed start (killed before it could run?)", category: "process.error")
        case .some(let text):
            debugLog?.append("\(service.title) log tail from the failed start:\n\(text)", category: "process.error")
        case .none:
            debugLog?.append("\(service.title) log tail unavailable at \(logFile(for: service).path)", category: "process.error")
        }
    }

    private func isServiceReady(_ service: ManagedService) async -> Bool {
        await health.isReady(url: healthURL(for: service), headers: healthHeaders(for: service))
    }

    /// Version reported by whatever process currently serves the API health endpoint —
    /// after an app update this can be an orphaned process from the previous app version.
    func reportedAPIVersion() async -> String? {
        await health.reportedAPIVersion(healthURL: healthURL(for: .api))
    }

    private func healthHeaders(for service: ManagedService) -> [String: String] {
        switch service {
        case .qdrant:
            config.qdrantAPIKey.isEmpty ? [:] : ["api-key": config.qdrantAPIKey]
        case .ollama, .api:
            [:]
        }
    }

    private func healthURL(for service: ManagedService) -> URL {
        switch service {
        case .qdrant:
            config.qdrantBaseURL.appendingPathComponent("readyz")
        case .ollama:
            config.ollamaBaseURL.appendingPathComponent("api/tags")
        case .api:
            config.apiBaseURL.appendingPathComponent("health")
        }
    }

    private func binaryPath(for service: ManagedService) -> URL {
        switch service {
        case .qdrant: paths.bundledQdrant
        case .ollama: paths.bundledOllama
        case .api: paths.bundledAPI
        }
    }

    private func terminateListenersOnManagedPorts() {
        for service in ManagedService.allCases {
            terminateListeners(on: managedPort(for: service))
        }
    }

    private func managedPort(for service: ManagedService) -> Int {
        switch service {
        case .qdrant: config.qdrantRestPort
        case .ollama: config.ollamaBaseURL.port ?? 11_434
        case .api: config.apiPort
        }
    }

    private func setStatus(_ service: ManagedService, _ status: ServiceStatus, message: String) {
        var nextStatuses = statuses
        var nextMessages = messages
        nextStatuses[service] = status
        nextMessages[service] = message
        statuses = nextStatuses
        messages = nextMessages
    }

    private func setMessage(_ service: ManagedService, _ message: String) {
        var nextMessages = messages
        nextMessages[service] = message
        messages = nextMessages
    }

    private func terminateListeners(on port: Int) {
        let pids = listenerPIDs(on: port)
        guard !pids.isEmpty else {
            debugLog?.append("No listener found on port \(port) during hard reset cleanup", category: "process")
            return
        }

        debugLog?.append("Terminating listener PID(s) on port \(port): \(pids.joined(separator: ", "))", category: "process")
        _ = runSystemCommand(executable: "/bin/kill", arguments: ["-TERM"] + pids)

        Thread.sleep(forTimeInterval: 0.5)
        let remainingPIDs = listenerPIDs(on: port)
        guard !remainingPIDs.isEmpty else { return }

        debugLog?.append("Force killing listener PID(s) on port \(port): \(remainingPIDs.joined(separator: ", "))", category: "process")
        _ = runSystemCommand(executable: "/bin/kill", arguments: ["-KILL"] + remainingPIDs)
    }

    private func listenerPIDs(on port: Int) -> [String] {
        let output = runSystemCommand(
            executable: "/usr/sbin/lsof",
            arguments: ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        )
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func runSystemCommand(executable: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            debugLog?.append(
                "Failed to run \(executable) \(arguments.joined(separator: " ")): \(error.localizedDescription)",
                category: "process.error"
            )
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func configureProcesses() {
        processes[.qdrant] = ManagedProcess(spec: ProcessSpec(
            service: .qdrant,
            executable: paths.bundledQdrant,
            arguments: ["--config-path", paths.qdrantConfig.path],
            environment: ["QDRANT__SERVICE__API_KEY": config.qdrantAPIKey],
            logFile: logFile(for: .qdrant),
            workingDirectory: paths.appSupport
        ))

        processes[.ollama] = ManagedProcess(spec: ProcessSpec(
            service: .ollama,
            executable: paths.bundledOllama,
            arguments: ["serve"],
            environment: [
                "OLLAMA_HOST": config.ollamaHost,
                "OLLAMA_MODELS": paths.ollamaModels.path,
            ],
            logFile: logFile(for: .ollama),
            workingDirectory: paths.appSupport
        ))

        processes[.api] = ManagedProcess(spec: ProcessSpec(
            service: .api,
            executable: paths.bundledAPI,
            arguments: [],
            environment: [
                "EMBARSY_HOST": config.host,
                "EMBARSY_API_PORT": String(config.apiPort),
                "EMBARSY_API_KEY": config.embarsyAPIKey,
                "OLLAMA_BASE_URL": config.ollamaBaseURL.absoluteString,
                "OLLAMA_MODEL": config.ollamaModel,
                "OLLAMA_KEEP_ALIVE": config.ollamaKeepAlive,
                "QDRANT_BASE_URL": config.qdrantBaseURL.absoluteString,
                "QDRANT_API_KEY": config.qdrantAPIKey,
            ],
            logFile: logFile(for: .api),
            workingDirectory: paths.appSupport
        ))
    }

    private func writeQdrantConfig() throws {
        let configText = """
        service:
          host: \(config.host)
          http_port: \(config.qdrantRestPort)
          grpc_port: \(config.qdrantGrpcPort)
          api_key: \(config.qdrantAPIKey)
        storage:
          storage_path: \(paths.qdrantStorage.path)
        """
        try configText.write(to: paths.qdrantConfig, atomically: true, encoding: .utf8)
    }
}
