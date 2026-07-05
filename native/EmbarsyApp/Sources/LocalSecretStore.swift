import Foundation
import Security

enum LocalSecretError: LocalizedError {
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            "Local secret generation failed with status \(status)."
        }
    }
}

struct LocalSecretStore {
    let fileURL: URL

    func value(for account: String) throws -> String? {
        try values()[account]
    }

    func set(_ value: String, for account: String) throws {
        var storedValues = try values()
        storedValues[account] = value
        try write(storedValues)
    }

    func getOrCreateHexSecret(account: String, bytes: Int) throws -> String {
        if let value = try value(for: account), !value.isEmpty {
            return value
        }

        let value = try Self.generateHexSecret(bytes: bytes)
        try set(value, for: account)
        return value
    }

    static func generateHexSecret(bytes: Int) throws -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, bytes, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw LocalSecretError.randomGenerationFailed(status) }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    func resetSecrets(_ secrets: [(account: String, value: String)]) throws {
        var storedValues = try values()
        secrets.forEach { storedValues[$0.account] = $0.value }
        try write(storedValues)
    }

    func deleteAll() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Already clean.
        }
    }

    private func values() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [:] }
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        return decoded
    }

    private func write(_ values: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try JSONEncoder().encode(values)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
