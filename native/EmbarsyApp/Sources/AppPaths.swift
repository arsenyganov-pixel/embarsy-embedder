import Foundation

struct AppPaths {
    let appSupport: URL
    let runDirectory: URL
    let logsDirectory: URL
    let qdrantStorage: URL
    let qdrantConfig: URL
    let ollamaModels: URL
    let installMarker: URL
    let localSecretsFile: URL
    let bundledQdrant: URL
    let bundledOllama: URL
    let bundledAPI: URL

    static func live(bundle: Bundle = .main) throws -> AppPaths {
        let fileManager = FileManager.default
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Embarsy", isDirectory: true)

        let resources = bundle.resourceURL ?? bundle.bundleURL
        return AppPaths(
            appSupport: appSupportRoot,
            runDirectory: appSupportRoot.appendingPathComponent("run", isDirectory: true),
            logsDirectory: appSupportRoot.appendingPathComponent("logs", isDirectory: true),
            qdrantStorage: appSupportRoot.appendingPathComponent("qdrant/storage", isDirectory: true),
            qdrantConfig: appSupportRoot.appendingPathComponent("qdrant/config.yaml"),
            ollamaModels: appSupportRoot.appendingPathComponent("ollama", isDirectory: true),
            installMarker: appSupportRoot.appendingPathComponent(".installed"),
            localSecretsFile: appSupportRoot.appendingPathComponent(".local-secrets.json"),
            bundledQdrant: resources.appendingPathComponent("qdrant"),
            bundledOllama: resources.appendingPathComponent("ollama"),
            bundledAPI: resources.appendingPathComponent("embarsy-api")
        )
    }

    func createDirectories() throws {
        let fileManager = FileManager.default
        try [appSupport, runDirectory, logsDirectory, qdrantStorage, ollamaModels]
            .forEach { try fileManager.createDirectory(at: $0, withIntermediateDirectories: true) }
        try fileManager.createDirectory(
            at: qdrantConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
