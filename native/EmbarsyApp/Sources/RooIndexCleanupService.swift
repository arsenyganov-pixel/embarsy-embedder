import CryptoKit
import Foundation

struct RooIndexCleanupRequest {
    let workspacePath: String
    let qdrantBaseURL: URL
    let qdrantAPIKey: String
}

struct RooIndexCleanupResult {
    let workspacePath: String
    let collectionName: String
    let cacheFile: URL
    var deletedCollections: [String] = []
    var missingCollections: [String] = []
    var clearedCacheFiles: [URL] = []
    var missingCacheFiles: [URL] = []

    var summary: String {
        let collectionSummary = deletedCollections.isEmpty
            ? "Qdrant collection was already absent"
            : "deleted Qdrant collection \(deletedCollections.joined(separator: ", "))"
        let cacheSummary = clearedCacheFiles.isEmpty
            ? "Watcher cache file was already absent"
            : "cleared Watcher cache file \(clearedCacheFiles.map(\.path).joined(separator: ", "))"
        return "Clear Watcher Index finished: \(collectionSummary); \(cacheSummary)."
    }
}

enum RooIndexCleanupError: LocalizedError {
    case emptyWorkspacePath
    case qdrantRequestFailed(statusCode: Int, body: String)
    case invalidQdrantResponse

    var errorDescription: String? {
        switch self {
        case .emptyWorkspacePath:
            return "Select a default project before clearing the Watcher index."
        case let .qdrantRequestFailed(statusCode, body):
            return "Qdrant request failed with HTTP \(statusCode): \(body)"
        case .invalidQdrantResponse:
            return "Qdrant returned an invalid collections response."
        }
    }
}

struct RooIndexCleanupService {
    private let fileManager: FileManager
    private let session: URLSession

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
    }

    func clearWorkspaceIndex(_ request: RooIndexCleanupRequest) async throws -> RooIndexCleanupResult {
        let workspacePath = request.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspacePath.isEmpty else { throw RooIndexCleanupError.emptyWorkspacePath }

        let collectionName = Self.collectionName(forWorkspacePath: workspacePath)
        let cacheFile = Self.cacheFile(forWorkspacePath: workspacePath)
        var result = RooIndexCleanupResult(
            workspacePath: workspacePath,
            collectionName: collectionName,
            cacheFile: cacheFile
        )

        let collections = try await collectionNames(baseURL: request.qdrantBaseURL, apiKey: request.qdrantAPIKey)
        if collections.contains(collectionName) {
            try await deleteCollection(collectionName, baseURL: request.qdrantBaseURL, apiKey: request.qdrantAPIKey)
            result.deletedCollections.append(collectionName)
        } else {
            result.missingCollections.append(collectionName)
        }

        if fileManager.fileExists(atPath: cacheFile.path) {
            try Data("{}".utf8).write(to: cacheFile, options: .atomic)
            result.clearedCacheFiles.append(cacheFile)
        } else {
            result.missingCacheFiles.append(cacheFile)
        }

        return result
    }

    static func collectionName(forWorkspacePath workspacePath: String) -> String {
        let digest = sha256Hex(workspacePath)
        return "ws-\(digest.prefix(16))"
    }

    static func cacheFile(forWorkspacePath workspacePath: String) -> URL {
        vscodeGlobalStorageDirectory()
            .appendingPathComponent("zoocodeorganization.zoo-code", isDirectory: true)
            .appendingPathComponent("roo-index-cache-\(sha256Hex(workspacePath)).json")
    }

    static func vscodeGlobalStorageDirectory() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage", isDirectory: true)
    }

    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func collectionNames(baseURL: URL, apiKey: String) async throws -> Set<String> {
        var request = URLRequest(url: baseURL.appendingPathComponent("collections"))
        request.timeoutInterval = 5
        request.httpMethod = "GET"
        applyQdrantHeaders(to: &request, apiKey: apiKey)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(QdrantCollectionsResponse.self, from: data)
        return Set(decoded.result.collections.map(\.name))
    }

    private func deleteCollection(_ name: String, baseURL: URL, apiKey: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("collections").appendingPathComponent(name))
        request.timeoutInterval = 10
        request.httpMethod = "DELETE"
        applyQdrantHeaders(to: &request, apiKey: apiKey)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func applyQdrantHeaders(to request: inout URLRequest, apiKey: String) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RooIndexCleanupError.invalidQdrantResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
            throw RooIndexCleanupError.qdrantRequestFailed(statusCode: http.statusCode, body: body)
        }
    }
}

private struct QdrantCollectionsResponse: Decodable {
    let result: QdrantCollectionsResult
}

private struct QdrantCollectionsResult: Decodable {
    let collections: [QdrantCollection]
}

private struct QdrantCollection: Decodable {
    let name: String
}
