import SwiftUI

/// The values Zoo / Roo Code needs pasted into its Codebase Indexing settings. Lives in the
/// Connections screen's Zoo / Roo tab — the one place that explains what to do with them.
struct RooConnectionParameters: View {
    @EnvironmentObject private var store: EmbarsyStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapRow) {
            ConnectionRow(label: "Embedder Provider", value: "OpenAI Compatible")
            ConnectionRow(label: "Base URL", value: store.config.apiBaseURL.absoluteString)
            ConnectionRow(label: "Compatibility Endpoint", value: "/embeddings and /v1/embeddings")
            ConnectionRow(label: "API Key", value: store.config.embarsyAPIKey, secret: true)
            ConnectionRow(label: "Model", value: store.config.ollamaModel)
            ConnectionRow(label: "Embedding Dimension", value: String(store.config.embeddingDimension), accent: true)
            ConnectionRow(label: "Qdrant URL", value: store.config.qdrantProxyBaseURL.absoluteString)
            ConnectionRow(label: "Qdrant API Key", value: store.config.qdrantAPIKey, secret: true)
            ConnectionRow(label: "Search Score Threshold", value: store.config.searchScoreThreshold)
            ConnectionRow(label: "Maximum Search Results", value: store.config.maxSearchResults)

            if !store.rooConnectionMessage.isEmpty {
                // Advice shown on every launch, not a failure — so it reads as guidance, not alarm.
                Text(store.rooConnectionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 8) {
                Text(store.rooDiagnosticsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(store.isRefreshingRooDiagnostics ? "Checking..." : "Check Qdrant Key") {
                    Task { await store.refreshRooDiagnostics() }
                }
                .disabled(store.isRefreshingRooDiagnostics)
            }

            Text("Use Embedding Dimension 1024 exactly, and set the Qdrant URL to the Embarsy proxy value above so Monitoring can count Watcher vector reads and writes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("After Remove Components and Clear Secrets or a fresh Install, copy the current API Key and Qdrant API Key from this screen into Zoo / Roo settings. Embarsy verifies the API key before marking the stack as installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

/// A single connection parameter: label on the left, monospaced value that
/// truncates before it can overtake the label, and a fixed-width Copy button
/// whose "Copied" confirmation never changes the row width.
private struct ConnectionRow: View {
    let label: String
    let value: String
    var accent: Bool = false
    var secret: Bool = false

    @State private var copied = false
    @State private var shown = false

    private var masked: Bool { secret && !shown }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.body)
                // Keep the label intact; the value truncates instead (≈≤58% of the row).
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(masked ? String(repeating: "\u{2022}", count: 12) : value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(accent ? Color(nsColor: .systemGreen) : .primary)
                .tracking(masked ? 2 : 0)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            if secret {
                Button { shown.toggle() } label: {
                    Image(systemName: shown ? "eye.slash" : "eye")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(shown ? "Hide" : "Reveal")
            }
            Button(copied ? "Copied" : "Copy") { copy() }
                .frame(width: 62)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            copied = false
        }
    }
}

/// Shown on Status while the API is rejecting keys that have Embarsy's shape but belong to a
/// previous installation. It stays on Status rather than moving with the parameters: stale
/// keys break Claude Code and Codex just as surely as Zoo / Roo, and Status is where someone
/// looks first when "authentication failed" appears.
struct StaleKeyBanner: View {
    @EnvironmentObject private var store: EmbarsyStore

    var body: some View {
        if store.staleEditorKeyDetected { banner }
    }

    /// Shown only while the API is actively rejecting Embarsy-shaped keys that belong to
    /// a previous installation — the exact "authentication failed forever" trap that a
    /// reinstall sets for an editor configured earlier.
    private var banner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "key.slash.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .contentShape(Rectangle())
                    .chipHelp("Shown while the running API is rejecting keys that have Embarsy's own shape but belong to a previous installation. It disappears on its own once those retries stop.")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your editor is using keys from a previous Embarsy installation")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemRed))
                    Text("Reinstalling regenerates BOTH keys, so the editor keeps failing with “authentication failed”. Claude Code and Codex: press Reconnect in Connections. Zoo / Roo: paste the current keys into its indexing settings and press Save there.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Copy API Key") { copy(store.config.embarsyAPIKey) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                Button("Copy Qdrant API Key") { copy(store.config.qdrantAPIKey) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .systemRed).opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(nsColor: .systemRed).opacity(0.30)))
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
