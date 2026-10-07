import Foundation

/// Connects coding agents to Embarsy by writing their MCP config for them.
///
/// Everything the config needs lives inside the app bundle — the Node runtime and the bridge
/// — so connecting never depends on npm, on a Node that happens to be on PATH, or on a
/// network. The paths written are absolute and always exist, which is what the editors need:
/// they launch MCP servers with a minimal PATH that includes neither Homebrew nor nvm.
///
/// Both files belong to live applications, so each is read, modified in place and written
/// atomically: every unrelated key and every other server in them survives untouched.
enum EditorAgent: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Value written as `EMBARSY_CLIENT`, which is the only way Activity can name the editor:
    /// both agents spawn the identical bridge binary, so nothing about the connection itself
    /// distinguishes them.
    var clientTag: String {
        switch self {
        case .claude: return "claude-code"
        case .codex: return "codex"
        }
    }

    /// `home` is injectable so the write paths can be exercised against a scratch directory
    /// instead of the real editor configs.
    func configURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        switch self {
        case .claude: return home.appendingPathComponent(".claude.json")
        case .codex: return home.appendingPathComponent(".codex/config.toml")
        }
    }

    /// What the user has to do for a freshly written config to take effect.
    var activationHint: String {
        switch self {
        case .claude: return "restart Claude Code to pick it up"
        case .codex: return "restart Codex to pick it up"
        }
    }
}

enum EditorConnectionState: Equatable {
    case connected
    case notConnected
    /// Registered through a bridge installed separately (npm) — it works, it just updates on
    /// its own schedule instead of with the app. Not an error, and must not look like one.
    case connectedViaExternalBridge(path: String)
    /// Registered to a runtime that no longer exists — Embarsy was moved or replaced. The
    /// editor fails to start the server, which "not connected" would misdiagnose.
    case connectedToMissingBuild(path: String)

    var isConnected: Bool { self != .notConnected }
}

struct EditorConnectionService {
    static let serverName = "embarsy-qdrant"

    let paths: AppPaths
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Reading state

    func state(of agent: EditorAgent) -> EditorConnectionState {
        guard let recorded = recordedCommand(for: agent) else { return .notConnected }
        if recorded == paths.bundledNode.path { return .connected }
        // The two foreign cases differ in the only way that matters to the user: whether the
        // editor can actually start the server.
        return FileManager.default.isExecutableFile(atPath: recorded)
            ? .connectedViaExternalBridge(path: recorded)
            : .connectedToMissingBuild(path: recorded)
    }

    private func recordedCommand(for agent: EditorAgent) -> String? {
        guard let text = try? String(contentsOf: agent.configURL(home: home), encoding: .utf8) else { return nil }
        switch agent {
        case .claude:
            guard
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let servers = json["mcpServers"] as? [String: Any],
                let ours = servers[Self.serverName] as? [String: Any]
            else { return nil }
            return ours["command"] as? String
        case .codex:
            // Hand-parsed rather than pulling in a TOML library for two lines: find our
            // section, then the first `command =` inside it.
            guard let sectionRange = text.range(of: "[mcp_servers.\(Self.serverName)]") else { return nil }
            let rest = text[sectionRange.upperBound...]
            for line in rest.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[mcp_servers.\(Self.serverName)") { break }
                if trimmed.hasPrefix("command = ") {
                    return String(trimmed.dropFirst("command = ".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            return nil
        }
    }

    // MARK: Writing

    func connect(_ agent: EditorAgent, config: EmbarsyConfig) throws {
        switch agent {
        case .claude: try writeClaude(config: config, remove: false)
        case .codex: try writeCodex(config: config, remove: false)
        }
    }

    func disconnect(_ agent: EditorAgent) throws {
        switch agent {
        case .claude: try writeClaude(config: nil, remove: true)
        case .codex: try writeCodex(config: nil, remove: true)
        }
    }

    /// The env block handed to the bridge. A collection is deliberately NOT pinned: the
    /// bridge resolves it from the folder the editor is working in, so one registration
    /// serves every indexed project instead of only the one current when it was written.
    private func environment(for agent: EditorAgent, config: EmbarsyConfig) -> [String: String] {
        [
            "EMBARSY_CLIENT": agent.clientTag,
            "OPENAI_BASE_URL": config.apiBaseURL.appendingPathComponent("v1").absoluteString,
            "OPENAI_API_KEY": config.embarsyAPIKey,
            "EMBEDDING_MODEL": config.ollamaModel,
            "EMBEDDING_DIMENSION": String(config.embeddingDimension),
            "QDRANT_URL": config.qdrantProxyBaseURL.absoluteString,
            "QDRANT_API_KEY": config.qdrantAPIKey,
        ]
    }

    private func writeClaude(config: EmbarsyConfig?, remove: Bool) throws {
        let url = EditorAgent.claude.configURL(home: home)
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConnectionError.unreadableConfig(url.path)
            }
            json = parsed
        }
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        if remove {
            servers.removeValue(forKey: Self.serverName)
        } else if let config {
            servers[Self.serverName] = [
                "command": paths.bundledNode.path,
                "args": [paths.bundledBridgeMCP.path],
                "env": environment(for: .claude, config: config),
            ]
        }
        json["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try writeAtomically(data, to: url)
    }

    private func writeCodex(config: EmbarsyConfig?, remove: Bool) throws {
        let url = EditorAgent.codex.configURL(home: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var body = Self.strippingOurSection(from: existing).trimmingCharacters(in: .newlines)

        if !remove, let config {
            let env = environment(for: .codex, config: config)
            var lines = [
                "",
                "[mcp_servers.\(Self.serverName)]",
                "command = \(Self.tomlString(paths.bundledNode.path))",
                "args = [\(Self.tomlString(paths.bundledBridgeMCP.path))]",
                "",
                "[mcp_servers.\(Self.serverName).env]",
            ]
            // Sorted so a re-write produces a stable file instead of reshuffling the block.
            lines += env.keys.sorted().map { "\($0) = \(Self.tomlString(env[$0]!))" }
            body += "\n" + lines.joined(separator: "\n")
        }
        try writeAtomically(Data((body + "\n").utf8), to: url)
    }

    /// Drop our own section and its `.env` child, leaving every other server's block as it
    /// was. A TOML section runs until the next `[header]` or end of file.
    static func strippingOurSection(from source: String) -> String {
        var out: [Substring] = []
        var skipping = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                skipping = trimmed == "[mcp_servers.\(serverName)]"
                    || trimmed.hasPrefix("[mcp_servers.\(serverName).")
            }
            if !skipping { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// TOML basic-string escaping, written out rather than borrowed from a JSON encoder:
    /// Foundation escapes forward slashes as `\\/`, which is valid JSON but NOT a legal TOML
    /// escape — every path we write would make Codex's config fail to parse.
    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Replace via a temporary file in the same directory: these configs belong to running
    /// applications, and a partially written one breaks the editor itself.
    private func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).embarsy-tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    enum ConnectionError: LocalizedError {
        case unreadableConfig(String)

        var errorDescription: String? {
            switch self {
            case .unreadableConfig(let path):
                return "\(path) is not valid JSON. Fix or remove it, then connect again."
            }
        }
    }
}
