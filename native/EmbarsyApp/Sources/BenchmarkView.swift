import SwiftUI
import UniformTypeIdentifiers

/// The Status-screen "Benchmark" chip: grep vs semantic search, on the user's own
/// indexed code. The design goal is to make the RAG-vs-grep difference tangible —
/// grep matches words (and buries you in lines); the semantic index matches meaning
/// (and hands you a ranked shortlist).
struct BenchmarkView: View {
    @EnvironmentObject private var store: EmbarsyStore
    /// Owned by the store: a run keeps going while the user browses other tabs, and
    /// the last result (persisted on disk) is always here when they come back.
    @ObservedObject var service: BenchmarkService
    @State private var collectionMenuOpen = false
    @State private var detailsOpen = false
    @State private var methodologyOpen = false
    @State private var duelHelpOpen = false
    /// Paraphrase discipline: swap ONE word of each question for a fixed-table synonym
    /// — the test literal search cannot ace, because that word is no longer literally
    /// in the file. ON by default: the paraphrase duel is the story that matters;
    /// switch off for verbatim words (grep's home turf).
    @State private var useSynonyms = true

    private let grepColor = Theme.offGray
    private let semanticColor = Theme.accent

    private var collections: [ContentIndexCollection] {
        store.contentIndex.snapshot.collections.sorted { $0.pointsCount > $1.pointsCount }
    }
    private var activeCollection: String? {
        service.selectedCollection ?? collections.first?.collectionName
    }
    /// The folder the selected collection was indexed from, when Embarsy knows it and it
    /// still exists — the only folder grep can fairly race over. Previously every collection
    /// was paired with the single default folder from Settings, so the benchmark worked for
    /// exactly one collection and refused (correctly, with a mismatch error) for all others.
    private var collectionFolder: URL? {
        guard let name = activeCollection,
              let folder = collections.first(where: { $0.collectionName == name })?.revealableFolder,
              FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return folder
    }

    /// The Settings default is now only the fallback for a collection whose folder is unknown.
    private var workspacePath: String { collectionFolder?.path ?? store.preferences.defaultProjectPath }

    var body: some View {
        EmbarsySection(title: "Benchmark", right: "grep vs meaning") {
            Text("Same question, two engines — on your own indexed code. Questions are sampled from real chunks; grep is real `/usr/bin/grep` playing its best game — the AND pipeline over the exact folder this collection indexes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            controls

            switch service.phase {
            case .idle:
                EmptyView()
            case .running(let stage):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(stage).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if message.contains("does not match") {
                        HStack(spacing: 10) {
                            Text("The Workspace folder is set on the Settings page (\u{201C}Default project\u{201D}).")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Open Settings") { store.selectedTab = .settings }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            case .done:
                EmptyView()
            }

            if let result = service.result {
                let isRunning: Bool = { if case .running = service.phase { return true } else { return false } }()
                VStack(alignment: .leading, spacing: 10) {
                    if let selected = activeCollection, selected != result.collection {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                            Text("The result below is for **\(shortCollectionTitle(result.collection))** (\(abbreviatedPath(result.workspacePath))). You now have \(shortCollectionTitle(selected)) selected — press Run \(service.result == nil ? "benchmark" : "again") to benchmark it.")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if isRunning {
                        Text("Previous result — a new run is in flight.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    duelResults(result)
                    editorSection(result)
                }
                .opacity(isRunning ? 0.55 : 1)
            }
        }
        // Every dropdown here toggles on a click anywhere in its header, not just the arrow.
        .disclosureGroupStyle(TappableDisclosureStyle())
        .task {
            // The stack may still be starting when Status first appears — keep trying
            // for a while so the collection picker fills in without a manual refresh.
            for _ in 0..<10 {
                if Task.isCancelled { return }
                if !store.contentIndex.snapshot.collections.isEmpty { break }
                await store.refreshContentIndex()
                if !store.contentIndex.snapshot.collections.isEmpty { break }
                try? await Task.sleep(for: .seconds(3), tolerance: .milliseconds(500))
            }
            // Dev/screenshot hook (inert normally): EMBARSY_BENCH_AUTORUN=<collection>
            // runs the benchmark on launch without a click.
            if service.result == nil,
               let wanted = ProcessInfo.processInfo.environment["EMBARSY_BENCH_AUTORUN"],
               !workspacePath.isEmpty {
                let collection = collections.first(where: { $0.collectionName == wanted })?.collectionName
                    ?? activeCollection
                if let collection {
                    service.selectedCollection = collection
                    // EMBARSY_BENCH_PARAPHRASE=1/0 overrides; unset follows the toggle default.
                    let paraphrase = ProcessInfo.processInfo.environment["EMBARSY_BENCH_PARAPHRASE"]
                        .map { $0 == "1" } ?? useSynonyms
                    useSynonyms = paraphrase
                    await service.runRetrieval(config: store.config, collection: collection,
                                               workspacePath: workspacePath, paraphrase: paraphrase)
                }
            }
            // Dev hook (inert normally): EMBARSY_BENCH_SELECT=<collection> preselects
            // a collection in the picker without running anything.
            if let preselect = ProcessInfo.processInfo.environment["EMBARSY_BENCH_SELECT"] {
                service.selectedCollection = preselect
            }
            // Dev/screenshot hook (inert normally): open the explanation dropdowns.
            if ProcessInfo.processInfo.environment["EMBARSY_BENCH_EXPAND"] == "1" {
                methodologyOpen = true; duelHelpOpen = true
            }
            // Dev hook (inert normally): EMBARSY_BENCH_EXPORT_LOG=<path> writes the
            // composed Markdown log to disk — lets CI/screenshot runs verify the export.
            if let exportPath = ProcessInfo.processInfo.environment["EMBARSY_BENCH_EXPORT_LOG"],
               let result = service.result {
                let log = BenchmarkLogComposer.compose(
                    result: result, lastRun: service.lastRunDate,
                    duels: service.agentDuels, duelEditor: service.agentEditor)
                try? log.write(toFile: exportPath, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button { collectionMenuOpen.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "tablecells").font(.caption).foregroundStyle(.secondary)
                    Text(activeCollection.map(shortCollectionTitle) ?? "no collections")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).frame(height: 34)
                .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.separator))
            }
            .buttonStyle(.plain)
            .disabled(collections.isEmpty)
            .popover(isPresented: $collectionMenuOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(collections) { collection in
                        Button {
                            service.selectedCollection = collection.collectionName
                            collectionMenuOpen = false
                        } label: {
                            HStack {
                                Text(shortCollectionTitle(collection.collectionName))
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("\(collection.pointsCount) pts")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .frame(minWidth: 260)
            }

            if workspacePath.isEmpty {
                Button("Choose project folder…") { store.chooseDefaultProject() }
                    .buttonStyle(.bordered)
                Text("grep needs the folder this collection indexes")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if let folder = collectionFolder {
                // A path is navigation: it reveals the folder grep will race over.
                FinderLink(label: abbreviatedPath(folder.path), folder: folder,
                           font: .system(.caption, design: .monospaced))
            } else {
                Text(abbreviatedPath(workspacePath))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                    .chipHelp("Embarsy doesn't know which folder this collection indexes, so grep uses the default project folder from Settings. If the two don't match, the benchmark stops with a mismatch error rather than racing over the wrong code.")
            }

            Spacer()

            Toggle(isOn: $useSynonyms) {
                Text("synonyms")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(useSynonyms ? Theme.accent : .secondary)
            }
            .toggleStyle(.checkbox)
            .chipHelp("Paraphrase test: one word of each question is swapped for a fixed-table synonym before the duel. The right file no longer contains that literal word — grep must fall back, while the semantic index should still land it by meaning. One swap keeps the question anchored to its file; more would drift it away. Swaps are listed per question and in the saved log.")

            Button {
                guard let collection = activeCollection else { return }
                let paraphrase = useSynonyms
                Task {
                    await service.runRetrieval(config: store.config, collection: collection,
                                               workspacePath: workspacePath, paraphrase: paraphrase)
                }
            } label: {
                Label(service.result == nil ? "Run benchmark" : "Run again", systemImage: "flag.checkered")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(activeCollection == nil || workspacePath.isEmpty)
            .disabled({ if case .running = service.phase { return true } else { return false } }())
            .disabled({ if case .running = service.agentPhase { return true } else { return false } }())
        }
    }

    // MARK: Duel results

    private func duelResults(_ result: RetrievalBenchmark) -> some View {
        let semantic = result.summary.semantic
        let grep = result.summary.grep
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                engineBadge("grep", color: grepColor, mono: true)
                Text("vs").font(.caption).foregroundStyle(.tertiary)
                engineBadge("Embarsy.", color: semanticColor, mono: false)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(result.samples) questions · top-\(result.topK)")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    Text("\(shortCollectionTitle(result.collection)) · \(abbreviatedPath(result.workspacePath))\(result.paraphrased == true ? " · synonym questions" : "")")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                    if let lastRun = service.lastRunDate {
                        Text("last run \(lastRun.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(.quaternary)
                    }
                }
            }

            metricRow(
                title: "Right file found (top-\(result.topK))",
                grepText: "\(grep.hitTopK)/\(result.samples)",
                semanticText: "\(semantic.hitTopK)/\(result.samples)",
                grepFraction: Double(grep.hitTopK) / Double(max(result.samples, 1)),
                semanticFraction: Double(semantic.hitTopK) / Double(max(result.samples, 1))
            )
            let allGrepTimedOut = (grep.timeouts ?? 0) >= result.samples
            metricRow(
                title: "Median time to a ranked answer",
                grepText: allGrepTimedOut ? "n/a" : formatSeconds(grep.medianLatencyMS),
                semanticText: formatSeconds(semantic.medianLatencyMS),
                grepFraction: allGrepTimedOut ? 0.02 : fractionSmallerIsBetter(mine: grep.medianLatencyMS, other: semantic.medianLatencyMS),
                semanticFraction: fractionSmallerIsBetter(mine: semantic.medianLatencyMS, other: grep.medianLatencyMS)
            )
            metricRow(
                title: "To sift through, per question",
                grepText: (grep.medianMatchedLines ?? 0) <= 0 ? "n/a" : "\(Int(grep.medianMatchedLines ?? 0)) lines",
                semanticText: "\(result.topK) snippets",
                grepFraction: fractionSmallerIsBetter(mine: grep.medianMatchedLines ?? 0, other: Double(result.topK)),
                semanticFraction: fractionSmallerIsBetter(mine: Double(result.topK), other: grep.medianMatchedLines ?? 0),
                semanticInfo: "“Lines” and “snippets” are different units, on purpose — that’s the whole point of the comparison.\n\nLEFT (grep): every matching line across all the files grep found — raw text you scroll through by eye to locate the answer. Mostly noise.\n\nRIGHT (Embarsy): a fixed handful — the top \(result.topK) ranked snippets. Each is one short, already-relevant code chunk with its file, ordered by meaning. You read these, you don’t sift them.\n\nSo the left number is how much you’d have to wade through; the right number is how little you’d actually read."
            )
            if let timeouts = grep.timeouts, timeouts > 0 {
                Text("\(timeouts) grep run\(timeouts == 1 ? "" : "s") exceeded the 15 s budget and \(timeouts == 1 ? "was" : "were") stopped — excluded from the medians above.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let root = result.grepRoot, root != result.workspacePath {
                Text("Both engines searched \(abbreviatedPath(root)) — the folder this collection actually indexes, detected from the sampled files. grep is never made to scan siblings the index doesn't cover.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if result.meaningWins > 0 {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 13)).foregroundStyle(semanticColor)
                    Text("**Meaning won \(result.meaningWins) of \(result.samples).** In those questions grep found files matching the query words — and the right file still never reached its top-\(result.topK). The semantic index ranked it by meaning instead.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(semanticColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(semanticColor.opacity(0.25)))
            }

            DisclosureGroup(isExpanded: $detailsOpen) {
                VStack(spacing: 6) {
                    ForEach(result.queries.sorted { $0.meaningWins && !$1.meaningWins }) { row in
                        queryRow(row, topK: result.topK)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Per-question details")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $methodologyOpen) {
                Text("Questions are concept words extracted from randomly sampled chunks of this collection; the source file is the ground truth and is verified to exist in your folder. By construction every query word is literally present in the answer file — that aids grep (its AND pipeline can always reach the file) as much as the index, so the duel measures ranking under noise and time-to-answer, not paraphrase understanding. grep plays its competent game: files containing ALL the words (classic `grep -ril | xargs` pipeline), ranked by match density, over the folder the collection indexes; one-pass OR is the fallback. grep timings include normal filesystem caching, while the embedding model is pre-warmed, as it is in real use. \(result.samples) sampled questions are an indication, not a paper — run it again for a fresh sample.")
                    .font(.system(size: 12.5)).lineSpacing(2.5).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                Text("How this is measured")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    saveLog(result)
                } label: {
                    Label("Save full log…", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.bordered).controlSize(.small)
                Text("Human-readable Markdown: every query, the exact grep commands, timings, ranked files and context sizes.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    /// Full transparency export — people rightly distrust a benchmark they can't inspect.
    private func saveLog(_ result: RetrievalBenchmark) {
        let panel = NSSavePanel()
        let stamp = (service.lastRunDate ?? Date()).formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Embarsy-benchmark-\(stamp).md"
        panel.canCreateDirectories = true
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let log = BenchmarkLogComposer.compose(
            result: result, lastRun: service.lastRunDate,
            duels: service.agentDuels, duelEditor: service.agentEditor)
        do {
            try log.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save the benchmark log"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func engineBadge(_ title: String, color: Color, mono: Bool) -> some View {
        Text(title)
            .font(mono ? .system(size: 12, weight: .semibold, design: .monospaced)
                       : .system(size: 12, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.35)))
    }

    private func metricRow(title: String, grepText: String, semanticText: String,
                           grepFraction: Double, semanticFraction: Double,
                           semanticInfo: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                valueBar(text: grepText, fraction: grepFraction, color: grepColor, mono: true)
                valueBar(text: semanticText, fraction: semanticFraction, color: semanticColor, mono: false, info: semanticInfo)
            }
        }
    }

    private func valueBar(text: String, fraction: Double, color: Color, mono: Bool, info: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(text)
                    .font(.system(size: 16, weight: .bold, design: mono ? .monospaced : .default).monospacedDigit())
                    .foregroundStyle(color)
                if let info {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        // The glyph is tiny (~12pt) and hard to land the cursor on; pad it out
                        // to a ~24pt hit target (contentShape makes the padding hoverable) so the
                        // tooltip is easy to trigger. Negative margins keep the layout unchanged.
                        .padding(6)
                        .contentShape(Rectangle())
                        .chipHelp(info)
                        .padding(-6)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fillQuaternary)
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: max(4, proxy.size.width * max(0, min(1, fraction))))
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
    }

    private func queryRow(_ row: BenchmarkQueryRow, topK: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("“\(row.query)”")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.tail)
                if let swaps = row.swapped, !swaps.isEmpty {
                    Text(swaps.map { "\($0.from)→\($0.to)" }.joined(separator: " "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
                if row.meaningWins {
                    Text("meaning wins")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(semanticColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(semanticColor.opacity(0.12), in: Capsule())
                }
                Spacer()
            }
            HStack(spacing: 14) {
                rankLabel(engine: "grep", rank: row.grep.rank, topK: topK,
                          detail: "\(row.grep.matchedLines ?? 0) lines · \(formatSeconds(row.grep.latencyMS))",
                          color: grepColor)
                rankLabel(engine: "embarsy", rank: row.semantic.rank, topK: topK,
                          detail: formatSeconds(row.semantic.latencyMS),
                          color: semanticColor)
                Spacer()
                Text(row.truthFile.components(separatedBy: "/").suffix(2).joined(separator: "/"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func rankLabel(engine: String, rank: Int?, topK: Int, detail: String, color: Color) -> some View {
        let engineName = engine == "grep" ? "grep" : "Embarsy's semantic search"
        let help: String = {
            if let rank {
                let place = rank == 1 ? "the very first result" : "result #\(rank)"
                return "#\(rank): the right file came out as \(place) in \(engineName)'s ranking of this question — lower is better, #1 is best. A hit counts when it lands anywhere in the top \(topK)."
            }
            return "miss: the right file never reached \(engineName)'s top \(topK) for this question."
        }()
        return HStack(spacing: 5) {
            Image(systemName: rank != nil ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(rank != nil ? color : Color(nsColor: .systemRed).opacity(0.8))
            Text(rank.map { "#\($0)" } ?? "miss")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(rank != nil ? color : .secondary)
            Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .chipHelp(help)
    }

    // MARK: Editor duels

    @ViewBuilder
    private func editorSection(_ result: RetrievalBenchmark) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Theme.separator)
            Text("LIVE DUEL — YOUR EDITOR")
                .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            DisclosureGroup(isExpanded: $duelHelpOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A *duel* asks your coding agent the same question twice: once restricted to grep/text tools, once leading with Embarsy's `search_code`. Embarsy compares which run finds the right file, how long it takes, and how many tokens it burns — the cost you actually pay.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Where your agent ships a command-line tool Embarsy can drive, the button **runs 3 duels for you**. Where it doesn't, the button **copies a ready script** — paste it into that agent's chat, run both prompts, and compare. Hover a button for details.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12.5)).lineSpacing(2.5).foregroundStyle(.secondary)
                .padding(.top, 6)
            } label: {
                Text("How the live duel works")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }

            ForEach(BenchmarkEditor.allCases) { editor in
                editorRow(editor, result: result)
            }

            switch service.agentPhase {
            case .running(let stage):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(stage).font(.callout).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.orange)
            case .done:
                agentResults
            case .idle:
                EmptyView()
            }
        }
        .task { await service.detectEditors() }
    }

    private func editorRow(_ editor: BenchmarkEditor, result: RetrievalBenchmark) -> some View {
        let questions = Array(result.queries.prefix(3))
        let cliPath = service.detectedCLIs[editor]
        return HStack(spacing: 10) {
            // Filled dot = Embarsy can run it automatically; hollow = manual (copy prompts).
            Circle()
                .strokeBorder(Theme.accent.opacity(0.8), lineWidth: cliPath != nil ? 0 : 1.5)
                .background(Circle().fill(cliPath != nil ? Theme.accent.opacity(0.85) : .clear))
                .frame(width: 8, height: 8)
                .contentShape(Rectangle())
                .chipHelp(cliPath != nil
                      ? "Filled dot: Embarsy found this agent's command-line tool and can run the duels for you automatically."
                      : "Hollow dot: no automatable command-line tool here — run the duel by hand with the copied prompts. (Filled dot = Embarsy runs it for you.)")
            Text(editor.title).font(.system(size: 12.5, weight: .semibold))
            Text(editorStatus(editor))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .chipHelp(editorStatusHelp(editor))
            Spacer()
            if let cliPath {
                Button("Run 3 duels") {
                    Task {
                        await service.runAgentDuels(editor: editor, questions: questions,
                                                    workspacePath: workspacePath)
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled({ if case .running = service.agentPhase { return true } else { return false } }())
                .chipHelp("Runs \(editor.title) automatically on the first 3 questions, each answered twice: once allowed only grep/find/read tools, once leading with Embarsy's search_code (via the embarsy-qdrant MCP). Embarsy times both runs and reports which found the right file, the seconds, and the tokens. Nothing is sent to the cloud beyond your agent's own model calls.\n\nUsing the CLI at: \(cliPath)")
            } else {
                // No runnable CLI here — the duel still works, run by hand from the chat.
                Button("Copy duel prompts") {
                    service.copyPrompts(editorTitle: editor.title, questions: questions)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .chipHelp(copyPromptsHelp(editor))
            }
        }
    }

    /// Short reason shown next to the editor name (full text on hover).
    private func editorStatus(_ editor: BenchmarkEditor) -> String {
        if service.detectedCLIs[editor] != nil { return "CLI found — Embarsy runs the duels for you" }
        switch editor {
        case .zoo:    return "runs only inside the editor — copy prompts to its chat"
        case .claude: return "no automatable CLI here — copy prompts to its chat"
        case .codex:  return "CLI not found on PATH — copy prompts to its chat"
        }
    }

    private func editorStatusHelp(_ editor: BenchmarkEditor) -> String {
        if let path = service.detectedCLIs[editor] {
            return "\(editor.title)'s command-line tool was found at \(path). Embarsy can run the duels headless — press Run 3 duels."
        }
        switch editor {
        case .zoo:
            return "Zoo / Roo Code runs only inside your editor's chat — it ships no command line, so Embarsy can't automate it. Use Copy duel prompts and run them in the Zoo/Roo chat by hand."
        case .claude:
            return "No Claude command-line tool was found on your PATH that Embarsy can drive headless (the one bundled in the Claude desktop app needs its own interactive login). Use Copy duel prompts and run them in the Claude chat. To enable the automatic Run button, install the Claude Code CLI so `claude` is on your PATH."
        case .codex:
            return "No Codex command-line tool was found. Use Copy duel prompts and run them in the Codex chat. If you have the Codex app or CLI installed, make sure `codex` is reachable so Embarsy can automate the duel."
        }
    }

    private func copyPromptsHelp(_ editor: BenchmarkEditor) -> String {
        "\(editor.title) can't be driven automatically on this Mac, so run the duel by hand. This copies a ready script: for each of the first 3 questions, a *grep-only* prompt and a *semantic* prompt. Paste them into \(editor.title)'s chat one at a time, run both, and compare how long each takes and which file it lands on. Same test, no CLI required."
    }

    @ViewBuilder
    private var agentResults: some View {
        if let editor = service.agentEditor, !service.agentDuels.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                let grepTotal = service.agentDuels.reduce(0.0) { $0 + $1.grepRun.seconds }
                let semTotal = service.agentDuels.reduce(0.0) { $0 + $1.semanticRun.seconds }
                let grepCorrect = service.agentDuels.filter(\.grepRun.correct).count
                let semCorrect = service.agentDuels.filter(\.semanticRun.correct).count
                Text("**\(editor.title)**: grep-only — \(grepCorrect)/\(service.agentDuels.count) correct in \(String(format: "%.0f", grepTotal))s · with Embarsy — \(semCorrect)/\(service.agentDuels.count) correct in \(String(format: "%.0f", semTotal))s")
                    .font(.system(size: 12))
                ForEach(service.agentDuels) { duel in
                    agentDuelRow(duel)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func agentDuelRow(_ duel: AgentDuel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("“\(duel.question)”")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1).truncationMode(.tail)
            HStack(spacing: 14) {
                agentRunLabel("grep", run: duel.grepRun, color: grepColor)
                agentRunLabel("embarsy", run: duel.semanticRun, color: semanticColor)
                Spacer()
            }
        }
        .padding(.vertical, 3)
    }

    private func agentRunLabel(_ name: String, run: AgentRun, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: run.correct ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(run.correct ? color : Color(nsColor: .systemRed).opacity(0.8))
                .contentShape(Rectangle())
                .chipHelp(run.correct
                      ? "Correct: this run found the right file. (Filled check = correct; hollow red cross = wrong.)"
                      : "Wrong: this run did not land on the right file. (Filled check = correct; hollow red cross = wrong.)")
            Text(name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            Text(String(format: "%.0fs", run.seconds))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            if let tokens = run.totalTokens {
                Text("\(tokens) tok")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
            if let note = run.failureNote {
                Text(note).font(.system(size: 10)).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }

    // MARK: Formatting

    private func shortCollectionTitle(_ name: String) -> String {
        name.count > 24 ? String(name.prefix(21)) + "…" : name
    }

    private func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func formatSeconds(_ milliseconds: Double) -> String {
        milliseconds >= 1000
            ? String(format: "%.2f s", milliseconds / 1000)
            : String(format: "%.0f ms", milliseconds)
    }

    private func fractionSmallerIsBetter(mine: Double, other: Double) -> Double {
        guard mine > 0 else { return 1 }
        return max(0.02, min(1, min(mine, other) / mine))
    }
}
