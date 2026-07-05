import Foundation

final class DebugLogService: ObservableObject {
    let fileURL: URL

    private let dateFormatter = ISO8601DateFormatter()

    init(logsDirectory: URL) {
        self.fileURL = logsDirectory.appendingPathComponent("embarsy-debug.log")
    }

    func startSession(securityPreflightSummary: String, buildInfoSummary: String) {
        let timestamp = dateFormatter.string(from: Date())
        let header = """
        Embarsy Debug Log
        Started: \(timestamp)
        Log file: \(fileURL.path)

        Build info:
        \(buildInfoSummary)

        Security preflight:
        \(securityPreflightSummary)

        ---

        """

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try header.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Debug logging must never break app runtime flows.
        }
    }

    func append(_ message: String, category: String = "app") {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(message)\n"
        let data = Data(line.utf8)

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Debug logging must never break app runtime flows.
        }
    }

    func export(to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.copyItem(at: fileURL, to: destination)
        } else {
            try "Embarsy debug log has not been created yet.\n".write(
                to: destination,
                atomically: true,
                encoding: .utf8
            )
        }
    }
}
