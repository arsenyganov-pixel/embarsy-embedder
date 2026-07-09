import { promises as fs } from "node:fs";
import path from "node:path";
import ignoreImport from "ignore";
import type { Config } from "./config.js";

/** Minimal surface of the `ignore` matcher we use (its default export is a factory). */
interface Ignorer {
  ignores(p: string): boolean;
  add(patterns: string): unknown;
}
function createIgnorer(): Ignorer {
  const f = ignoreImport as unknown as any;
  return typeof f === "function" ? f() : f.default();
}

/** Directories never worth indexing (in addition to whatever .gitignore says). */
const SKIP_DIRS = new Set([
  ".git", ".hg", ".svn", "node_modules", ".venv", "venv", "__pycache__", ".mypy_cache",
  ".pytest_cache", "dist", "build", "out", "target", ".next", ".nuxt", ".svelte-kit",
  ".turbo", ".cache", "coverage", ".idea", ".vscode", ".gradle", "Pods", ".terraform",
  "vendor", "bin", "obj", ".DS_Store",
]);

/** Extensions we treat as indexable source/text. */
const CODE_EXT = new Set([
  "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "kts",
  "swift", "c", "h", "cc", "cpp", "hpp", "cs", "php", "scala", "sh", "bash", "zsh", "sql",
  "md", "mdx", "json", "yaml", "yml", "toml", "html", "htm", "css", "scss", "sass", "less",
  "vue", "svelte", "lua", "ex", "exs", "dart", "r", "pl", "pm", "proto", "graphql", "gql",
  "tf", "gradle", "groovy", "m", "mm", "clj", "cljs", "edn", "elm", "erl", "hs", "ml", "nim",
  "txt", "cfg", "ini",
]);
// ".env"-family files (prod.env, config.env, …) are deliberately NOT in CODE_EXT: they
// hold secrets, not code worth semantic-searching, and indexing them would ship
// credentials to the embeddings endpoint and Qdrant. (A literal ".env" has no extension
// and is skipped anyway.)

export interface DiscoveredFile {
  abs: string;
  rel: string; // POSIX-style relative path from root
}

export async function discoverFiles(root: string, cfg: Config): Promise<DiscoveredFile[]> {
  const rootAbs = path.resolve(root);
  const ig = createIgnorer();
  await loadGitignore(ig, rootAbs);

  const out: DiscoveredFile[] = [];
  await walk(rootAbs, rootAbs, ig, cfg, out);
  out.sort((a, b) => a.rel.localeCompare(b.rel));
  return out;
}

async function loadGitignore(ig: Ignorer, rootAbs: string): Promise<void> {
  try {
    const text = await fs.readFile(path.join(rootAbs, ".gitignore"), "utf8");
    ig.add(text);
  } catch {
    /* no .gitignore — fine */
  }
}

async function walk(
  dir: string,
  rootAbs: string,
  ig: Ignorer,
  cfg: Config,
  out: DiscoveredFile[],
): Promise<void> {
  let entries: import("node:fs").Dirent[];
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const abs = path.join(dir, entry.name);
    const rel = toPosix(path.relative(rootAbs, abs));
    if (!rel || rel.startsWith("..")) continue;

    if (entry.isSymbolicLink()) continue;

    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      if (ig.ignores(rel + "/")) continue;
      await walk(abs, rootAbs, ig, cfg, out);
      continue;
    }
    if (!entry.isFile()) continue;
    if (ig.ignores(rel)) continue;

    const ext = path.extname(entry.name).replace(/^\./, "").toLowerCase();
    // Only index files with a known code/text extension.
    if (!CODE_EXT.has(ext)) continue;

    try {
      const st = await fs.stat(abs);
      if (st.size > cfg.maxFileBytes || st.size === 0) continue;
    } catch {
      continue;
    }
    out.push({ abs, rel });
  }
}

const toPosix = (p: string) => p.split(path.sep).join("/");
