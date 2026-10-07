import Foundation

struct ContentIndexSnapshot: Decodable {
    let now: Int
    let collections: [ContentIndexCollection]

    static let empty = ContentIndexSnapshot(now: 0, collections: [])
}

struct PreviewTag: Decodable, Hashable {
    let kind: String        // count | lang | area | term | sample
    let label: String
    let copy: String?

    /// Text placed on the clipboard when the chip is clicked (full sample for sample chips).
    var copyPayload: String { copy ?? label }
    var stableID: String { "\(kind)|\(label)" }
}

struct ContentIndexCollection: Decodable, Identifiable {
    let collectionName: String
    let displayName: String
    let pointsCount: Int
    let indexedSummary: String
    let preview: String
    let previewTags: [PreviewTag]?   // optional: nil when decoded from an older API payload
    let workspacePath: String?       // absent when no folder is known for this collection
    /// "indexer" when Embarsy's own bridge wrote the folder (safe to re-index from the app),
    /// "editor" when it was recovered from an editor's cache (that editor owns the index).
    let workspaceSource: String?
    /// Epoch seconds of the last finished bridge run; 0 or absent when unknown.
    let indexedAt: Int?

    var id: String { collectionName }

    enum CodingKeys: String, CodingKey {
        case collectionName = "collection_name"
        case displayName = "display_name"
        case pointsCount = "points_count"
        case indexedSummary = "indexed_summary"
        case preview
        case previewTags = "preview_tags"
        case workspacePath = "workspace_path"
        case workspaceSource = "workspace_source"
        case indexedAt = "indexed_at"
    }

    /// The folder to reveal in Finder, or nil when the name is not backed by one — a name
    /// inferred from relative paths has no folder, and the API sends "" for those.
    /// A folder Embarsy's bridge indexed — the ones the Connections screen lists and may refresh.
    var isBridgeIndexed: Bool { workspaceSource == "indexer" && revealableFolder != nil }

    var lastIndexedDate: Date? {
        guard let indexedAt, indexedAt > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(indexedAt))
    }

    var revealableFolder: URL? {
        guard let path = workspacePath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The summary with its leading "<name> — " stripped, so the name can be drawn as a
    /// link and the rest as prose without the name appearing twice. Returns nil when the
    /// summary does not open with the name (a nameless collection).
    var summaryWithoutName: String? {
        let prefix = "\(displayName) — "
        guard indexedSummary.hasPrefix(prefix) else { return nil }
        return String(indexedSummary.dropFirst(prefix.count))
    }
}

@MainActor
final class ContentIndexService: ObservableObject {
    @Published var snapshot: ContentIndexSnapshot = .empty
    @Published var message = "Content overview is waiting for Embarsy API."
    @Published var isRefreshing = false
    /// False until one refresh has succeeded — an empty snapshot before that means "not
    /// known yet", not "nothing indexed", and screens must not present it as the latter.
    @Published private(set) var hasLoaded = false

    private let decoder = JSONDecoder()

    /// `maxAge` caps how stale the API's server-side content cache may be for this call:
    /// pass `0` to force a recompute (right after deleting a collection, so the row
    /// disappears immediately), or the poll interval so cached data is never older than
    /// one refresh period. `nil` accepts the server default.
    func refresh(config: EmbarsyConfig, maxAge: Double? = nil) async {
        guard !isRefreshing else { return }

        guard config.embarsyAPIKey.isEmpty == false else {
            message = "Content overview needs local API secrets. Start or install Embarsy first."
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var components = URLComponents(
                url: config.apiBaseURL.appendingPathComponent("content/collections"),
                resolvingAgainstBaseURL: false
            )
            if let maxAge {
                components?.queryItems = [URLQueryItem(name: "max_age", value: String(maxAge))]
            }
            guard let url = components?.url else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Bearer \(config.embarsyAPIKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                message = "Content endpoint is unavailable. Start Embarsy API and refresh."
                return
            }

            snapshot = try decoder.decode(ContentIndexSnapshot.self, from: data)
            hasLoaded = true
            message = snapshot.collections.isEmpty
                ? "No Qdrant collections found yet. Start Watcher indexing first."
                : "Content overview updated."
        } catch {
            message = "Content refresh failed: \(error.localizedDescription)"
        }
    }
}
