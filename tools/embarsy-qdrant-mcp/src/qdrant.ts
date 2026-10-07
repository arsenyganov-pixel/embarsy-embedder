import type { Config } from "./config.js";
import { requestJSON } from "./http.js";
import { clientHeaders } from "./client.js";

/** Qdrant authenticates with the `api-key` header; Embarsy's proxy validates the same header. */
function headers(cfg: Config): Record<string, string> {
  return { "Content-Type": "application/json", "api-key": cfg.qdrantApiKey, ...clientHeaders() };
}

function base(cfg: Config): string {
  return `${cfg.qdrantUrl}/collections/${encodeURIComponent(cfg.collection)}`;
}

export interface QdrantPoint {
  id: string;
  vector: number[];
  payload: Record<string, unknown>;
}

export interface SearchHit {
  id: string | number;
  score: number;
  payload: Record<string, any>;
}

/** Create the collection (Cosine, configured dimension) if it doesn't exist; add a file_path index. */
export async function ensureCollection(cfg: Config): Promise<void> {
  const res = await fetch(base(cfg), { headers: headers(cfg) });
  if (res.status === 200) {
    await res.text();
    return;
  }
  const body = await res.text();
  if (res.status !== 404) {
    throw new Error(`Qdrant collection check failed → HTTP ${res.status}\n${body.slice(0, 300)}`);
  }
  await requestJSON(
    base(cfg),
    {
      method: "PUT",
      headers: headers(cfg),
      body: JSON.stringify({
        // Laptop-friendly storage: full-precision originals live on disk and are only
        // read to rescore the top candidates; searches run on an in-RAM int8 copy
        // (~4x smaller, SIMD-accelerated) with no practical recall loss for cosine
        // text embeddings.
        vectors: { size: cfg.embeddingDimension, distance: "Cosine", on_disk: true },
        quantization_config: { scalar: { type: "int8", quantile: 0.99, always_ram: true } },
      }),
    },
    { label: "create collection", retries: 0 },
  );
  // Payload index on file_path enables fast delete-by-file for incremental reindex.
  try {
    await requestJSON(
      `${base(cfg)}/index`,
      {
        method: "PUT",
        headers: headers(cfg),
        body: JSON.stringify({ field_name: "file_path", field_schema: "keyword" }),
      },
      { label: "create index", retries: 0 },
    );
  } catch {
    /* index is an optimization; ignore if the Qdrant build rejects it */
  }
}

export async function upsertPoints(cfg: Config, points: QdrantPoint[]): Promise<void> {
  if (points.length === 0) return;
  await requestJSON(
    `${base(cfg)}/points?wait=true`,
    { method: "PUT", headers: headers(cfg), body: JSON.stringify({ points }) },
    { label: "upsert" },
  );
}

export async function search(
  cfg: Config,
  vector: number[],
  limit: number,
  filter?: Record<string, unknown>,
): Promise<SearchHit[]> {
  const body: Record<string, unknown> = { vector, limit, with_payload: true };
  if (filter) body.filter = filter;
  const json = await requestJSON(
    `${base(cfg)}/points/search`,
    { method: "POST", headers: headers(cfg), body: JSON.stringify(body) },
    { label: "search" },
  );
  return (json?.result ?? []) as SearchHit[];
}

export async function deleteByFilePath(cfg: Config, filePath: string): Promise<void> {
  await requestJSON(
    `${base(cfg)}/points/delete?wait=true`,
    {
      method: "POST",
      headers: headers(cfg),
      body: JSON.stringify({ filter: { must: [{ key: "file_path", match: { value: filePath } }] } }),
    },
    { label: "delete points" },
  );
}

/** Stamp `workspace` (the project's name) and `workspace_path` (the folder it was indexed
 *  from) onto EVERY point in the collection.
 *
 *  Setting them only on freshly embedded points would leave them off almost everything: an
 *  index run skips unchanged files, so on the second run nearly no point is rewritten.
 *  This is one payload write over the whole collection — no re-embedding — which also
 *  backfills collections indexed before the fields existed.
 *
 *  The absolute path is stored so Embarsy can offer "reveal this project in Finder"; it
 *  stays on the machine that indexed it, in that machine's own local Qdrant. */
export async function setWorkspacePayload(
  cfg: Config,
  workspace: string,
  workspacePath: string,
  indexRoot: string,
): Promise<void> {
  await requestJSON(
    `${base(cfg)}/points/payload?wait=true`,
    {
      method: "POST",
      headers: headers(cfg),
      // An empty filter selects every point in the collection.
      // `indexed_at` lets Embarsy show when this folder was last refreshed — stamped here,
      // at the end of a successful run, so it never claims a run that failed partway.
      body: JSON.stringify({
        // `index_root` is the folder every `file_path` is relative to. It differs from
        // `workspace_path` when a source container was indexed (`myproj/src` is the `myproj`
        // project), and the bridge needs the exact one to map a hit back onto the disk.
        payload: {
          workspace,
          workspace_path: workspacePath,
          index_root: indexRoot,
          indexed_at: Math.floor(Date.now() / 1000),
        },
        filter: {},
      }),
    },
    { label: "set workspace payload" },
  );
}

/** Map of file_path -> file_hash for every indexed file, used to skip unchanged files. */
export async function scrollFileHashes(cfg: Config): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  let offset: unknown = undefined;
  for (let guard = 0; guard < 10000; guard++) {
    const body: Record<string, unknown> = {
      limit: 256,
      with_payload: { include: ["file_path", "file_hash"] },
      with_vector: false,
    };
    if (offset !== undefined && offset !== null) body.offset = offset;
    const json = await requestJSON(
      `${base(cfg)}/points/scroll`,
      { method: "POST", headers: headers(cfg), body: JSON.stringify(body) },
      { label: "scroll" },
    );
    const points = json?.result?.points ?? [];
    for (const p of points) {
      const fp = p?.payload?.file_path;
      const fh = p?.payload?.file_hash;
      if (typeof fp === "string" && typeof fh === "string" && !out.has(fp)) out.set(fp, fh);
    }
    offset = json?.result?.next_page_offset ?? null;
    if (!offset) break;
  }
  return out;
}

/** One point's `index_root`, `workspace_path` and `file_path` — enough to work out which
 *  folder the collection's relative file paths hang off. Null when the collection is empty
 *  or unreadable. */
export async function sampleLocation(
  cfg: Config,
): Promise<{ indexRoot: string; workspacePath: string; filePath: string } | null> {
  try {
    const json = await requestJSON(
      `${base(cfg)}/points/scroll`,
      {
        method: "POST",
        headers: headers(cfg),
        body: JSON.stringify({
          limit: 1,
          with_payload: ["index_root", "workspace_path", "file_path"],
          with_vector: false,
        }),
      },
      { label: "sample collection", retries: 0 },
    );
    const p = json?.result?.points?.[0]?.payload;
    if (!p) return null;
    const str = (v: unknown) => (typeof v === "string" ? v : "");
    return { indexRoot: str(p.index_root), workspacePath: str(p.workspace_path), filePath: str(p.file_path) };
  } catch {
    return null;
  }
}

export async function collectionInfo(cfg: Config): Promise<{ pointsCount: number } | null> {
  const res = await fetch(base(cfg), { headers: headers(cfg) });
  if (res.status === 404) return null;
  const json = JSON.parse(await res.text());
  return { pointsCount: json?.result?.points_count ?? 0 };
}

/** Names of every collection in this Qdrant. */
export async function listCollections(cfg: Config): Promise<string[]> {
  const json = await requestJSON(
    `${cfg.qdrantUrl}/collections`,
    { method: "GET", headers: headers(cfg) },
    { label: "list collections" },
  );
  const items = json?.result?.collections;
  return Array.isArray(items)
    ? items.map((c: any) => String(c?.name ?? "")).filter(Boolean)
    : [];
}

/** The folder a collection was indexed from, or null when it carries no `workspace_path`
 *  (collections written by other tools). One sampled point is enough — the field is stamped
 *  across every point in the collection by the same run. */
export async function workspacePathOf(cfg: Config, collection: string): Promise<string | null> {
  try {
    const json = await requestJSON(
      `${cfg.qdrantUrl}/collections/${encodeURIComponent(collection)}/points/scroll`,
      {
        method: "POST",
        headers: headers(cfg),
        body: JSON.stringify({ limit: 1, with_payload: ["workspace_path"], with_vector: false }),
      },
      { label: "sample collection", retries: 0 },
    );
    const value = json?.result?.points?.[0]?.payload?.workspace_path;
    return typeof value === "string" && value ? value : null;
  } catch {
    return null; // an unreadable collection simply is not a candidate
  }
}
