import Foundation

struct EmbarsyConfig {
    var host = "127.0.0.1"
    var apiPort = 8000
    var qdrantRestPort = 6333
    var qdrantGrpcPort = 6334
    var ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
    var ollamaModel = "qwen3-embedding"
    var ollamaSourceModel = "hf.co/Qwen/Qwen3-Embedding-0.6B-GGUF:Q8_0"
    var ollamaKeepAlive = "-1"
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
