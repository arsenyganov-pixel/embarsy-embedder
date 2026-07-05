import SwiftUI

struct InstallView: View {
    @EnvironmentObject private var store: EmbarsyStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Install")
                    .font(.largeTitle.bold())
                Text(store.installManager.message)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Build \(EmbarsyBuildInfo.bundleVersion) · \(EmbarsyBuildInfo.bundlePath)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    if let warning = EmbarsyBuildInfo.mountedVolumeWarning {
                        Text(warning)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !store.installManager.isInstalling && !store.installManager.isModelDownloadActive {
                    Text(store.installManager.detailMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ProgressView(value: store.installManager.progress) {
                    Text(store.installManager.currentStep.title)
                }

                if store.installManager.shouldShowInstallActivity {
                    HStack(alignment: .top, spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Install activity")
                                .font(.callout.weight(.semibold))
                            if !store.installManager.modelDownloadCommand.isEmpty {
                                Text(store.installManager.modelDownloadCommand)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                                Text(store.installManager.modelDownloadActivity.isEmpty
                                ? "Install polling is active. Waiting for the next setup event..."
                                : store.installManager.modelDownloadActivity)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if !store.installManager.modelDownloadLastOutputAge.isEmpty {
                                Text(store.installManager.modelDownloadLastOutputAge)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.installManager.binaryChecks) { check in
                        HStack {
                            Image(systemName: check.isExecutable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(check.isExecutable ? .green : .red)
                            Text(check.service.title)
                            Spacer()
                            Text(check.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button("Install") {
                        Task { await store.install() }
                    }
                    .disabled(store.installManager.isInstalling)

                    Button("Install and Start") {
                        Task { await store.installAndStart() }
                    }
                    .disabled(store.installManager.isInstalling)

                    Button("Refresh") {
                        Task {
                            await store.refreshServiceStatuses()
                        }
                    }

                    Button("Show Logs") { store.revealLogsInFinder() }
                }

                if store.installManager.isInstalled || store.installManager.isInstalling {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ManagedService.allCases) { service in
                            let message = store.serviceMessage(for: service)
                            Text("\(service.title): \(message)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Components are removed. Install to recreate the local stack.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Model download is performed by bundled Ollama and can take several minutes on the first install.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if store.installManager.isInstalling || store.installManager.isModelDownloadActive {
                    Text("Large model layers may stay on the same percentage for a while. The spinner, elapsed-time text and last-output age confirm that installation polling is still active while Ollama downloads or verifies the layer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
