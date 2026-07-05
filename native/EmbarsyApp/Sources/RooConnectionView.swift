import SwiftUI

struct RooConnectionView: View {
    @EnvironmentObject private var store: EmbarsyStore

    var body: some View {
        EmbarsySection(title: "Connection Parameters", spacing: Theme.gapRow) {
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
                Text(store.rooConnectionMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
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

            Text("After Remove Components and Clear Secrets or a fresh Install, copy the current API Key and Qdrant API Key from this screen into Watcher settings. Embarsy verifies the API key before marking the stack as installed.")
                .font(.caption)
                .foregroundStyle(.orange)
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
