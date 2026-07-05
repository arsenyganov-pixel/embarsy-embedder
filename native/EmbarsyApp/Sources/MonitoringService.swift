import Foundation

enum MonitoringScale: Int, CaseIterable, Identifiable {
    case minutes15 = 900
    case hour1 = 3600
    case hours6 = 21600
    case hours24 = 86400
    case days7 = 604800

    var id: Int { rawValue }

    /// Common short duration units (m/h/d) so the label fits the pill-width range dropdown.
    var rangeLabel: String {
        switch self {
        case .minutes15: "Last 15m"
        case .hour1: "Last 1h"
        case .hours6: "Last 6h"
        case .hours24: "Last 24h"
        case .days7: "Last 7d"
        }
    }
}

struct MonitoringSnapshot: Decodable {
    let now: Int
    let bucketSeconds: Int
    let summary: MonitoringSummary
    let series: [MonitoringPoint]

    enum CodingKeys: String, CodingKey {
        case now
        case bucketSeconds = "bucket_seconds"
        case summary
        case series
    }

    static let empty = MonitoringSnapshot(
        now: 0,
        bucketSeconds: 5,
        summary: MonitoringSummary.empty,
        series: []
    )
}

struct MonitoringSummary: Decodable {
    let startedAt: Int
    let embeddingsRequests: Int
    let embeddingsVectors: Int
    let embeddingsErrors: Int
    let embeddingsLatencyMSAverage: Double
    let qdrantReads: Int
    let qdrantWrites: Int
    let qdrantErrors: Int

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case embeddingsRequests = "embeddings_requests"
        case embeddingsVectors = "embeddings_vectors"
        case embeddingsErrors = "embeddings_errors"
        case embeddingsLatencyMSAverage = "embeddings_latency_ms_avg"
        case qdrantReads = "qdrant_reads"
        case qdrantWrites = "qdrant_writes"
        case qdrantErrors = "qdrant_errors"
    }

    static let empty = MonitoringSummary(
        startedAt: 0,
        embeddingsRequests: 0,
        embeddingsVectors: 0,
        embeddingsErrors: 0,
        embeddingsLatencyMSAverage: 0,
        qdrantReads: 0,
        qdrantWrites: 0,
        qdrantErrors: 0
    )
}

struct MonitoringPoint: Decodable, Identifiable {
    let timestamp: Int
    let embeddingsRequests: Int
    let embeddingsVectors: Int
    let embeddingsErrors: Int
    let embeddingsLatencyMSAverage: Double
    let qdrantReads: Int
    let qdrantWrites: Int
    let qdrantErrors: Int

    var id: Int { timestamp }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case embeddingsRequests = "embeddings_requests"
        case embeddingsVectors = "embeddings_vectors"
        case embeddingsErrors = "embeddings_errors"
        case embeddingsLatencyMSAverage = "embeddings_latency_ms_avg"
        case qdrantReads = "qdrant_reads"
        case qdrantWrites = "qdrant_writes"
        case qdrantErrors = "qdrant_errors"
    }
}

@MainActor
final class MonitoringService: ObservableObject {
    @Published var scale: MonitoringScale = .hour1
    @Published var snapshot: MonitoringSnapshot = .empty
    @Published var message = "Monitoring is waiting for Embarsy API."
    @Published var isRefreshing = false

    private let decoder = JSONDecoder()

    func refresh(config: EmbarsyConfig) async {
        guard !isRefreshing else { return }

        guard config.embarsyAPIKey.isEmpty == false else {
            message = "Monitoring needs local API secrets. Start or install Embarsy first."
            snapshot = .empty
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var components = URLComponents(url: config.apiBaseURL.appendingPathComponent("metrics/embeddings"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "scale_seconds", value: String(scale.rawValue))]
            guard let url = components?.url else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            request.setValue("Bearer \(config.embarsyAPIKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                message = "Monitoring endpoint is unavailable. Start Embarsy API and refresh."
                return
            }
            snapshot = try decoder.decode(MonitoringSnapshot.self, from: data)
            message = snapshot.series.isEmpty ? "No embedding activity yet." : "Monitoring updated."
        } catch {
            message = "Monitoring refresh failed: \(error.localizedDescription)"
        }
    }
}
