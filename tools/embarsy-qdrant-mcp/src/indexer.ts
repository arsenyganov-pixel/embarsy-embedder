import { promises as fs } from "node:fs";
import path from "node:path";
import type { Config } from "./config.js";
import { embedBatch } from "./embeddings.js";
import { chunkFile } from "./chunker.js";
import { discoverFiles } from "./walk.js";
import {
  ensureCollection,
  upsertPoints,
  deleteByFilePath,
  scrollFileHashes,
  setWorkspacePayload,
  type QdrantPoint,
} from "./qdrant.js";
import { sha256, pointId, languageForExtension } from "./util.js";

export interface IndexResult {
  files: number;
  indexed: number;   // files (re)embedded
  skipped: number;   // unchanged files
  removed: number;   // files deleted from the index
  chunks: number;    // chunks upserted
  skippedMinified: number; // files skipped as minified / generated blobs
}

export interface IndexOptions {
  onProgress?: (msg: string) => void;
}

/** Crude binary guard: a NUL byte early in the file means it isn't source text. */
function looksBinary(s: string): boolean {
  const n = Math.min(s.length, 8192);
  for (let i = 0; i < n; i++) {
    if (s.charCodeAt(i) === 0) return true;
  }
  return false;
}

/** Longest line length — a line far longer than any hand-written source line flags a minified
 *  / bundled / single-blob file (a poor embedding candidate that also stresses the model). */
function maxLineLength(s: string): number {
  let max = 0, cur = 0;
  for (let i = 0; i < s.length; i++) {
    if (s.charCodeAt(i) === 10) { if (cur > max) max = cur; cur = 0; } else cur++;
  }
  return cur > max ? cur : max;
}

/** Directories that hold source but never name a project. */
const CONTAINER_DIRS = new Set([
  "src", "source", "sources", "lib", "libs", "app", "apps",
  "internal", "cmd", "pkg", "test", "tests",
]);

/** The folder that NAMES this project: the indexed directory, or its nearest ancestor that
 *  isn't a source container — indexing `~/code/myproj/src` is still the `myproj` project.
 *
 *  Name and path are derived from this one value on purpose. Embarsy shows the name and
 *  reveals the path in Finder, so a name taken from `myproj` while the path pointed at
 *  `myproj/src` would open a folder the label never mentioned. */
export function workspaceRootFor(rootAbs: string): string {
  let current = rootAbs;
  for (;;) {
    const name = path.basename(current);
    const parent = path.dirname(current);
    if (!name || parent === current) return rootAbs;
    if (!CONTAINER_DIRS.has(name.toLowerCase())) return current;
    current = parent;
  }
}

/** Full/incremental index of a directory into the configured Qdrant collection. */
export async function indexRepo(root: string, cfg: Config, opts: IndexOptions = {}): Promise<IndexResult> {
  const log = opts.onProgress ?? (() => {});
  const rootAbs = path.resolve(root);
  const workspaceRoot = workspaceRootFor(rootAbs);
  const workspace = path.basename(workspaceRoot);

  await ensureCollection(cfg);
  const files = await discoverFiles(rootAbs, cfg);
  log(`Found ${files.length} indexable files in ${rootAbs}`);

  const existing = await scrollFileHashes(cfg);
  const seen = new Set<string>();
  const result: IndexResult = { files: files.length, indexed: 0, skipped: 0, removed: 0, chunks: 0, skippedMinified: 0 };

  // Pending chunk buffer, flushed in embedding batches across files.
  let pending: { text: string; payload: Record<string, unknown>; key: string }[] = [];

  const flush = async () => {
    if (pending.length === 0) return;
    const vectors = await embedBatch(pending.map((p) => p.text), cfg);
    const points: QdrantPoint[] = pending.map((p, i) => ({
      id: pointId(p.key),
      vector: vectors[i]!,
      payload: p.payload,
    }));
    await upsertPoints(cfg, points);
    result.chunks += points.length;
    pending = [];
  };

  for (const file of files) {
    seen.add(file.rel);
    let content: string;
    try {
      content = await fs.readFile(file.abs, "utf8");
    } catch {
      continue;
    }
    if (looksBinary(content)) continue;
    if (maxLineLength(content) > cfg.maxLineChars) {
      result.skippedMinified++;
      log(`  skipped (minified/generated): ${file.rel}`);
      continue;
    }

    const hash = sha256(content);
    if (existing.get(file.rel) === hash) {
      result.skipped++;
      continue;
    }
    // Changed or new: drop the file's old points, then re-chunk.
    if (existing.has(file.rel)) await deleteByFilePath(cfg, file.rel);

    const ext = path.extname(file.rel).replace(/^\./, "").toLowerCase();
    const language = languageForExtension(ext);
    const chunks = chunkFile(content, cfg);
    chunks.forEach((c, idx) => {
      pending.push({
        key: `${file.rel}:${idx}`,
        text: `${file.rel}\n\n${c.text}`, // path gives the embedder useful context
        payload: {
          file_path: file.rel,
          workspace,
          language,
          start_line: c.startLine,
          end_line: c.endLine,
          file_hash: hash,
          chunk_index: idx,
          text: c.text.length > 4000 ? c.text.slice(0, 4000) : c.text,
        },
      });
    });
    result.indexed++;
    if (pending.length >= cfg.embedBatch) await flush();
    if (result.indexed % 25 === 0) log(`  indexed ${result.indexed} files, ${result.chunks + pending.length} chunks…`);
  }
  await flush();

  // Prune files that no longer exist on disk.
  for (const rel of existing.keys()) {
    if (!seen.has(rel)) {
      await deleteByFilePath(cfg, rel);
      result.removed++;
    }
  }

  // Backfills points this run skipped as unchanged, and points indexed by an older bridge
  // that never wrote the field — without it the name would stay missing until every file
  // in the project happened to change.
  await setWorkspacePayload(cfg, workspace, workspaceRoot);

  return result;
}
