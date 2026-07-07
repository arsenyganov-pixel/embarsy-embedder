import Foundation

@MainActor
final class InstallManager: ObservableObject {
    @Published var currentStep: InstallStep = .idle
    @Published var message = "Ready to install Embarsy local stack."
    @Published var detailMessage = "Install progress details will appear here."
    @Published private(set) var isModelDownloadActive = false
    @Published private(set) var modelDownloadActivity = ""
    @Published private(set) var modelDownloadCommand = ""
    @Published private(set) var modelDownloadLastOutputAge = ""
    @Published private(set) var binaryChecks: [BinaryCheck] = []
    @Published private(set) var isInstalling = false
    @Published private(set) var isInstalled = false

    private let runner = ProcessRunner()
    private let debugLog: DebugLogService?
    private var modelDownloadHeartbeatTask: Task<Void, Never>?
    private var modelDownloadStartedAt: Date?
    private var lastModelDownloadOutputAt: Date?
    private var lastModelDownloadLine = ""

    init(debugLog: DebugLogService? = nil) {
        self.debugLog = debugLog
    }

    var progress: Double { currentStep.progress }

    var shouldShowInstallActivity: Bool {
        isInstalling || isModelDownloadActive
    }

    func refreshInstalledState(paths: AppPaths, processManager: ProcessManager) {
        let markerExists = FileManager.default.fileExists(atPath: paths.installMarker.path)
        let binariesReady = processManager.validateBinaries().allSatisfy(\.isExecutable)
        let layoutReady = FileManager.default.fileExists(atPath: paths.appSupport.path)
            && FileManager.default.fileExists(atPath: paths.qdrantConfig.deletingLastPathComponent().path)
            && FileManager.default.fileExists(atPath: paths.ollamaModels.path)
        isInstalled = markerExists && binariesReady && layoutReady
        if isInstalled {
            currentStep = .completed
            message = "Embarsy local stack is installed."
        }
    }

    func installOnly(paths: AppPaths, config: EmbarsyConfig, processManager: ProcessManager) async {
        guard !isInstalling else {
            debugLog?.append("Install ignored: install is already running", category: "install")
            return
        }
        refreshInstalledState(paths: paths, processManager: processManager)
        guard !isInstalled else {
            message = "Embarsy local stack is already installed."
            debugLog?.append(message, category: "install")
            return
        }
        isInstalling = true
        startInstallActivity(
            "Install polling started. Waiting for setup steps...",
            command: "Embarsy install workflow"
        )
        defer {
            stopInstallActivity(finalMessage: "")
            isInstalling = false
        }
        detailMessage = "Preparing clean install..."
        debugLog?.append("Install flow started", category: "install")

        do {
            try await setStep(.prepareDirectories, "Creating App Support layout...")
            processManager.forceCleanStop(message: "Preparing clean install...")
            try paths.createDirectories()

            try await setStep(.secrets, "Local secrets are ready.")

            try await setStep(.validateBinaries, "Checking bundled binaries...")
            binaryChecks = processManager.validateBinaries()
            let missing = binaryChecks.filter { !$0.isExecutable }
            guard missing.isEmpty else {
                throw InstallError.missingBinaries(missing.map { "\($0.service.title): \($0.path)" })
            }

            try await setStep(.startQdrant, "Temporarily starting Qdrant for setup...")
            await processManager.start(.qdrant)
            guard processManager.statuses[.qdrant] == .running else { throw InstallError.serviceStartFailed(.qdrant) }
            do {
                try await validateQdrantAuth(config: config)
            } catch {
                debugLog?.append("Qdrant rejected current key after start. Restarting Qdrant with freshly written config. Details: \(error.localizedDescription)", category: "install.qdrant")
                await processManager.restart(.qdrant, reason: "Qdrant auth probe rejected current API key")
                guard processManager.statuses[.qdrant] == .running else { throw InstallError.serviceStartFailed(.qdrant) }
                try await validateQdrantAuth(config: config)
            }

            try await setStep(.startOllama, "Temporarily starting Ollama for model setup...")
            await processManager.start(.ollama)
            guard processManager.statuses[.ollama] == .running else { throw InstallError.serviceStartFailed(.ollama) }

            try await setStep(.prepareModel, "Downloading/preparing \(config.ollamaModel). This can take a while...")
            try await prepareModel(paths: paths, config: config)

            try await setStep(.startAPI, "Starting Embarsy API with current local secrets...")
            await processManager.start(.api)
            if processManager.statuses[.api] != .running {
                // One in-place retry: the first post-install start of the PyInstaller onefile
                // API is its slowest (extraction + per-dylib signature validation); a second
                // attempt starts from warm caches and usually clears a marginal timeout.
                debugLog?.append("Embarsy API failed its first start during install (\(processManager.messages[.api] ?? "")). Retrying once...", category: "install")
                updateInstallActivity("Embarsy API needs a second start attempt. Retrying...")
                await processManager.restart(.api, reason: "Install retry after first API start failed")
            }
            guard processManager.statuses[.api] == .running else {
                throw InstallError.apiStartFailed(processManager.messages[.api] ?? "No details available.")
            }

            try await setStep(.verifyHealth, "Verifying Watcher-compatible authentication...")
            try await validateRooAuth(config: config)

            try await setStep(.verifyHealth, "Writing install marker...")
            try writeInstallMarker(paths: paths)
            try await setStep(.completed, "Embarsy is installed. Use Start All to run services.")
            detailMessage = "Install completed. Watcher-compatible auth probe passed with the current API key."
            isInstalled = true
            debugLog?.append("Install flow completed successfully", category: "install")
        } catch {
            message = error.localizedDescription
            detailMessage = "Install failed. See the recommendation above and open logs for details."
            currentStep = .idle
            isInstalled = false
            debugLog?.append("Install flow failed: \(error.localizedDescription)", category: "install.error")
        }
    }

    func hardReset(paths: AppPaths, processManager: ProcessManager) async {
        debugLog?.append("Hard Reset requested: stopping services and cleaning app support", category: "install")
        clearInstallActivity()
        processManager.hardResetCleanup()
        archiveLogsBeforeReset(paths: paths)
        do {
            try FileManager.default.removeItem(at: paths.appSupport)
            debugLog?.append("Removed App Support at \(paths.appSupport.path)", category: "install")
        } catch CocoaError.fileNoSuchFile {
            debugLog?.append("App Support already clean at \(paths.appSupport.path)", category: "install")
        } catch {
            message = "Hard Reset failed: \(error.localizedDescription)"
            debugLog?.append(message, category: "install.error")
            return
        }

        currentStep = .idle
        binaryChecks = []
        isInstalled = false
        message = "Hard Reset completed. App Support and local secrets are clean."
        detailMessage = "Components removed. Run Install to recreate the local stack."
        processManager.markAllStopped(message: "Components removed. Install required.")
        debugLog?.append(message, category: "install")
    }

    /// Hard Reset deletes App Support INCLUDING logs/ — which used to destroy the only
    /// evidence of whatever failure prompted the reset. Snapshot the logs directory to
    /// ~/Library/Logs/Embarsy/reset-<timestamp>/ first (keep the last 3 snapshots).
    private func archiveLogsBeforeReset(paths: AppPaths) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.logsDirectory.path) else { return }
        let archiveRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Embarsy")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let destination = archiveRoot.appendingPathComponent("reset-\(formatter.string(from: Date()))")
        do {
            try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            try fileManager.copyItem(at: paths.logsDirectory, to: destination)
            debugLog?.append("Archived logs to \(destination.path) before Hard Reset", category: "install")
            let snapshots = (try fileManager.contentsOfDirectory(at: archiveRoot, includingPropertiesForKeys: nil))
                .filter { $0.lastPathComponent.hasPrefix("reset-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for stale in snapshots.dropLast(3) {
                try? fileManager.removeItem(at: stale)
            }
        } catch {
            debugLog?.append("Log archive before Hard Reset failed: \(error.localizedDescription)", category: "install.error")
        }
    }

    private func writeInstallMarker(paths: AppPaths) throws {
        let text = "installed_at=\(ISO8601DateFormatter().string(from: Date()))\n"
        try text.write(to: paths.installMarker, atomically: true, encoding: .utf8)
    }

    private func prepareModel(paths: AppPaths, config: EmbarsyConfig) async throws {
        let environment = [
            "OLLAMA_HOST": config.ollamaHost,
            "OLLAMA_MODELS": paths.ollamaModels.path,
        ]

        debugLog?.append("Preparing model \(config.ollamaModel) from \(config.ollamaSourceModel)", category: "install")
        startInstallActivity(
            "Checking local Qwen model files before download...",
            command: "ollama pull \(config.ollamaSourceModel)"
        )

        if modelManifestExists(paths: paths, config: config) {
            updateInstallActivity("Source model is already downloaded. Preparing local alias \(config.ollamaModel)...")
            debugLog?.append("Source model manifest already exists. Skipping ollama pull for \(config.ollamaSourceModel).", category: "install")
        } else {
            updateInstallActivity("Starting Qwen model download. Large layer can take several minutes...")
            debugLog?.append("Running ollama pull \(config.ollamaSourceModel)", category: "install")
            let pull = try await runOllamaCommand(
                name: "ollama pull",
                executable: paths.bundledOllama,
                arguments: ["pull", config.ollamaSourceModel],
                environment: environment,
                workingDirectory: paths.appSupport,
                timeout: 900,
                onOutput: { [weak self] output in
                    Task { @MainActor in
                        self?.updateModelProgress(from: output)
                    }
                }
            )
            debugLog?.append("ollama pull finished with exit code \(pull.exitCode). Output tail: \(Self.outputTail(pull.output))", category: "install")
            guard pull.exitCode == 0 else { throw InstallError.commandFailed("ollama pull", pull.output) }
            updateInstallActivity("Qwen model download completed. Creating local alias \(config.ollamaModel)...")
        }

        modelDownloadCommand = "ollama cp \(config.ollamaSourceModel) \(config.ollamaModel)"
        detailMessage = "Creating local model alias \(config.ollamaModel)..."
        debugLog?.append("Running ollama cp \(config.ollamaSourceModel) \(config.ollamaModel)", category: "install")
        let pull = try await runOllamaCommand(
            name: "ollama cp",
            executable: paths.bundledOllama,
            arguments: ["cp", config.ollamaSourceModel, config.ollamaModel],
            environment: environment,
            workingDirectory: paths.appSupport,
            timeout: 120
        )
        debugLog?.append("ollama cp finished with exit code \(pull.exitCode). Output tail: \(Self.outputTail(pull.output))", category: "install")
        guard pull.exitCode == 0 || pull.output.localizedCaseInsensitiveContains("already") else {
            throw InstallError.commandFailed("ollama cp", pull.output)
        }
        updateInstallActivity("Model \(config.ollamaModel) is ready.")
    }

    private func runOllamaCommand(
        name: String,
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> ProcessRunner.Result {
        do {
            return try await runner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                timeout: timeout,
                onOutput: onOutput
            )
        } catch ProcessRunner.RunnerError.timedOut(_, _, let output) {
            throw InstallError.commandTimedOut(name, output)
        } catch {
            throw InstallError.commandFailed(name, error.localizedDescription)
        }
    }

    private func validateRooAuth(config: EmbarsyConfig) async throws {
        var request = URLRequest(url: config.apiBaseURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.embarsyAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "input": "Embarsy install auth probe",
            "model": config.ollamaModel,
            "dimensions": config.embeddingDimension,
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw InstallError.rooAuthProbeFailed("No HTTP response from Embarsy API.")
        }

        guard httpResponse.statusCode == 200 else {
            throw InstallError.rooAuthProbeFailed("Embarsy API returned HTTP \(httpResponse.statusCode).")
        }

        detailMessage = "Watcher-compatible auth probe passed. Current API key is accepted."
        debugLog?.append("Watcher-compatible auth probe passed", category: "install")
    }

    private func validateQdrantAuth(config: EmbarsyConfig) async throws {
        var request = URLRequest(url: config.qdrantBaseURL.appendingPathComponent("collections"))
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.qdrantAPIKey.isEmpty {
            request.setValue(config.qdrantAPIKey, forHTTPHeaderField: "api-key")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw InstallError.qdrantAuthProbeFailed("No HTTP response from Qdrant.")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
            throw InstallError.qdrantAuthProbeFailed("Qdrant returned HTTP \(httpResponse.statusCode): \(body)")
        }

        debugLog?.append("Qdrant auth probe passed with current API key", category: "install.qdrant")
    }

    private func updateModelProgress(from output: String) {
        let meaningfulLines = Self.progressLines(from: output)

        guard let latestLine = meaningfulLines.last else { return }
        updateInstallActivity(latestLine)
    }

    private func startInstallActivity(_ initialMessage: String, command: String) {
        modelDownloadHeartbeatTask?.cancel()
        let now = Date()
        modelDownloadStartedAt = now
        lastModelDownloadOutputAt = now
        isModelDownloadActive = true
        modelDownloadCommand = command
        modelDownloadLastOutputAge = "last output just now"
        lastModelDownloadLine = initialMessage
        modelDownloadActivity = initialMessage
        detailMessage = initialMessage
        debugLog?.append("Install activity started: \(initialMessage)", category: "install.activity")
        debugLog?.append("Install activity command: \(command)", category: "install.activity")

        modelDownloadHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    self?.refreshInstallActivityHeartbeat()
                }
            }
        }
    }

    private func updateInstallActivity(_ activity: String) {
        lastModelDownloadOutputAt = Date()
        isModelDownloadActive = true
        modelDownloadLastOutputAge = "last output just now"
        lastModelDownloadLine = activity
        let message = formattedInstallActivity(elapsed: Int(Date().timeIntervalSince(modelDownloadStartedAt ?? Date())))
        modelDownloadActivity = message
        detailMessage = message
        debugLog?.append("Install activity: \(activity)", category: "install.activity")
    }

    private func refreshInstallActivityHeartbeat() {
        guard isModelDownloadActive else { return }
        let elapsed = Int(Date().timeIntervalSince(modelDownloadStartedAt ?? Date()))
        let secondsSinceOutput = Int(Date().timeIntervalSince(lastModelDownloadOutputAt ?? Date()))
        modelDownloadLastOutputAge = "last output \(Self.formatDuration(secondsSinceOutput)) ago"
        let message = formattedInstallActivity(elapsed: elapsed)
        modelDownloadActivity = message
        detailMessage = message
        if secondsSinceOutput == 10 || secondsSinceOutput % 30 == 0 {
            debugLog?.append("Install activity heartbeat: \(message)", category: "install.activity")
        }
    }

    private func stopInstallActivity(finalMessage: String) {
        modelDownloadHeartbeatTask?.cancel()
        modelDownloadHeartbeatTask = nil
        guard isModelDownloadActive || !modelDownloadActivity.isEmpty else { return }
        if !finalMessage.isEmpty {
            lastModelDownloadLine = finalMessage
            modelDownloadActivity = finalMessage
            detailMessage = finalMessage
            debugLog?.append("Install activity stopped: \(finalMessage)", category: "install.activity")
        } else {
            debugLog?.append("Install activity stopped", category: "install.activity")
        }
        isModelDownloadActive = false
        modelDownloadStartedAt = nil
        lastModelDownloadOutputAt = nil
        modelDownloadLastOutputAge = ""
        modelDownloadCommand = ""
    }

    private func clearInstallActivity() {
        modelDownloadHeartbeatTask?.cancel()
        modelDownloadHeartbeatTask = nil
        if isModelDownloadActive || !modelDownloadActivity.isEmpty {
            debugLog?.append("Install activity cleared", category: "install.activity")
        }
        isModelDownloadActive = false
        modelDownloadStartedAt = nil
        lastModelDownloadOutputAt = nil
        lastModelDownloadLine = ""
        modelDownloadActivity = ""
        modelDownloadLastOutputAge = ""
        modelDownloadCommand = ""
    }

    private func formattedInstallActivity(elapsed: Int) -> String {
        let currentLine = lastModelDownloadLine.isEmpty
            ? "Waiting for install progress output"
            : lastModelDownloadLine
        return "\(currentLine) · elapsed \(Self.formatDuration(elapsed))"
    }

    private func modelManifestExists(paths: AppPaths, config: EmbarsyConfig) -> Bool {
        let parts = config.ollamaSourceModel.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }

        let modelPath = parts[0]
        let tag = parts[1]
        let manifest = paths.ollamaModels
            .appendingPathComponent("manifests")
            .appendingPathComponent(modelPath)
            .appendingPathComponent(tag)
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    private static func outputTail(_ output: String, limit: Int = 2_000) -> String {
        guard output.count > limit else { return output }
        return String(output.suffix(limit))
    }

    private static func cleanTerminalOutput(_ output: String) -> String {
        output
            .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func progressLines(from output: String) -> [String] {
        cleanTerminalOutput(output)
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: "\u{0008}") }
            .map { line in
                line
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { line in
                guard !line.isEmpty else { return false }
                let lower = line.lowercased()
                return lower.contains("pulling")
                    || lower.contains("downloading")
                    || lower.contains("verifying")
                    || lower.contains("writing")
                    || lower.contains("success")
                    || lower.contains("manifest")
                    || lower.contains("sha256")
                    || line.contains("%")
            }
    }

    private static func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 { return "\(remainder)s" }
        return "\(minutes)m \(remainder)s"
    }

    private func setStep(_ step: InstallStep, _ newMessage: String) async throws {
        currentStep = step
        message = newMessage
        detailMessage = newMessage
        if isInstalling {
            updateInstallActivity(newMessage)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

enum EmbarsySecret: String {
    case qdrantAPIKey = "QDRANT_API_KEY"
    case embarsyAPIKey = "EMBARSY_API_KEY"
}

enum InstallError: LocalizedError {
    case missingBinaries([String])
    case commandFailed(String, String)
    case commandTimedOut(String, String)
    case serviceStartFailed(ManagedService)
    case apiStartFailed(String)
    case healthCheckFailed
    case rooAuthProbeFailed(String)
    case qdrantAuthProbeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBinaries(let binaries):
            "Missing executable binaries:\n" + binaries.joined(separator: "\n")
        case .commandFailed(let command, let output):
            "\(command) failed: \(output)\n\nRecommendation: check your internet connection, click Refresh, then run Install again. If it fails again, export the debug log first (Settings), then use Remove Components and Clear Secrets, retry Install, and send the debug log to arsenyganov@gmail.com."
        case .commandTimedOut(let command, let output):
            "\(command) timed out. Output tail: \(Self.outputTail(output))\n\nRecommendation: check your internet connection, click Refresh, then run Install again. If it fails again, export the debug log first (Settings), then use Remove Components and Clear Secrets, retry Install, and send the debug log to arsenyganov@gmail.com."
        case .serviceStartFailed(let service):
            "\(service.title) failed to start during install. Recommendation: click Refresh, retry Install, then open logs and send the debug log to arsenyganov@gmail.com."
        case .apiStartFailed(let details):
            "Embarsy API failed to start during install (after a retry): \(details)\n\nQdrant, Ollama and the model are installed correctly — only the API step failed. Recommendation: retry Install (it will skip the finished steps), and if it fails again, export the debug log (Settings) and send it to arsenyganov@gmail.com. Do NOT run Remove Components — that would erase the evidence and the downloaded model."
        case .healthCheckFailed:
            "Health check failed: not all services are running. Recommendation: click Refresh, retry Install, then open logs and send the debug log to arsenyganov@gmail.com."
        case .rooAuthProbeFailed(let details):
            "Watcher-compatible authentication check failed: \(details) Recommendation: use Remove Components and Clear Secrets, run Install again, then copy the fresh API Key and Qdrant API Key from Embarsy into Watcher settings."
        case .qdrantAuthProbeFailed(let details):
            "Qdrant authentication check failed: \(details) Recommendation: use Remove Components and Clear Secrets, run Install again, then copy the fresh Qdrant API Key from Embarsy into Watcher settings."
        }
    }

    private static func outputTail(_ output: String, limit: Int = 1_000) -> String {
        guard output.count > limit else { return output }
        return String(output.suffix(limit))
    }
}
