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
}
