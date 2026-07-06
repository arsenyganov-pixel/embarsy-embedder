import type { Config } from "./config.js";
import { requestJSON } from "./http.js";

/**
 * Embed a batch of texts through the OpenAI-COMPATIBLE endpoint (Embarsy's /v1 proxy).
 * This is the piece other tools get wrong: we send a bearer API key and use the standard
 * POST /v1/embeddings shape, so Embarsy authenticates the call and counts it in Monitoring.
 */
export async function embedBatch(texts: string[], cfg: Config): Promise<number[][]> {
  if (texts.length === 0) return [];
  const json = await requestJSON(
    `${cfg.openaiBaseUrl}/embeddings`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${cfg.openaiApiKey}`,
      },
      body: JSON.stringify({ model: cfg.embeddingModel, input: texts }),
    },
    { label: "embeddings" },
  );

  const data = json?.data;
  if (!Array.isArray(data) || data.length !== texts.length) {
    throw new Error(
      `Unexpected embeddings response (got ${Array.isArray(data) ? data.length : "no"} vectors for ${texts.length} inputs).`,
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
