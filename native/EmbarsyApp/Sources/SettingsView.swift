import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: EmbarsyStore
    @State private var hardResetArmed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BrandedHeader(title: "Settings", subtitle: "Startup, local secrets, and installed components.")

                startupCard

                // A Grid row sizes both cells to the taller card's height; `fillHeight` lets each
                // card's surface fill that height so they read as equal in the row.
                Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                    GridRow {
                        runtimeBuildCard
                        defaultProjectCard
                    }
                }

                localSecretsCard
                debugLogCard
                installStateCard

                EmbarsySection(title: "App Support") {
                    SupportChip()
                }
            }
            .padding(Theme.padScreen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var startupCard: some View {
        EmbarsySection(title: "Startup") {
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Launch Embarsy at login", isOn: Binding(
                    get: { store.preferences.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
                .tint(Theme.accent)
                Text("Login Item status: \(store.loginItemService.statusText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 48)
            }
            Toggle("Start stack when Embarsy launches", isOn: $store.preferences.startStackOnLaunch)
                .tint(Theme.accent)
        }
    }

    private var runtimeBuildCard: some View {
        EmbarsySection(title: "Runtime build", right: "arm64", fillHeight: true) {
            Text(store.buildInfoSummary)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(EmbarsyBuildInfo.isRunningFromMountedVolume ? .orange : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultProjectCard: some View {
        EmbarsySection(title: "Default project", fillHeight: true) {
            HStack(spacing: 10) {
                Button("Choose…") { store.chooseDefaultProject() }
                Text(store.preferences.defaultProjectPath.isEmpty ? "Not selected" : store.preferences.defaultProjectPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var localSecretsCard: some View {
        EmbarsySection(title: "Local secrets") {
            Text(store.localSecretsMessage)
                .font(.callout)
                .foregroundStyle(store.localSecretsNeedsRemediation ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh Local Secrets Status") { store.refreshLocalSecretsStatus() }
                Button("Recreate Local Secrets", role: .destructive) {
                    Task { await store.repairLocalSecrets() }
                }
            }
        }
    }

    private var debugLogCard: some View {
        EmbarsySection(title: "Debug log") {
            Text(store.debugLog.fileURL.path)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(store.debugLogMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Save Debug Log…") { store.exportDebugLog() }
                Button("Open Logs Folder") { store.revealLogsInFinder() }
            }
        }
    }

    private var installStateCard: some View {
        EmbarsySection(title: "Install state", right: store.installManager.isInstalled ? "installed" : "not installed") {
            HStack {
                Button("Refresh Install State") { store.refreshInstalledState() }
                Button("Remove Components and Clear Secrets", role: .destructive) {
                    hardResetArmed = true
                }
            }
            if hardResetArmed {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemRed))
                    Text("Confirm removal?")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Remove Everything", role: .destructive) {
                        Task {
                            await store.removeComponentsAndLocalSecrets()
                            hardResetArmed = false
                        }
                    }
                    Button("Cancel") { hardResetArmed = false }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(nsColor: .systemRed).opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(nsColor: .systemRed).opacity(0.28)))
            }
            HelpNote("Removes Embarsy App Support data, local service files and protected local secrets. Services will be stopped first.")
            if !store.installManager.message.isEmpty {
                Text(store.installManager.message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
