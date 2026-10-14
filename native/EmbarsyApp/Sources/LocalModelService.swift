import Foundation

/// The optional local language model (docs/memory-spec.md §10, tier 3), run by the Ollama that
/// already ships inside Embarsy for embeddings.
///
/// It costs nothing until it is asked for: a downloaded model is only disk space; Ollama loads
/// it into memory on the first request and Embarsy asks it to unload after `idleTimeout`
/// seconds without one. "Unload now" frees the memory at once.
@MainActor
final class LocalModelService: ObservableObject {
    struct Choice: Identifiable, Hashable {
        let tag: String
        let label: String
        let downloadGB: Double
        /// Smallest Mac memory it is offered for: the model, the embedding model, Qdrant and
        /// macOS with the user's apps all have to fit.
        let minMemoryGB: Int
        let note: String
        var id: String { tag }
    }

    static let catalog: [Choice] = [
        Choice(tag: "qwen3.6:35b-a3b", label: "Qwen 3.6 35B-A3B", downloadGB: 24, minMemoryGB: 48,
               note: L("Mixture of experts: about 3B parameters work per token, so it answers fast — what a migration's hundreds of small questions need.")),
        Choice(tag: "qwen3.5:9b", label: "Qwen 3.5 9B", downloadGB: 6.6, minMemoryGB: 24,
               note: L("A solid middle ground for Macs with less memory.")),
        Choice(tag: "qwen3.5:4b", label: "Qwen 3.5 4B", downloadGB: 3.3, minMemoryGB: 16,
               note: L("Enough to sort files; for condensing the core, your own agent does better.")),
    ]

    struct Loaded: Equatable {
        let name: String
        let bytes: Int64
        let expiresAt: Date?
    }

    struct Download: Equatable {
        let tag: String
        var status: String
        var completed: Int64
        var total: Int64
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var loaded: [Loaded] = []
    /// The embedding model, when it's in memory. It isn't optional, but it obeys an idle time too.
    @Published private(set) var embeddingLoaded: Loaded?
    @Published private(set) var download: Download?
    @Published private(set) var lastError: String?
    @Published var selected: String {
        didSet { defaults.set(selected, forKey: Keys.model) }
    }
    /// Seconds without a request before the model leaves memory.
    @Published var idleTimeout: Int {
        didSet { defaults.set(idleTimeout, forKey: Keys.idle) }
    }

    let baseURL: URL
    let embeddingModel: String
    let memoryGB: Int
    private let defaults: UserDefaults
    private var downloadTask: Task<Void, Never>?

    private enum Keys {
        static let model = "localModelTag"
        static let idle = "localModelIdleSeconds"
    }

    init(baseURL: URL, embeddingModel: String, defaults: UserDefaults = .standard) {
        self.baseURL = baseURL
        self.embeddingModel = embeddingModel
        self.defaults = defaults
        memoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        idleTimeout = defaults.object(forKey: Keys.idle) as? Int ?? 120
        selected = defaults.string(forKey: Keys.model) ?? Self.recommended(forMemoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))?.tag ?? ""
    }

    /// The first model in the catalog this Mac has the memory for.
    static func recommended(forMemoryGB memory: Int) -> Choice? {
        catalog.first { memory >= $0.minMemoryGB }
    }

    var offered: [Choice] { Self.catalog.filter { memoryGB >= $0.minMemoryGB } }
    var isReady: Bool { installed.contains(selected) }
    var loadedSelected: Loaded? { loaded.first { $0.name == selected } }

    // MARK: State

    /// What's on disk and what's in memory, from Ollama itself.
    func refresh() async {
        if let tags = await get("api/tags")?["models"] as? [[String: Any]] {
            installed = Set(tags.compactMap { $0["name"] as? String })
        }
        if let ps = await get("api/ps")?["models"] as? [[String: Any]] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let all: [Loaded] = ps.compactMap { model in
                guard let name = model["name"] as? String else { return nil }
                let expires = (model["expires_at"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                return Loaded(name: name, bytes: (model["size"] as? NSNumber)?.int64Value ?? 0, expiresAt: expires)
            }
            loaded = all.filter { item in Self.catalog.contains { $0.tag == item.name } }
            embeddingLoaded = all.first { $0.name == embeddingModel || $0.name == embeddingModel + ":latest" }
        }
    }

    // MARK: Download / delete / unload

    func startDownload(_ tag: String) {
        guard download == nil else { return }
        lastError = nil
        download = Download(tag: tag, status: L("Starting…"), completed: 0, total: 0)
        downloadTask = Task { [weak self] in await self?.pull(tag) }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        download = nil
    }

    private func pull(_ tag: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": tag, "stream": true])
        request.timeoutInterval = 3600
        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let error = json["error"] as? String { throw NSError(domain: "Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
                var state = download ?? Download(tag: tag, status: "", completed: 0, total: 0)
                state.status = json["status"] as? String ?? state.status
                if let total = (json["total"] as? NSNumber)?.int64Value, total > 0 {
                    state.total = total
                    state.completed = (json["completed"] as? NSNumber)?.int64Value ?? state.completed
                }
                download = state
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { lastError = L("Download stopped: \(error.localizedDescription). Press Download to continue — Ollama resumes where it left off.") }
        }
        download = nil
        await refresh()
    }

    func delete(_ tag: String) async {
        await unload(tag)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/delete"))
        request.httpMethod = "DELETE"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": tag])
        _ = try? await URLSession.shared.data(for: request)
        await refresh()
    }

    /// Frees the model's memory now. The next request loads it again.
    func unload(_ tag: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": tag, "keep_alive": 0])
        request.timeoutInterval = 30
        _ = try? await URLSession.shared.data(for: request)
        await refresh()
    }

    // MARK: Asking

    enum ModelError: LocalizedError {
        case notInstalled(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled(let tag): return L("The local model \(tag) isn't downloaded. Download it in Memory → Assistant.")
            case .failed(let why): return why
            }
        }
    }

    /// One question, one answer. With `schema`, the answer is JSON matching it. The model stays
    /// in memory `idleTimeout` seconds after.
    ///
    /// Ollama before 0.40 enforced `format` for Qwen 3.5/3.6 only while thinking (0.40.3 fixed it).
    /// The schema also goes into the system prompt and the answer is checked for every required
    /// field anyway — a wrong answer costs a retry, a right one costs nothing.
    func ask(system: String, user: String, schema: [String: Any]? = nil, think: Bool = false, numCtx: Int = 16384) async throws -> String {
        guard installed.contains(selected) else { throw ModelError.notInstalled(selected) }
        var prompt = system
        if let schema, let text = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
            prompt += "\n\nReply with one JSON object only, no prose and no code fence, matching this JSON schema:\n" + String(decoding: text, as: UTF8.self)
        }
        var last = ""
        // Without thinking, two tries; then one with thinking, where Ollama does enforce the
        // schema — slower, but it only runs for the rare broken answer.
        let attempts: [Bool] = schema == nil ? [think] : (think ? [true, true] : [false, false, true])
        for attemptThink in attempts {
            last = try await chat(system: prompt, user: user, schema: schema, think: attemptThink, numCtx: numCtx)
            guard schema != nil else { return last }
            if let json = Self.jsonObject(in: last, required: schema?["required"] as? [String] ?? []) { return json }
        }
        throw ModelError.failed(L("The local model didn't answer in the expected format: \(String(last.prefix(200)))"))
    }

    /// The JSON object in a reply, tolerating a ```json fence around it, with every required
    /// field present — a model that drops one has answered something else.
    static func jsonObject(in reply: String, required: [String] = []) -> String? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.drop(while: { $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("```") { text = String(text.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              required.allSatisfy({ object[$0] != nil }) else { return nil }
        return text
    }

    private func chat(system: String, user: String, schema: [String: Any]?, think: Bool, numCtx: Int) async throws -> String {
        var body: [String: Any] = [
            "model": selected,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": false,
            "keep_alive": "\(idleTimeout)s",
            "think": think,
            // Most tasks are one file or one pair of notes; a window sized to the task keeps
            // Ollama from reserving cache for nothing.
            "options": ["temperature": 0.2, "num_ctx": numCtx],
        ]
        if let schema { body["format"] = schema }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 600
        let (data, response) = try await URLSession.shared.data(for: request)
        defer { Task { await self.refresh() } }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelError.failed(L("The local model returned something unreadable."))
        }
        if let error = json["error"] as? String { throw ModelError.failed(L("The local model failed: \(error)")) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let content = (json["message"] as? [String: Any])?["content"] as? String else {
            throw ModelError.failed(L("The local model returned no answer."))
        }
        return content
    }

    private func get(_ path: String) async -> [String: Any]? {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
