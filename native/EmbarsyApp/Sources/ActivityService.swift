import Foundation

struct ActivitySnapshot: Decodable, Sendable {
    let now: Int
    let events: [ActivityEvent]
    /// Highest event id the server has ever assigned (not just in this response) — lets the
    /// client detect an id reset (API restart with wiped state) and re-fetch the full window.
    let latestID: Int?
    /// Server process incarnation. Changes whenever the API restarts, so a held since_id
    /// from a previous incarnation is dropped even when the new ids happen to be larger.
    let bootID: String?

    enum CodingKeys: String, CodingKey {
        case now
        case events
        case latestID = "latest_id"
        case bootID = "boot_id"
    }

    static let empty = ActivitySnapshot(now: 0, events: [], latestID: nil, bootID: nil)
}

struct ActivityEvent: Decodable, Equatable, Identifiable, Sendable {
    let id: Int
    let timestamp: Int
    let kind: ActivityKind
    let operation: ActivityOperation
    let title: String
    let detail: String
    let count: Int
    let error: Bool
    /// Absent when decoding from an API older than this field, empty when the caller did
    /// not declare itself — both render the same way, as an unknown client.
    let client: String?

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    /// `<editor> · <tool>` as declared, prettified for display. Editors are named the way
    /// their own product does; anything unrecognised is shown verbatim rather than guessed.
    var clientLabel: String {
        guard let client, !client.isEmpty else { return "Unknown client" }
        let parts = client.split(separator: "·", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let editor = parts.first.map(Self.prettyEditor) ?? client
        guard parts.count > 1, !parts[1].isEmpty else { return editor }
        return "\(editor) · \(parts[1] == "index" ? "indexing" : parts[1])"
    }

    private static func prettyEditor(_ raw: String) -> String {
        switch raw {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        case "embarsy-qdrant-mcp": return "Bridge"
        case "embarsy-app": return "Embarsy"
        default: return raw
        }
    }
}

enum ActivityKind: String, Decodable, Sendable {
    case embedding
    case qdrant
}

enum ActivityOperation: String, Decodable, Sendable {
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

    private static let windowSeconds = 86_400
    private static let maxEvents = 5_000

    /// Highest event id already merged into `snapshot` — subsequent polls request only
    /// newer events. The full 24h window (a multi-MB JSON on a busy day) is fetched once
    /// per tab open instead of every 2 seconds.
    private var lastEventID = 0
    /// Server incarnation the current `lastEventID` belongs to.
    private var serverBootID: String?

    func refresh(config: EmbarsyConfig) async {
        guard !isRefreshing else { return }

        guard config.embarsyAPIKey.isEmpty == false else {
            message = "Activity needs local API secrets. Start or install Embarsy first."
            snapshot = .empty
            lastEventID = 0
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        await fetch(config: config, sinceID: lastEventID)
    }

    private func fetch(config: EmbarsyConfig, sinceID: Int) async {
        do {
            var components = URLComponents(
                url: config.apiBaseURL.appendingPathComponent("activity/requests"),
                resolvingAgainstBaseURL: false
            )
            var query = [
                URLQueryItem(name: "limit", value: String(Self.maxEvents)),
                URLQueryItem(name: "since_seconds", value: String(Self.windowSeconds)),
            ]
            if sinceID > 0 {
                query.append(URLQueryItem(name: "since_id", value: String(sinceID)))
            }
            components?.queryItems = query
            guard let url = components?.url else { return }

            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            request.setValue("Bearer \(config.embarsyAPIKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                message = "Activity endpoint is unavailable. Start Embarsy API and refresh."
                return
            }
            // Multi-MB on a busy first fetch — decode off the main actor.
            let decoded = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(ActivitySnapshot.self, from: data)
            }.value

            // Drop a stale since_id and re-fetch the full window when:
            // (a) the API restarted (boot_id changed) — ids may have been re-minted, even
            //     to values LARGER than our since_id when persisted state was reloaded;
            // (b) ids visibly went backwards (wiped state, old server without boot_id).
            if sinceID > 0 {
                let rebooted = decoded.bootID != nil && decoded.bootID != serverBootID
                let idsReset = (decoded.latestID ?? Int.max) < sinceID
                if rebooted || idsReset {
                    lastEventID = 0
                    serverBootID = decoded.bootID
                    await fetch(config: config, sinceID: 0)
                    return
                }
            }
            serverBootID = decoded.bootID

            snapshot = merged(decoded, sinceID: sinceID)
            lastEventID = snapshot.events.first?.id ?? lastEventID
            message = snapshot.events.isEmpty ? "No request activity in the last 24 hours." : "Activity updated. Showing the last 24 hours."
        } catch {
            message = "Activity refresh failed: \(error.localizedDescription)"
        }
    }

    /// New events (newest-first from the server) prepended to what we already have,
    /// re-trimmed to the 24h window and the event cap — same contents the old
    /// full-window fetch produced.
    private func merged(_ incoming: ActivitySnapshot, sinceID: Int) -> ActivitySnapshot {
        guard sinceID > 0 else { return incoming }
        // An old server that predates since_id support returns the FULL window (and no
        // latest_id) — merging that with our snapshot would duplicate every event.
        guard incoming.latestID != nil else { return incoming }
        let cutoff = incoming.now - Self.windowSeconds
        // Defense in depth: never merge events we already hold, whatever the server sent.
        let fresh = incoming.events.filter { $0.id > sinceID }
        var events = fresh + snapshot.events.filter { $0.id <= sinceID }
        events = events.filter { $0.timestamp >= cutoff }
        if events.count > Self.maxEvents {
            events = Array(events.prefix(Self.maxEvents))
        }
        return ActivitySnapshot(now: incoming.now, events: events, latestID: incoming.latestID, bootID: incoming.bootID)
    }
}
