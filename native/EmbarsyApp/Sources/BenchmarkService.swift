import AppKit
import Foundation

// MARK: - /benchmark/retrieval response models

struct BenchmarkGrepMatch: Decodable, Equatable {
    let path: String
    let lines: Int
}

struct BenchmarkEngineRun: Decodable, Equatable {
    let latencyMS: Double
    let rank: Int?
    let topFiles: [String]
    let matchedLines: Int?
    let filesWithMatches: Int?
    let timedOut: Bool?
    // Log-transparency fields (optional: a still-running 0.2.0 API omits them).
    let command: String?          // grep: the exact command that ran
    let embedMS: Double?          // semantic: query-embedding time
    let searchMS: Double?         // semantic: vector-search time
    let snippetChars: Int?        // semantic: context returned in the top-K snippets
    let topMatches: [BenchmarkGrepMatch]?  // grep: top files with matching-line counts
    let truncatedOutput: Bool?    // grep: stdout overflowed the 8 MB cap — counts are lower bounds
    let strategy: String?         // grep: "and" (intersection pipeline) or "or" (fallback)

    enum CodingKeys: String, CodingKey {
        case latencyMS = "latency_ms"
        case rank
        case topFiles = "top_files"
        case matchedLines = "matched_lines"
        case filesWithMatches = "files_with_matches"
        case timedOut = "timed_out"
        case command
        case embedMS = "embed_ms"
        case searchMS = "search_ms"
        case snippetChars = "snippet_chars"
        case topMatches = "top_matches"
        case truncatedOutput = "truncated_output"
        case strategy
    }
}

struct BenchmarkSynonymSwap: Decodable, Equatable {
    let from: String
    let to: String
}

struct BenchmarkQueryRow: Decodable, Equatable, Identifiable {
    let query: String
    let truthFile: String
    let semantic: BenchmarkEngineRun
    let grep: BenchmarkEngineRun
    // Paraphrase mode: the question before synonym swaps + the swaps themselves.
    let originalQuery: String?
    let swapped: [BenchmarkSynonymSwap]?

    var id: String { query + truthFile }
    /// The story row: grep genuinely matched lines (no timeout, no empty result) yet its
    /// ranking drowned, while semantic search landed the file. Timeouts and zero-match
    /// rows are real grep failures too, but they don't earn the "every word existed"
    /// narrative — they're reported separately.
    var meaningWins: Bool {
        semantic.rank != nil && grep.rank == nil
            && grep.timedOut != true && (grep.filesWithMatches ?? 0) > 0
    }

    enum CodingKeys: String, CodingKey {
        case query
        case truthFile = "truth_file"
        case semantic
        case grep
        case originalQuery = "original_query"
        case swapped
    }
}

struct BenchmarkSide: Decodable, Equatable {
    let hitTop1: Int
    let hitTopK: Int
    let medianLatencyMS: Double
    let medianMatchedLines: Double?
    let zeroResultQueries: Int?
    let timeouts: Int?

    enum CodingKeys: String, CodingKey {
        case hitTop1 = "hit_top1"
        case hitTopK = "hit_topk"
        case medianLatencyMS = "median_latency_ms"
        case medianMatchedLines = "median_matched_lines"
        case zeroResultQueries = "zero_result_queries"
        case timeouts
    }
}

struct BenchmarkSummary: Decodable, Equatable {
    let semantic: BenchmarkSide
    let grep: BenchmarkSide
}

struct RetrievalBenchmark: Decodable, Equatable {
    let collection: String
    let workspacePath: String
    let samples: Int
    let topK: Int
    let queries: [BenchmarkQueryRow]
    let summary: BenchmarkSummary
    let skippedErrors: Int?
    let workspaceVerified: Bool?  // false = the find gate timed out and was skipped
    /// The folder grep actually raced over — the detected root of the indexed tree.
    /// May be a child of workspacePath (indexers often root at a subproject); both
    /// engines then compete over the SAME corpus.
    let grepRoot: String?
    let paraphrased: Bool?  // synonym mode: half the query words swapped for synonyms

    var meaningWins: Int { queries.filter(\.meaningWins).count }

    enum CodingKeys: String, CodingKey {
        case collection
        case workspacePath = "workspace_path"
        case samples
        case topK = "top_k"
        case queries
        case summary
        case skippedErrors = "skipped_errors"
        case workspaceVerified = "workspace_verified"
        case grepRoot = "grep_root"
        case paraphrased
    }
}

// MARK: - Editor (agent) duels

enum BenchmarkEditor: String, CaseIterable, Identifiable {
    case claude, codex, zoo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .zoo: "Zoo / Roo Code"
        }
    }
    /// Binary looked up on the user's login-shell PATH (nil = copy-prompt only).
    var binaryName: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .zoo: nil
        }
    }
}

struct AgentRun: Equatable {
    let answer: String        // path the agent replied with ("" when unparseable)
    let correct: Bool
    let seconds: Double
    let totalTokens: Int?     // Claude reports usage; Codex doesn't
    let failureNote: String?  // populated when the CLI errored / timed out
}

struct AgentDuel: Equatable, Identifiable {
    let question: String
    let truthFile: String
    let grepRun: AgentRun
    let semanticRun: AgentRun
    var id: String { question + truthFile }
}

// MARK: - Service

@MainActor
final class BenchmarkService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(String)
        case failed(String)
        case done
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: RetrievalBenchmark?
    @Published private(set) var lastRunDate: Date?
    /// The user's collection choice — lives here (not in the view) so it survives
    /// tab switches, exactly like a running benchmark does.
    @Published var selectedCollection: String?

    @Published private(set) var detectedCLIs: [BenchmarkEditor: String] = [:]
    @Published private(set) var agentPhase: Phase = .idle
    @Published private(set) var agentEditor: BenchmarkEditor?
    @Published private(set) var agentDuels: [AgentDuel] = []

    private let runner = ProcessRunner()
    /// Last successful result is persisted here so Status always shows it — across
    /// tab switches AND app relaunches. nil (tests/previews) disables persistence.
    private let stateFile: URL?
    static let searchToolID = "mcp__embarsy-qdrant__search_code"

    init(stateFile: URL? = nil) {
        self.stateFile = stateFile
        loadPersistedResult()
    }

    private func loadPersistedResult() {
        guard let stateFile,
              let data = try? Data(contentsOf: stateFile),
              let decoded = try? JSONDecoder().decode(RetrievalBenchmark.self, from: data)
        else { return }
        result = decoded
        selectedCollection = decoded.collection
        phase = .done
        lastRunDate = (try? FileManager.default.attributesOfItem(atPath: stateFile.path)[.modificationDate]) as? Date
    }

    private func persistResult(_ data: Data) {
        guard let stateFile else { return }
        try? FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateFile)
    }

    // MARK: Retrieval benchmark (Tier 1 — built-in, no LLM)

    func runRetrieval(config: EmbarsyConfig, collection: String, workspacePath: String, samples: Int = 12, paraphrase: Bool = false) async {
        if case .running = phase { return }
        if case .running = agentPhase { return }  // duels reference the current question set
        phase = .running("Sampling \(collection) and running \(samples) duels — real grep vs the semantic index…")
        // Keep the previous result on screen while the new run is in flight — Status
        // always shows the last completed benchmark. Editor duels answered the OLD
        // questions, though: pairing them with a fresh sample would fabricate data.
        agentDuels = []
        agentEditor = nil
        agentPhase = .idle
        do {
            var request = URLRequest(url: config.apiBaseURL.appendingPathComponent("benchmark/retrieval"))
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("Bearer \(config.embarsyAPIKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "collection": collection,
                "workspace_path": workspacePath,
                "samples": samples,
                "paraphrase": paraphrase,
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                phase = .failed("No HTTP response from the Embarsy API.")
                return
            }
            guard http.statusCode == 200 else {
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                if http.statusCode == 404, detail == nil || detail == "Not Found" {
                    // A still-running pre-0.2.1 API has no benchmark route at all; its
                    // bare "Not Found" would leave the user with no way forward.
                    phase = .failed("The running Embarsy API predates the benchmark. Use the Update button in Services — only the API restarts, indexes are untouched.")
                } else {
                    phase = .failed(detail ?? "Benchmark endpoint returned HTTP \(http.statusCode). If Status offers an API Update, run it first.")
                }
                return
            }
            result = try JSONDecoder().decode(RetrievalBenchmark.self, from: data)
            persistResult(data)
            lastRunDate = Date()
            phase = .done
        } catch {
            phase = .failed("Benchmark failed: \(error.localizedDescription)")
        }
    }

    // MARK: Editor CLI detection

    func detectEditors() async {
        var found: [BenchmarkEditor: String] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for editor in BenchmarkEditor.allCases {
            guard let binary = editor.binaryName else { continue }
            // 1) Login shell, so the user's real PATH (nvm/homebrew/…) is honoured — GUI
            // apps don't inherit it, which is the exact trap the How To warns about.
            if let output = try? await runner.run(
                executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", "command -v \(binary)"],
                timeout: 15
            ), output.exitCode == 0 {
                let path = output.output
                    .split(whereSeparator: \.isNewline).last.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if path.hasPrefix("/") { found[editor] = path; continue }
            }
            // 2) Well-known install locations — the CLIs' own installers often register
            // only an interactive-shell alias, invisible to `zsh -lc`. The Codex
            // desktop app bundles a fully working CLI (shares ~/.codex auth), so
            // desktop-only users still get real duels.
            var candidates = [
                "\(home)/.claude/local/\(binary)",
                "\(home)/.local/bin/\(binary)",
                "/opt/homebrew/bin/\(binary)",
                "/usr/local/bin/\(binary)",
            ]
            if editor == .codex {
                candidates.append("/Applications/Codex.app/Contents/Resources/codex")
            }
            for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
                found[editor] = candidate
                break
            }
        }
        detectedCLIs = found
    }

    // MARK: Agent duels (Tier 2 — the user's own editor answers the same questions)

    /// grep-only condition: the agent may search text but not the semantic index.
    static func grepPrompt(question: String) -> String {
        """
        You are taking part in a code-search benchmark, in the "plain text search" condition. \
        In this repository, find the ONE file whose content best matches this description: \
        "\(question)". \
        Rules: search ONLY with filename/text matching (grep-style tools, find, reading files). \
        Do NOT use any semantic, embedding or code-index search tool (no MCP search tools). \
        Work quickly. Your FINAL line must be exactly the file's path relative to the repo root — nothing else on that line.
        """
    }

    /// semantic condition: the agent leads with the Embarsy MCP search tool.
    static func semanticPrompt(question: String) -> String {
        """
        You are taking part in a code-search benchmark, in the "semantic search" condition. \
        In this repository, find the ONE file whose content best matches this description: \
        "\(question)". \
        Rules: use the `search_code` tool (embarsy-qdrant MCP, the local semantic index) as your search method; \
        you may read files to confirm a candidate. Do not use grep or filename scanning. \
        Work quickly. Your FINAL line must be exactly the file's path relative to the repo root — nothing else on that line.
        """
    }

    /// Paste-ready duel script for an editor chat — the fallback for ANY editor whose
    /// CLI is not installed (Zoo/Roo has no CLI at all; Claude/Codex desktop-only setups
    /// land here too, so the benchmark works on every machine).
    static func promptBundle(editorTitle: String, questions: [BenchmarkQueryRow]) -> String {
        var text = "Embarsy benchmark — run each prompt in \(editorTitle) chat and compare time + answers.\n"
        for (index, row) in questions.enumerated() {
            text += """

            ── Question \(index + 1) (expected answer: \(row.truthFile)) ──
            [A · grep only]
            \(grepPrompt(question: row.query))

            [B · semantic]
            \(semanticPrompt(question: row.query))

            """
        }
        return text
    }

    func copyPrompts(editorTitle: String, questions: [BenchmarkQueryRow]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.promptBundle(editorTitle: editorTitle, questions: questions),
                                       forType: .string)
    }

    func runAgentDuels(editor: BenchmarkEditor, questions: [BenchmarkQueryRow], workspacePath: String) async {
        guard let binaryPath = detectedCLIs[editor] else { return }
        agentEditor = editor
        agentDuels = []
        agentPhase = .running("Starting \(editor.title)…")

        var duels: [AgentDuel] = []
        for (index, row) in questions.enumerated() {
            if Task.isCancelled { break }
            // Alternate which condition goes first: a fixed order would hand whichever
            // runs second a warm-cache advantage.
            let grepFirst = index % 2 == 0
            var grepRun = AgentRun(answer: "", correct: false, seconds: 0, totalTokens: nil, failureNote: nil)
            var semanticRun = grepRun
            for pass in 0..<2 {
                let isGrepPass = (pass == 0) == grepFirst
                agentPhase = .running("\(editor.title) · question \(index + 1)/\(questions.count) · \(isGrepPass ? "grep-only" : "semantic") run…")
                let run = await runAgent(
                    editor: editor, binaryPath: binaryPath,
                    prompt: isGrepPass ? Self.grepPrompt(question: row.query)
                                       : Self.semanticPrompt(question: row.query),
                    truth: row.truthFile, workspacePath: workspacePath, semantic: !isGrepPass
                )
                if isGrepPass { grepRun = run } else { semanticRun = run }
                if Task.isCancelled { break }
            }
            duels.append(AgentDuel(question: row.query, truthFile: row.truthFile,
                                   grepRun: grepRun, semanticRun: semanticRun))
            agentDuels = duels
        }
        agentPhase = Task.isCancelled ? .idle : .done
    }

    private func runAgent(
        editor: BenchmarkEditor,
        binaryPath: String,
        prompt: String,
        truth: String,
        workspacePath: String,
        semantic: Bool
    ) async -> AgentRun {
        let started = Date()
        let arguments: [String]
        switch editor {
        case .claude:
            // Headless: tools must be pre-allowed. The two conditions get different toolsets.
            let tools = semantic
                ? [Self.searchToolID, "Read", "LS"]
                : ["Grep", "Glob", "Read", "LS", "Bash(grep:*)", "Bash(find:*)", "Bash(ls:*)", "Bash(cat:*)"]
            arguments = ["-p", prompt, "--output-format", "json", "--max-turns", "12",
                         "--allowedTools"] + tools
        case .codex:
            arguments = ["exec", "--skip-git-repo-check", prompt]
        case .zoo:
            return AgentRun(answer: "", correct: false, seconds: 0, totalTokens: nil,
                            failureNote: "Zoo Code has no CLI — use the copied prompts.")
        }

        do {
            // GUI apps carry a minimal PATH; npm/nvm-installed CLIs are shell scripts
            // that need node & friends resolvable, so rebuild a sane PATH around the
            // detected binary.
            let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            let binaryDir = (binaryPath as NSString).deletingLastPathComponent
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = [binaryDir, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", currentPath]
                .joined(separator: ":")
            let run = try await runner.run(
                executable: URL(fileURLWithPath: binaryPath),
                arguments: arguments,
                environment: ["PATH": path],
                workingDirectory: URL(fileURLWithPath: workspacePath),
                timeout: 240
            )
            let seconds = Date().timeIntervalSince(started)
            let (answerText, tokens) = Self.parseAgentOutput(editor: editor, raw: run.output)
            let answerPath = Self.lastPathToken(in: answerText)
            let correct = Self.pathsMatch(answerPath, truth)
            let note = run.exitCode == 0 ? nil : "exit code \(run.exitCode)"
            return AgentRun(answer: answerPath, correct: correct, seconds: seconds,
                            totalTokens: tokens, failureNote: note)
        } catch {
            // A timeout error carries the CLI's whole captured output — cap the note
            // so the UI and the exported log stay readable.
            return AgentRun(answer: "", correct: false,
                            seconds: Date().timeIntervalSince(started),
                            totalTokens: nil,
                            failureNote: String(error.localizedDescription.prefix(200)))
        }
    }

    // MARK: Output parsing helpers (deliberately forgiving — CLI formats drift)

    static func parseAgentOutput(editor: BenchmarkEditor, raw: String) -> (answer: String, tokens: Int?) {
        switch editor {
        case .claude:
            // `--output-format json` → one JSON object with "result" and usage fields.
            // stderr is merged into our capture, so cut from the first "{" to the
            // last "}" before parsing.
            let jsonSlice: String
            if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end {
                jsonSlice = String(raw[start...end])
            } else {
                jsonSlice = raw
            }
            if let data = jsonSlice.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let answer = object["result"] as? String ?? raw
                var tokens: Int?
                if let usage = object["usage"] as? [String: Any] {
                    let input = (usage["input_tokens"] as? Int) ?? 0
                    let output = (usage["output_tokens"] as? Int) ?? 0
                    let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                    let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    let total = input + output + cacheRead + cacheWrite
                    tokens = total > 0 ? total : nil
                }
                return (answer, tokens)
            }
            return (raw, nil)
        case .codex, .zoo:
            return (raw, nil)
        }
    }

    static func lastPathToken(in text: String) -> String {
        let pattern = #"[A-Za-z0-9_@:+~-]+(?:/[A-Za-z0-9_.@+~-]+)*\.[A-Za-z0-9]{1,8}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard let last = matches.last, let swiftRange = Range(last.range, in: text) else { return "" }
        return String(text[swiftRange])
    }

    /// Mirrors the backend's paths_match exactly — the "← ground truth" markers in the
    /// exported log and duel scoring must agree with the server's rank verdicts.
    nonisolated static func pathsMatch(_ candidate: String, _ truth: String) -> Bool {
        let a = candidate.split(separator: "/").map(String.init)
        let b = truth.split(separator: "/").map(String.init)
        guard let lastA = a.last, let lastB = b.last, lastA == lastB else { return false }
        let tail = min(a.count, b.count, 3)
        // When either side carries directory context, a bare-filename match is not
        // enough (root-level index.js must not be credited for src/pages/index.js).
        if tail < 2 && max(a.count, b.count) >= 2 { return false }
        return Array(a.suffix(tail)) == Array(b.suffix(tail))
    }
}
