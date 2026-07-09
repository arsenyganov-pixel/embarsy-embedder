import type { Config } from "./config.js";
import { requestJSON } from "./http.js";

/**
 * Embed a batch of texts through the OpenAI-COMPATIBLE endpoint (Embarsy's /v1 proxy).
 * This is the piece other tools get wrong: we send a bearer API key and use the standard
 * POST /v1/embeddings shape, so Embarsy authenticates the call and counts it in Monitoring.
 */
/** Absolute per-input cap (defense in depth on top of chunking) so no single text can overflow
 *  the model's context and crash the embedding backend, whatever produced it. */
const MAX_EMBED_CHARS = 8000;

/** Lone surrogates (an emoji cut in half by any UTF-16 slice) are invalid Unicode: the
 *  Embarsy API's UTF-8 re-encode for Ollama rejects them, failing the whole batch with
 *  a 500. Replace them with U+FFFD so one broken character can never sink an index run. */
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g;

function wellFormed(text: string): string {
  return text.replace(LONE_SURROGATE, "�");
}

export async function embedBatch(texts: string[], cfg: Config): Promise<number[][]> {
  if (texts.length === 0) return [];
  const input = texts.map((t) => wellFormed(t.length > MAX_EMBED_CHARS ? t.slice(0, MAX_EMBED_CHARS) : t));
  const json = await requestJSON(
    `${cfg.openaiBaseUrl}/embeddings`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${cfg.openaiApiKey}`,
      },
      body: JSON.stringify({ model: cfg.embeddingModel, input }),
    },
    // Extra retries: if the embedding backend hiccups (e.g. Ollama restarts llama-server), ride
    // out the restart instead of aborting the whole index.
    { label: "embeddings", retries: 4 },
  );

  const data = json?.data;
  if (!Array.isArray(data) || data.length !== input.length) {
    throw new Error(
      `Unexpected embeddings response (got ${Array.isArray(data) ? data.length : "no"} vectors for ${input.length} inputs).`,
    );
  }
  // Respect the `index` field so ordering is guaranteed to match the input.
  const ordered = [...data].sort((a, b) => (a.index ?? 0) - (b.index ?? 0));
  return ordered.map((d: any) => {
    const v = d?.embedding;
    if (!Array.isArray(v)) throw new Error("Embeddings response item missing `embedding` array.");
    return v as number[];
  });
}

export async function embedOne(text: string, cfg: Config): Promise<number[]> {
  const [v] = await embedBatch([text], cfg);
  if (!v) throw new Error("No embedding returned.");
  return v;
}
