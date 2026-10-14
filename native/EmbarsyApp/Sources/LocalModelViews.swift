import SwiftUI

/// Memory → Assistant: what the local model does for memory, then the model itself.
struct AssistantPanel: View {
    @ObservedObject var memory: MemoryService
    @ObservedObject var model: LocalModelService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keeps your memory correct without the busywork: a model on your Mac reads your notes and skills and drafts what needs changing. Free, private, works offline — and nothing changes until you apply a draft.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.isReady, model.download == nil, !model.offered.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Theme.accent)
                    Text("Not set up yet. Download the model below once — then the assistant is ready whenever you need it.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
            }

            VStack(alignment: .leading, spacing: 10) {
                useRow("arrow.triangle.branch", "Moves your memory in",
                       "Sorts the skills, instructions and agent memories you already have into a plan for the base — about ten minutes instead of hours by hand.")
                useRow("text.magnifyingglass", "Catches outdated facts",
                       "Finds notes that say different things about the same subject, so your agents stop following the outdated one.")
                useRow("pencil.and.outline", "Drafts the fixes that need judgment",
                       "Shortens a profile or skill description that's too long, says which of two drifted copies to keep, suggests a name that doesn't clash.")
            }

            Divider().overlay(Theme.separator)

            HStack(alignment: .firstTextBaseline) {
                Text("Local model").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(verbatim: L("optional")).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }
            LocalModelControls(model: model)
        }
    }

    private func useRow(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The local model itself: pick, download, see whether it's holding memory right now, and
/// free that memory at once.
struct LocalModelControls: View {
    @ObservedObject var model: LocalModelService
    @State private var deleteArmed = false

    private static let idleChoices: [(seconds: Int, label: String)] = [
        (60, L("1 min")), (120, L("2 min")), (300, L("5 min")), (600, L("10 min")), (1800, L("30 min")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On disk it only takes space; it loads into memory when the assistant is asked something and leaves after the idle time below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.offered.isEmpty {
                Text("This Mac has \(model.memoryGB) GB of memory; a local model needs at least 16 GB next to everything else. Your own agent does this work instead.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                picker
                statusRow
                idleRow
            }
            if let error = model.lastError {
                Text(verbatim: error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(model.download == nil ? 3 : 1))
            }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Model").font(.callout)
                Picker("Model", selection: $model.selected) {
                    ForEach(model.offered) { choice in
                        Text(verbatim: choice.tag == model.offered.first?.tag ? L("\(choice.label) · \(Self.gb(choice.downloadGB)) · recommended") : "\(choice.label) · \(Self.gb(choice.downloadGB))")
                            .tag(choice.tag)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.download != nil)
            }
            if let choice = model.offered.first(where: { $0.tag == model.selected }) {
                Text(verbatim: choice.note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        if let download = model.download {
            HStack(spacing: 10) {
                ProgressView(value: download.fraction)
                    .frame(maxWidth: 260)
                Text(verbatim: download.total > 0
                     ? L("\(Self.gb(bytes: download.completed)) of \(Self.gb(bytes: download.total))")
                     : download.status)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Stop") { model.cancelDownload() }
            }
            Text("You can stop and continue later — the download picks up where it left off.")
                .font(.caption).foregroundStyle(.secondary)
        } else if !model.isReady {
            HStack(spacing: 10) {
                StateGlyph(state: .missing)
                Text("Not downloaded").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Download") { model.startDownload(model.selected) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!hasRoom)
            }
            if !hasRoom {
                Text("Not enough free disk space: the model needs \(Self.gb(selectedChoice?.downloadGB ?? 0)) plus 5 GB to spare, \(Self.gb(bytes: freeBytes)) is free.")
                    .font(.callout).foregroundStyle(.orange)
            }
        } else if let loaded = model.loadedSelected {
            HStack(spacing: 10) {
                StateGlyph(state: .inMemory)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: ModelFormat.inMemory(bytes: loaded.bytes, expiresAt: loaded.expiresAt, now: context.date))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Unload now") { Task { await model.unload(loaded.name) } }
            }
        } else {
            HStack(spacing: 10) {
                StateGlyph(state: .onDisk)
                Text("Downloaded · not in memory").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if deleteArmed {
                    Text("Delete the model from disk?").font(.callout)
                    Button("Delete", role: .destructive) {
                        deleteArmed = false
                        Task { await model.delete(model.selected) }
                    }
                    Button("Cancel") { deleteArmed = false }
                } else {
                    Button("Delete…") { deleteArmed = true }
                }
            }
        }
    }

    private var idleRow: some View {
        HStack(spacing: 8) {
            Text("Leave memory after").font(.callout)
            Picker("", selection: $model.idleTimeout) {
                ForEach(Self.idleChoices, id: \.seconds) { Text(verbatim: $0.label).tag($0.seconds) }
            }
            .labelsHidden()
            .frame(width: 100)
            Text("without a request").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var selectedChoice: LocalModelService.Choice? {
        LocalModelService.catalog.first { $0.tag == model.selected }
    }

    private var freeBytes: Int64 {
        let url = FileManager.default.homeDirectoryForCurrentUser
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    private var hasRoom: Bool {
        guard let choice = selectedChoice else { return false }
        return Double(freeBytes) >= (choice.downloadGB + 5) * 1_000_000_000
    }

    private static func gb(_ value: Double) -> String { ModelFormat.gb(value) }
    private static func gb(bytes: Int64) -> String { ModelFormat.gb(bytes: bytes) }
}

/// Settings → Embedding model: the model every search and index goes through. It can't be
/// turned off, but it doesn't have to sit in memory between searches.
struct EmbeddingModelCard: View {
    @EnvironmentObject private var store: EmbarsyStore
    @ObservedObject var model: LocalModelService
    @State private var minutes = EmbarsyConfig.embeddingIdleMinutes

    private static let choices: [(minutes: Int, label: String)] = [
        (1, L("1 min")), (5, L("5 min")), (10, L("10 min")), (30, L("30 min")), (120, L("2 hours")),
    ]

    var body: some View {
        EmbarsySection(title: "Embedding model", right: store.config.ollamaModel) {
            Text("Turns code and notes into vectors for search and indexing. It loads on the first search and leaves memory after the idle time below; the next search loads it again in a couple of seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let loaded = model.embeddingLoaded {
                    StateGlyph(state: .inMemory, help: Self.glyphHelp)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(verbatim: ModelFormat.inMemory(bytes: loaded.bytes, expiresAt: loaded.expiresAt, now: context.date))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Unload now") { Task { await model.unload(loaded.name) } }
                } else {
                    StateGlyph(state: .onDisk, help: Self.glyphHelp)
                    Text("Not in memory · loads on the next search").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                }
            }
            HStack(spacing: 8) {
                Text("Leave memory after").font(.callout)
                Picker("", selection: Binding(get: { minutes }, set: { minutes = $0; store.setEmbeddingIdle(minutes: $0) })) {
                    ForEach(Self.choices, id: \.minutes) { Text(verbatim: $0.label).tag($0.minutes) }
                }
                .labelsHidden()
                .frame(width: 100)
                Text("without a search").font(.callout).foregroundStyle(.secondary)
            }
            Text("A new idle time applies from the next search: Embarsy's service restarts for it, after any indexing in progress.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private static let glyphHelp = L("Empty circle — the embedding model isn't in memory; the next search loads it. Filled circle — it's in memory now; it leaves by itself after the idle time, or at once with Unload now.")
}

enum ModelFormat {
    static func gb(_ value: Double) -> String {
        value >= 10 ? L("\(Int(value.rounded())) GB") : L("\(String(format: "%.1f", value)) GB")
    }

    static func gb(bytes: Int64) -> String { gb(Double(bytes) / 1_000_000_000) }

    /// "In memory · 5.2 GB · leaves in 1:59" — the countdown only while there is one.
    static func inMemory(bytes: Int64, expiresAt: Date?, now: Date) -> String {
        let size = gb(bytes: bytes)
        guard let left = leaves(expiresAt, now: now) else { return L("In memory · \(size)") }
        return L("In memory · \(size) · leaves in \(left)")
    }

    /// The time left as h:mm:ss or m:ss, or nil when there's no countdown to show.
    static func leaves(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let left = Int(date.timeIntervalSince(now))
        // Ollama reports a far-future time for a model told to stay forever.
        guard left > 0, left < 86_400 else { return nil }
        return left >= 3600
            ? String(format: "%d:%02d:%02d", left / 3600, left % 3600 / 60, left % 60)
            : String(format: "%d:%02d", left / 60, left % 60)
    }
}

private struct StateGlyph: View {
    enum State { case missing, onDisk, inMemory }
    let state: State
    var help = L("Dashed circle — the model isn't downloaded. Empty circle — downloaded, takes only disk space, no memory. Filled circle — loaded into memory now; it leaves by itself after the idle time, or at once with Unload now.")

    var body: some View {
        Group {
            switch state {
            case .missing: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            case .onDisk: Image(systemName: "circle").foregroundStyle(.secondary)
            case .inMemory: Image(systemName: "circle.fill").foregroundStyle(Theme.accent)
            }
        }
        .font(.system(size: 11))
        .chipHelp(verbatim: help)
    }
}
