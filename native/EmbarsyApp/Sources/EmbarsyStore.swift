import AppKit
import Combine
import Foundation

enum AppTab: Hashable {
    case status
    case install
    case monitoring
    case activity
    case content
    case settings
    case howto
}

@MainActor
final class EmbarsyStore: ObservableObject {
    @Published var config = EmbarsyConfig()
    @Published var paths: AppPaths
    @Published var processManager: ProcessManager
    @Published var installManager = InstallManager()
    @Published var monitoring = MonitoringService()
    @Published var activity = ActivityService()
    @Published var contentIndex = ContentIndexService()
    @Published var preferences = PreferencesStore()
    @Published var loginItemService = LoginItemService()
    @Published var workspaceMessage = ""
    @Published var localSecretsMessage = "Local secrets will be prepared before Install or Start."
    @Published var rooConnectionMessage = ""
    @Published var rooDiagnosticsMessage = "Watcher/Qdrant diagnostics have not been run yet."
    @Published var isRefreshingRooDiagnostics = false
    @Published var localSecretsNeedsRemediation = false
    @Published var securityPreflight = SecurityPreflight.unknown
    @Published var buildInfoSummary = EmbarsyBuildInfo.summary
    @Published var debugLogMessage = "Debug log is ready."
    @Published var selectedTab: AppTab = .status
    @Published var isClearingRooIndex = false

    let localSecrets: LocalSecretStore
    let workspaceService = WorkspaceService()
    /// App-lifetime Memory / CPU / temperature buffer. Owned by the store (not the Monitoring
    /// view) so its history survives tab navigation and is sampled continuously in the background.
    let sysMetrics = SystemMetricsService()
    private var metricsSamplingTask: Task<Void, Never>?
    let debugLog: DebugLogService
    private let securityService = SecurityPreflightService()
    private let rooIndexCleanup = RooIndexCleanupService()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let resolvedPaths = (try? AppPaths.live()) ?? AppPaths(
            appSupport: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Embarsy"),
            runDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Embarsy/run"),
            logsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Embarsy/logs"),
            qdrantStorage: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Embarsy/qdrant/storage"),
            qdrantConfig: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Embarsy/qdrant/config.yaml"),
            ollamaModels: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Embarsy/ollama"),
            installMarker: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Embarsy/.installed"),
            localSecretsFile: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Embarsy/.local-secrets.json"),
            bundledQdrant: URL(fileURLWithPath: "qdrant"),
            bundledOllama: URL(fileURLWithPath: "ollama"),
            bundledAPI: URL(fileURLWithPath: "embarsy-api")
        )
        let defaultConfig = EmbarsyConfig()
        let debugLog = DebugLogService(logsDirectory: resolvedPaths.logsDirectory)
        self.config = defaultConfig
        self.paths = resolvedPaths
        self.debugLog = debugLog
        self.localSecrets = LocalSecretStore(fileURL: resolvedPaths.localSecretsFile)
        self.processManager = ProcessManager(paths: resolvedPaths, config: defaultConfig, debugLog: debugLog)
        self.installManager = InstallManager(debugLog: debugLog)
        self.installManager.refreshInstalledState(paths: resolvedPaths, processManager: self.processManager)
        self.selectedTab = self.installManager.isInstalled ? .status : .install
        self.securityPreflight = securityService.check()
        debugLog.startSession(
            securityPreflightSummary: self.securityPreflight.summary,
            buildInfoSummary: self.buildInfoSummary
        )
        self.loginItemService.refresh()
        bindChildObjectChanges()
        debugLog.append("EmbarsyStore initialized with build \(EmbarsyBuildInfo.bundleVersion) at \(EmbarsyBuildInfo.bundlePath)", category: "store")
        if let warning = EmbarsyBuildInfo.mountedVolumeWarning {
            workspaceMessage = warning
            debugLog.append(warning, category: "build.warning")
        }
        startMetricsSampling()
    }

    /// Continuously sample Memory / CPU / temperature for the app's lifetime so the Monitoring
    /// charts are historical — they no longer reset when the Monitoring tab is left and reopened.
    private func startMetricsSampling() {
        guard metricsSamplingTask == nil else { return }
        metricsSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sysMetrics.sample(rootPIDs: self.processManager.runningPIDs, config: self.config)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private let launchedAt = Date()

    /// Human-readable time since the app launched (shown on the Status hero).
    var uptimeText: String {
        let elapsed = max(0, Int(Date().timeIntervalSince(launchedAt)))
        let h = elapsed / 3600, m = (elapsed % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    var aggregateStatus: ServiceStatus {
        guard installManager.isInstalled || installManager.isInstalling else { return .stopped }
        let values = ManagedService.allCases.map { serviceStatus(for: $0) }
        if values.contains(.failed) { return .failed }
        if values.allSatisfy({ $0 == .running }) { return .running }
        if values.contains(.starting) { return .starting }
        if values.contains(.unknown) { return .unknown }
        return .stopped
    }

    func serviceStatus(for service: ManagedService) -> ServiceStatus {
        guard installManager.isInstalled || installManager.isInstalling else { return .stopped }
        return processManager.statuses[service, default: .unknown]
    }

    func serviceMessage(for service: ManagedService) -> String {
        guard installManager.isInstalled || installManager.isInstalling else {
            return "Components are not installed. Run Install first."
        }
        return processManager.messages[service, default: "Not checked yet."]
    }

    func refreshServiceStatuses() async {
        refreshInstalledState()
        guard installManager.isInstalled || installManager.isInstalling else {
            processManager.markAllStopped(message: "Components are not installed. Run Install first.")
            return
        }
        await processManager.refreshAll()
    }

    func startStackIfNeededOnLaunch() async {
        guard preferences.startStackOnLaunch else { return }
        guard ensureInstalledBeforeStart(source: "Start stack on launch") else { return }
        debugLog.append("Start stack on launch requested", category: "store")
        guard prepareLocalSecretsForUse() else { return }
        await processManager.startAll()
    }

    func startAll() async {
        workspaceMessage = "Starting Embarsy stack..."
        debugLog.append("Start All requested", category: "store")
        guard ensureInstalledBeforeStart(source: "Start All") else { return }
        guard prepareLocalSecretsForUse() else { return }
        processManager.forceCleanStop(message: "Preparing clean start...")
        await processManager.startAll()
        workspaceMessage = "Start All finished with status: \(aggregateStatus.title)."
        debugLog.append(workspaceMessage, category: "store")
    }

    func install() async {
        workspaceMessage = "Install requested..."
        debugLog.append("Install requested", category: "store")
        guard prepareLocalSecretsForUse() else { return }
        await installManager.installOnly(
            paths: paths,
            config: config,
            processManager: processManager
        )
        refreshInstalledState()
        await refreshRooDiagnostics()
        if installManager.isInstalled && !installManager.isInstalling {
            selectedTab = .status
        }
        workspaceMessage = "Install finished: \(installManager.message)"
        debugLog.append(workspaceMessage, category: "store")
        debugLog.append(
            "Install UI state: isInstalled=\(installManager.isInstalled), currentStep=\(installManager.currentStep.rawValue), selectedTab=\(selectedTab)",
            category: "store"
        )
    }

    func installAndStart() async {
        await install()
        guard installManager.isInstalled else { return }
        await startAll()
    }

    func repairLocalSecrets() async {
        processManager.stopAll()
        do {
            let qdrantKey = try LocalSecretStore.generateHexSecret(bytes: 32)
            let apiKey = try LocalSecretStore.generateHexSecret(bytes: 24)
            try localSecrets.resetSecrets([
                (EmbarsySecret.qdrantAPIKey.rawValue, qdrantKey),
                (EmbarsySecret.embarsyAPIKey.rawValue, apiKey),
            ])
            applySecrets(qdrantKey: qdrantKey, apiKey: apiKey)
            localSecretsMessage = "Protected local secrets were recreated."
            debugLog.append(localSecretsMessage, category: "secrets")
        } catch {
            localSecretsNeedsRemediation = true
            localSecretsMessage = "Failed to recreate local secrets: \(error.localizedDescription)"
            debugLog.append(localSecretsMessage, category: "secrets.error")
        }
    }

    func dismissLocalSecretsRemediation() {
        localSecretsNeedsRemediation = false
    }

    func refreshLocalSecretsStatus() {
        do {
            let qdrantReady = try localSecrets.value(for: EmbarsySecret.qdrantAPIKey.rawValue)?.isEmpty == false
            let apiReady = try localSecrets.value(for: EmbarsySecret.embarsyAPIKey.rawValue)?.isEmpty == false
            localSecretsNeedsRemediation = !(qdrantReady && apiReady)
            localSecretsMessage = qdrantReady && apiReady
                ? "Protected local secrets are ready."
                : "Protected local secrets are missing. Recreate local secrets or run Install."
            debugLog.append(localSecretsMessage, category: "secrets")
        } catch {
            localSecretsNeedsRemediation = true
            localSecretsMessage = "Protected local secrets are unavailable: \(error.localizedDescription)"
            debugLog.append(localSecretsMessage, category: "secrets.error")
        }
    }

    func refreshInstalledState() {
        installManager.refreshInstalledState(paths: paths, processManager: processManager)
        if installManager.isInstalled && selectedTab == .install && !installManager.isInstalling {
            selectedTab = .status
        }
        if !installManager.isInstalled && !installManager.isInstalling {
            processManager.markAllStopped(message: "Components are not installed. Run Install first.")
            selectedTab = .install
        }
    }

    func refreshMonitoring() async {
        if config.embarsyAPIKey.isEmpty {
            _ = prepareLocalSecretsForUse()
        }
        await monitoring.refresh(config: config)
    }

    func refreshActivity() async {
        if config.embarsyAPIKey.isEmpty {
            _ = prepareLocalSecretsForUse()
        }
        await activity.refresh(config: config)
    }

    func refreshContentIndex() async {
        if config.embarsyAPIKey.isEmpty {
            _ = prepareLocalSecretsForUse()
        }
        await contentIndex.refresh(config: config)
    }

    /// Permanently delete a Qdrant collection (Content slide-to-delete).
    func deleteCollection(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if config.qdrantAPIKey.isEmpty { _ = prepareLocalSecretsForUse() }
        debugLog.append("Delete collection requested: \(trimmed)", category: "content")
        do {
            var request = URLRequest(url: config.qdrantBaseURL
                .appendingPathComponent("collections")
                .appendingPathComponent(trimmed))
            request.httpMethod = "DELETE"
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !config.qdrantAPIKey.isEmpty {
                request.setValue(config.qdrantAPIKey, forHTTPHeaderField: "api-key")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                workspaceMessage = "Deleted collection \(trimmed)."
                debugLog.append("Deleted Qdrant collection \(trimmed)", category: "content")
                await contentIndex.refresh(config: config)
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data, encoding: .utf8) ?? ""
                workspaceMessage = "Failed to delete \(trimmed): HTTP \(code). \(body)"
                debugLog.append(workspaceMessage, category: "content.error")
            }
        } catch {
            workspaceMessage = "Failed to delete \(trimmed): \(error.localizedDescription). Start Embarsy stack and retry."
            debugLog.append(workspaceMessage, category: "content.error")
        }
    }

    func removeComponentsAndLocalSecrets() async {
        debugLog.append("Remove components and local secrets requested", category: "store")
        await installManager.hardReset(
            paths: paths,
            processManager: processManager
        )
        do {
            try localSecrets.deleteAll()
            debugLog.append("Local secrets file removed", category: "secrets")
        } catch {
            debugLog.append("Local secrets delete skipped or failed: \(error.localizedDescription)", category: "secrets")
        }
        config.qdrantAPIKey = ""
        config.embarsyAPIKey = ""
        processManager.updateConfig(config)
        processManager.markAllStopped(message: "Components removed. Install required.")
        installManager.refreshInstalledState(paths: paths, processManager: processManager)
        processManager.markAllStopped(message: "Components removed. Install required.")
        selectedTab = .install
        localSecretsMessage = "Local secrets were removed. They will be recreated during install."
        rooConnectionMessage = "Watcher still has the old Qdrant API Key after reset. After the next install, copy the fresh API Key and Qdrant API Key from this screen into Watcher before starting indexing."
        rooDiagnosticsMessage = "Watcher/Qdrant diagnostics skipped: components are removed. Run Install first."
        workspaceMessage = "Embarsy components and protected local secrets were removed."
        debugLog.append(workspaceMessage, category: "store")
        debugLog.append(
            "Reset UI state: isInstalled=\(installManager.isInstalled), isInstalling=\(installManager.isInstalling), selectedTab=\(selectedTab), aggregateStatus=\(aggregateStatus.rawValue)",
            category: "store"
        )
    }


    func clearRooIndexForDefaultProject() async {
        guard !isClearingRooIndex else { return }
        isClearingRooIndex = true
        defer { isClearingRooIndex = false }

            workspaceMessage = "Clearing Watcher index..."
            debugLog.append("Clear Watcher Index requested", category: "roo-index")

        guard ensureInstalledBeforeStart(source: "Clear Watcher Index") else { return }
        guard !preferences.defaultProjectPath.isEmpty else {
            workspaceMessage = "Clear Watcher Index skipped: select a default project first."
            debugLog.append(workspaceMessage, category: "roo-index")
            return
        }
        guard prepareLocalSecretsForUse() else { return }

        await processManager.refresh(.qdrant)
        if processManager.statuses[.qdrant] != .running {
            debugLog.append("Qdrant is not running; starting Qdrant before Watcher index cleanup", category: "roo-index")
            await processManager.start(.qdrant)
        }
        guard processManager.statuses[.qdrant] == .running else {
            workspaceMessage = "Clear Watcher Index failed: Qdrant is not running. Start Embarsy stack and try again."
            debugLog.append(workspaceMessage, category: "roo-index.error")
            return
        }

        do {
            let result = try await rooIndexCleanup.clearWorkspaceIndex(RooIndexCleanupRequest(
                workspacePath: preferences.defaultProjectPath,
                qdrantBaseURL: config.qdrantBaseURL,
                qdrantAPIKey: config.qdrantAPIKey
            ))
            workspaceMessage = result.summary
            debugLog.append(
                "Cleared workspace=\(result.workspacePath), collection=\(result.collectionName), cache=\(result.cacheFile.path), deletedCollections=\(result.deletedCollections), clearedCacheFiles=\(result.clearedCacheFiles.map(\.path)), missingCollections=\(result.missingCollections), missingCacheFiles=\(result.missingCacheFiles.map(\.path))",
                category: "roo-index"
            )
        } catch {
            workspaceMessage = "Clear Watcher Index failed: \(error.localizedDescription)"
            debugLog.append(workspaceMessage, category: "roo-index.error")
        }
    }

    @discardableResult
    func prepareLocalSecretsForUse() -> Bool {
        do {
            let qdrantKey = try localSecrets.getOrCreateHexSecret(
                account: EmbarsySecret.qdrantAPIKey.rawValue,
                bytes: 32
            )
            let apiKey = try localSecrets.getOrCreateHexSecret(
                account: EmbarsySecret.embarsyAPIKey.rawValue,
                bytes: 24
            )
            applySecrets(qdrantKey: qdrantKey, apiKey: apiKey)
            localSecretsMessage = "Protected local secrets are ready."
            rooConnectionMessage = "Copy the current API Key and Qdrant API Key into Watcher. Old keys from before reinstall will be rejected by Qdrant."
            debugLog.append(localSecretsMessage, category: "secrets")
            return true
        } catch {
            localSecretsNeedsRemediation = true
            localSecretsMessage = "Protected local secrets are unavailable: \(error.localizedDescription)"
            workspaceMessage = localSecretsMessage
            debugLog.append(localSecretsMessage, category: "secrets.error")
            return false
        }
    }

    func refreshSecurityPreflight() {
        securityPreflight = securityService.check()
        debugLog.append("Security preflight refreshed:\n\(securityPreflight.summary)", category: "security")
    }

    func refreshRooDiagnostics() async {
        guard !isRefreshingRooDiagnostics else { return }
        isRefreshingRooDiagnostics = true
        defer { isRefreshingRooDiagnostics = false }

        guard installManager.isInstalled || installManager.isInstalling else {
            rooDiagnosticsMessage = "Watcher/Qdrant diagnostics skipped: components are not installed."
            debugLog.append(rooDiagnosticsMessage, category: "roo-diagnostics")
            return
        }
        guard !config.qdrantAPIKey.isEmpty else {
            rooDiagnosticsMessage = "Qdrant API Key is missing. Run Install to recreate local secrets."
            debugLog.append(rooDiagnosticsMessage, category: "roo-diagnostics.error")
            return
        }

        do {
            let noKeyStatus = try await qdrantCollectionsStatus(apiKey: nil)
            let currentKeyStatus = try await qdrantCollectionsStatus(apiKey: config.qdrantAPIKey)

            guard let http = currentKeyStatus.response as? HTTPURLResponse else {
                rooDiagnosticsMessage = "Qdrant diagnostics failed: no HTTP response."
                debugLog.append(rooDiagnosticsMessage, category: "roo-diagnostics.error")
                return
            }

            if http.statusCode == 200 {
                let authMode = noKeyStatus.httpStatus.map { "No-key probe HTTP \($0)" } ?? "No-key probe unavailable"
                rooDiagnosticsMessage = "Qdrant accepts the current Qdrant API Key (HTTP 200). \(authMode). If Watcher still shows Unauthorized, Watcher settings contain a stale key: copy the current Qdrant API Key from Embarsy into Watcher, then clear/restart Watcher indexing."
                debugLog.append(rooDiagnosticsMessage, category: "roo-diagnostics")
            } else {
                let body = String(data: currentKeyStatus.data, encoding: .utf8) ?? "<non-UTF8 response>"
                rooDiagnosticsMessage = "Qdrant rejects the current key with HTTP \(http.statusCode): \(body). Restart or reinstall the stack, then copy the fresh Qdrant API Key into Watcher."
                debugLog.append(rooDiagnosticsMessage, category: "roo-diagnostics.error")
            }
        } catch {
            rooDiagnosticsMessage = "Qdrant diagnostics failed: \(error.localizedDescription). Start Embarsy stack and retry."
            debugLog.append(rooDiagnosticsMessage, category: "roo-diagnostics.error")
        }
    }

    private func qdrantCollectionsStatus(apiKey: String?) async throws -> (data: Data, response: URLResponse, httpStatus: Int?) {
        var request = URLRequest(url: config.qdrantBaseURL.appendingPathComponent("collections"))
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response, (response as? HTTPURLResponse)?.statusCode)
    }

    func revealLogsInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.logsDirectory])
    }

    func exportDebugLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "embarsy-debug.log"
        panel.allowedContentTypes = [.plainText, .log]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try debugLog.export(to: url)
            debugLogMessage = "Debug log saved to \(url.path)."
            debugLog.append(debugLogMessage, category: "debug")
        } catch {
            debugLogMessage = "Failed to save debug log: \(error.localizedDescription)"
            debugLog.append(debugLogMessage, category: "debug.error")
        }
    }

    func openSecuritySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    private func ensureInstalledBeforeStart(source: String) -> Bool {
        installManager.refreshInstalledState(paths: paths, processManager: processManager)
        guard installManager.isInstalled else {
            workspaceMessage = "\(source) skipped: install Embarsy local stack first."
            installManager.message = "Install Embarsy local stack before starting services."
            selectedTab = .install
            debugLog.append(workspaceMessage, category: "store")
            return false
        }
        return true
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemService.setEnabled(enabled)
            preferences.launchAtLogin = loginItemService.isEnabled
        } catch {
            workspaceMessage = "Failed to update Login Item: \(error.localizedDescription)"
            loginItemService.refresh()
            preferences.launchAtLogin = loginItemService.isEnabled
        }
    }

    func chooseDefaultProject() {
        if let path = workspaceService.chooseProjectFolder() {
            preferences.defaultProjectPath = path
        }
    }

    func openDefaultProjectInVSCode() {
        do {
            try workspaceService.openInVSCode(path: preferences.defaultProjectPath)
            workspaceMessage = "Opened project in VSCode."
        } catch {
            workspaceMessage = error.localizedDescription
        }
    }

    private func applySecrets(qdrantKey: String, apiKey: String) {
        config.qdrantAPIKey = qdrantKey
        config.embarsyAPIKey = apiKey
        processManager.updateConfig(config)
        localSecretsNeedsRemediation = false
    }

    private func bindChildObjectChanges() {
        processManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        installManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        monitoring.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        activity.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        contentIndex.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        preferences.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        loginItemService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}
