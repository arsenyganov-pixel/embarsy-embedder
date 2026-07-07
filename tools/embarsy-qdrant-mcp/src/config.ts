/**
 * Configuration resolved from environment variables, with Embarsy-friendly defaults so a
 * minimal setup ("just the two API keys") works out of the box.
 *
 * Both embeddings and Qdrant default to Embarsy's proxy on :8000 — that is the whole point of
 * this tool: everything flows through Embarsy so the API keys are honored and the Monitoring
 * counters (both embedding and Qdrant) move.
 */
export interface Config {
  openaiBaseUrl: string;   // OpenAI-compatible embeddings endpoint (Embarsy: http://localhost:8000/v1)
  openaiApiKey: string;    // Embarsy "API Key" (Status page)
  embeddingModel: string;  // e.g. qwen3-embedding
  embeddingDimension: number; // vector size (qwen3-embedding = 1024)
  qdrantUrl: string;       // Qdrant REST base (Embarsy proxy: http://localhost:8000/qdrant)
  qdrantApiKey: string;    // Embarsy "Qdrant API Key" (Status page)
  collection: string;      // Qdrant collection name
  chunkMaxChars: number;
  chunkOverlapChars: number;
  embedBatch: number;      // texts per embeddings request
  maxFileBytes: number;    // skip files larger than this
  maxLineChars: number;    // skip files with a line longer than this (minified / generated blobs)
}

function intEnv(value: string | undefined, fallback: number): number {
  if (value === undefined || value.trim() === "") return fallback;
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) ? n : fallback;
}

const stripTrailingSlash = (s: string) => s.replace(/\/+$/, "");

export function loadConfig(overrides: Partial<Config> = {}): Config {
  const env = process.env;
  return {
    openaiBaseUrl: stripTrailingSlash(env.OPENAI_BASE_URL ?? "http://localhost:8000/v1"),
    openaiApiKey: env.OPENAI_API_KEY ?? "",
    embeddingModel: env.EMBEDDING_MODEL ?? "qwen3-embedding",
    embeddingDimension: intEnv(env.EMBEDDING_DIMENSION, 1024),
    qdrantUrl: stripTrailingSlash(env.QDRANT_URL ?? "http://localhost:8000/qdrant"),
    qdrantApiKey: env.QDRANT_API_KEY ?? "",
    collection: env.QDRANT_COLLECTION_NAME ?? env.QDRANT_COLLECTION ?? "",
    chunkMaxChars: intEnv(env.EMBARSY_CHUNK_CHARS, 1500),
    chunkOverlapChars: intEnv(env.EMBARSY_CHUNK_OVERLAP, 200),
    embedBatch: intEnv(env.EMBARSY_EMBED_BATCH, 32),
    maxFileBytes: intEnv(env.EMBARSY_MAX_FILE_BYTES, 1_000_000),
    maxLineChars: intEnv(env.EMBARSY_MAX_LINE_CHARS, 5000),
    ...overrides,
  };
}

/** Throw a clear, actionable error if a required value is missing. */
export function requireConfig(cfg: Config, opts: { needCollection: boolean }): void {
  const missing: string[] = [];
  if (!cfg.openaiApiKey) missing.push("OPENAI_API_KEY (Embarsy → Status → API Key)");
  if (!cfg.qdrantApiKey) missing.push("QDRANT_API_KEY (Embarsy → Status → Qdrant API Key)");
  if (opts.needCollection && !cfg.collection) {
    missing.push("QDRANT_COLLECTION_NAME (or pass --collection)");
  }
  if (missing.length > 0) {
    throw new Error(
      "Missing required configuration:\n  - " + missing.join("\n  - ") +
      "\n\nSet them as environment variables. Copy the API keys from Embarsy → Status."
    );
  }
}
