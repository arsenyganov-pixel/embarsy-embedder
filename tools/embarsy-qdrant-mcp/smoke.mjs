// End-to-end smoke test against a live Embarsy stack.
// Usage: OPENAI_API_KEY=... QDRANT_API_KEY=... node smoke.mjs [targetDir] [query]
// Not published (excluded by package.json "files").
import path from "node:path";
import { loadConfig, requireConfig } from "./dist/config.js";
import { indexRepo } from "./dist/indexer.js";
import { embedOne } from "./dist/embeddings.js";
import { search, collectionInfo } from "./dist/qdrant.js";

const cfg = loadConfig({ collection: process.env.SMOKE_COLLECTION || "embarsy-selftest" });
requireConfig(cfg, { needCollection: true });

const target = path.resolve(process.argv[2] || "src");
console.log(`Indexing ${target} → collection "${cfg.collection}"`);
console.log(`  embeddings: ${cfg.openaiBaseUrl} (${cfg.embeddingModel}, dim ${cfg.embeddingDimension})`);
console.log(`  qdrant:     ${cfg.qdrantUrl}\n`);

const started = Date.now();
const result = await indexRepo(target, cfg, { onProgress: (m) => console.log(m) });
console.log(`\nIndex result (${((Date.now() - started) / 1000).toFixed(1)}s):`, result);

const info = await collectionInfo(cfg);
console.log(`Collection points_count: ${info?.pointsCount}\n`);

const query = process.argv[3] || "how are files discovered and filtered using gitignore";
console.log(`Search: ${JSON.stringify(query)}`);
const vec = await embedOne(query, cfg);
const hits = await search(cfg, vec, 5);
if (hits.length === 0) console.log("  (no hits)");
for (const h of hits) {
  const p = h.payload ?? {};
  console.log(`  ${p.file_path}:${p.start_line}-${p.end_line} [${p.language}]  score=${h.score.toFixed(3)}`);
}
