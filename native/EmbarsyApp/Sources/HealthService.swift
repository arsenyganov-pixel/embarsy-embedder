import Foundation

struct HealthService {
    func isReady(url: URL, headers: [String: String] = [:]) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// Version string the running Embarsy API reports at /health. Returns nil when the
    /// endpoint is unreachable; `"unknown"` when it responds but predates the version
    /// field (any 0.1.x binary) — which reads as "older than the bundled API".
    func reportedAPIVersion(healthURL: URL) async -> String? {
        await report(healthURL: healthURL)?.version
    }

    /// One /health read with everything Status needs. The API counts rejected keys there,
    /// so an editor still holding a key from a previous install surfaces with no extra call.
    func report(healthURL: URL) async -> APIHealthReport? {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let failures = payload?["auth_failures"] as? [String: Any]
            // Window the banner off the STALE timestamp, never the generic one: an
            // unrelated 401 (a curl with no header, a browser tab) must not resurrect a
            // diagnosis the user already fixed. Older APIs only sent last_at.
            let staleAt = (failures?["stale_last_at"] as? Double)
                ?? (failures?["last_at"] as? Double ?? 0)
            return APIHealthReport(
                version: payload?["version"] as? String ?? "unknown",
                rejectedKeys: (failures?["api"] as? Int ?? 0) + (failures?["qdrant"] as? Int ?? 0),
                looksStale: failures?["looks_stale"] as? Bool ?? false,
                lastFailureAt: staleAt > 0 ? Date(timeIntervalSince1970: staleAt) : nil
            )
        } catch {
            return nil
        }
    }
}

/// What /health tells the app about the running API.
struct APIHealthReport {
    let version: String
    /// 401s served since the API started (editors retry, so this climbs quickly).
    let rejectedKeys: Int
    /// A rejected key had the shape of THIS slot's key from a previous installation
    /// (a swapped key or a typo does not count).
    let looksStale: Bool
    /// When that stale-shaped key was last seen — drives the banner's expiry.
    let lastFailureAt: Date?
}
