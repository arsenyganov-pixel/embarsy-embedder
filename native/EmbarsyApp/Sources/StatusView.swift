import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var store: EmbarsyStore

    private var running: Bool { store.aggregateStatus == .running }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapSection) {
                brandHero
                servicesSection

                Text(store.localSecretsMessage)
                    .font(.callout)
                    .foregroundStyle(store.localSecretsNeedsRemediation ? .orange : .secondary)

                if !store.workspaceMessage.isEmpty {
                    Text(store.workspaceMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                RooConnectionView()

                BenchmarkView(service: store.benchmark)
            }
            .padding(Theme.padScreen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Brand hero

    private var brandHero: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    // Keep a 26pt layout footprint (so the title stays exactly put) but draw the
                    // mark larger, leading-aligned, so it grows into the gap toward the title.
                    Color.clear
                        .frame(width: 26, height: 26)
                        .overlay(alignment: .leading) {
                            EmbarsyMarkView(color: Theme.markTint(store.aggregateStatus), animated: running && !EmbarsyLaunchOverrides.stillMode)
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                                .chipHelp("Overall status, shown by the mark's colour: teal = all running, amber = starting up, red = a service failed, grey = stopped.")
                        }
                    (Text("Emb").font(.system(size: 19, weight: .heavy))
                        + Text("arsy").font(.system(size: 19, weight: .medium))
                        + Text(".").font(.system(size: 19, weight: .heavy)).foregroundColor(Theme.accent))
                        .foregroundStyle(.primary)
                }
                Text("Local semantic index")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                statusPill
                if running {
                    Text("uptime \(store.uptimeText)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var statusPill: some View {
        let color: Color = running ? Color(nsColor: .systemGreen) : .secondary
        return HStack(spacing: 7) {
            Circle().fill(running ? Color(nsColor: .systemGreen) : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 8, height: 8)
            Text(running ? "All systems operational" : "All systems stopped")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background((running ? Color(nsColor: .systemGreen) : Color(nsColor: .systemGray)).opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke((running ? Color(nsColor: .systemGreen) : Color(nsColor: .systemGray)).opacity(0.28)))
    }

    // MARK: Services

    private var runningCount: Int {
        ManagedService.allCases.filter { store.serviceStatus(for: $0) == .running }.count
    }
    /// True if at least one service is running — starting again would just fail, so Start All disables.
    private var anyRunning: Bool { runningCount > 0 }

    private var servicesSection: some View {
        EmbarsySection(title: "Services", right: anyRunning ? "\(runningCount) running" : "all stopped") {
            VStack(spacing: 0) {
                ForEach(Array(ManagedService.allCases.enumerated()), id: \.element) { index, service in
                    if index > 0 { Divider().overlay(Theme.separator) }
                    serviceRow(service)
                }
            }
            .padding(.horizontal, -14)   // full-bleed inside the card

            HStack(spacing: Theme.gapRow) {
                // Once anything is running, Start All is disabled (starting again just fails) and
                // Stop All becomes the highlighted action. When everything is stopped it flips.
                if anyRunning {
                    Button("Start All") { Task { await store.startAll() } }
                        .buttonStyle(.bordered)
                        .disabled(true)
                    Button("Stop All") { store.processManager.stopAll() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                } else {
                    Button("Start All") { Task { await store.startAll() } }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                    Button("Stop All") { store.processManager.stopAll() }
                        .buttonStyle(.bordered)
                }
                Button("Refresh") { Task { await store.refreshServiceStatuses() } }
                    .buttonStyle(.bordered)
                Button("Show Logs") { store.revealLogsInFinder() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
    }

    private func serviceRow(_ service: ManagedService) -> some View {
        let status = store.serviceStatus(for: service)
        return HStack(spacing: 10) {
            Circle()
                .strokeBorder(Theme.status(status), lineWidth: 2)
                .frame(width: 12, height: 12)
            Text(service.title).font(.body)
            Text(store.serviceMessage(for: service))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if service == .api, status == .running, store.apiUpdateAvailable {
                apiUpdateButton
            }
            Text(status.title)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Theme.status(status))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    /// Shown when the RUNNING API is older than the one bundled with this app (typical
    /// right after installing a new Embarsy version while the stack kept running).
    /// Restarts only the API — Qdrant, Ollama, the model and every index stay untouched.
    private var apiUpdateButton: some View {
        Button {
            Task { await store.updateAPIService() }
        } label: {
            HStack(spacing: 5) {
                if store.isUpdatingAPI {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                }
                Text(store.isUpdatingAPI ? "Updating..." : "Update")
                    .font(.system(size: 11.5, weight: .semibold))
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .controlSize(.small)
        .disabled(store.isUpdatingAPI)
        .chipHelp("A newer Embarsy API (\(EmbarsyConfig.bundledAPIVersion)) ships with this app. Update restarts only the API — Qdrant, Ollama and your indexes are not touched.")
    }
}
