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
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return payload?["version"] as? String ?? "unknown"
        } catch {
            return nil
        }
    }
}
