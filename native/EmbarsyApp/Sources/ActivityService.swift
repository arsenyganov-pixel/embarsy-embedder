import Foundation

struct ActivitySnapshot: Decodable {
    let now: Int
    let events: [ActivityEvent]

    static let empty = ActivitySnapshot(now: 0, events: [])
}

struct ActivityEvent: Decodable, Identifiable {
    let id: Int
    let timestamp: Int
    let kind: ActivityKind
    let operation: ActivityOperation
    let title: String
    let detail: String
    let count: Int
    let error: Bool

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

enum ActivityKind: String, Decodable {
    case embedding
    case qdrant
}

enum ActivityOperation: String, Decodable {
    case embedding
    case read
    case write

    var isRead: Bool { self == .read }
    var isWriteOrIndexing: Bool { self == .write || self == .embedding }
}

@MainActor
final class ActivityService: ObservableObject {
    @Published var snapshot: ActivitySnapshot = .empty
    @Published var message = "Activity is waiting for Embarsy API."
    @Published var isRefreshing = false

    private let decoder = JSONDecoder()

    func refresh(config: EmbarsyConfig) async {
        guard !isRefreshing else { return }

        guard config.embarsyAPIKey.isEmpty == false else {
            message = "Activity needs local API secrets. Start or install Embarsy first."
            snapshot = .empty
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var components = URLComponents(
                url: config.apiBaseURL.appendingPathComponent("activity/requests"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "limit", value: "5000"),
                URLQueryItem(name: "since_seconds", value: "86400"),
            ]
            guard let url = components?.url else { return }

            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            request.setValue("Bearer \(config.embarsyAPIKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                message = "Activity endpoint is unavailable. Start Embarsy API and refresh."
                return
            }
            snapshot = try decoder.decode(ActivitySnapshot.self, from: data)
            message = snapshot.events.isEmpty ? "No request activity in the last 24 hours." : "Activity updated. Showing the last 24 hours."
        } catch {
            message = "Activity refresh failed: \(error.localizedDescription)"
        }
    }
}
