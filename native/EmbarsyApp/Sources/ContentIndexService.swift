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

    var id: String { collectionName }

    enum CodingKeys: String, CodingKey {
        case collectionName = "collection_name"
        case displayName = "display_name"
        case pointsCount = "points_count"
        case indexedSummary = "indexed_summary"
        case preview
        case previewTags = "preview_tags"
    }
}

@MainActor
final class ContentIndexService: ObservableObject {
    @Published var snapshot: ContentIndexSnapshot = .empty
    @Published var message = "Content overview is waiting for Embarsy API."
    @Published var isRefreshing = false

    private let decoder = JSONDecoder()

    func refresh(config: EmbarsyConfig) async {
        guard !isRefreshing else { return }

        guard config.embarsyAPIKey.isEmpty == false else {
            message = "Content overview needs local API secrets. Start or install Embarsy first."
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let url = config.apiBaseURL.appendingPathComponent("content/collections")
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Bearer \(config.embarsyAPIKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                message = "Content endpoint is unavailable. Start Embarsy API and refresh."
                return
            }

            snapshot = try decoder.decode(ContentIndexSnapshot.self, from: data)
            message = snapshot.collections.isEmpty
                ? "No Qdrant collections found yet. Start Watcher indexing first."
                : "Content overview updated."
        } catch {
            message = "Content refresh failed: \(error.localizedDescription)"
        }
    }
}
