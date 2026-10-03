import Foundation

struct EmbarsyConfig {
    /// Version of the Embarsy API binary BUNDLED with this app build (kept in sync with
    /// `src/embarsy_api/__init__.py`). The Status screen compares it with what the
    /// running process reports at /health: after an app update the previous API process
    /// can still be serving on :8000, and a mismatch surfaces the "Update" button.
    static let bundledAPIVersion = "0.2.2"

    var host = "127.0.0.1"
    var apiPort = 8000
    var qdrantRestPort = 6333
    var qdrantGrpcPort = 6334
    var ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
    var ollamaModel = "qwen3-embedding"
    var ollamaSourceModel = "hf.co/Qwen/Qwen3-Embedding-0.6B-GGUF:Q8_0"
    /// Unload the embedding model after 30 idle minutes (was "-1" = pinned forever). Ollama
    /// transparently reloads it on the next request; ~700MB RAM comes back when idle.
    var ollamaKeepAlive = "30m"
    var embeddingDimension = 1024
    var searchScoreThreshold = "0.4"
    var maxSearchResults = "50"
    var qdrantAPIKey = ""
    var embarsyAPIKey = ""

    var apiBaseURL: URL { URL(string: "http://\(host):\(apiPort)")! }
    var qdrantBaseURL: URL { URL(string: "http://\(host):\(qdrantRestPort)")! }
    var qdrantProxyBaseURL: URL { apiBaseURL.appendingPathComponent("qdrant") }
    var ollamaHost: String { ollamaBaseURL.absoluteString.replacingOccurrences(of: "http://", with: "") }
}
