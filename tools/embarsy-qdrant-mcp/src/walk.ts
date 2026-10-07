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
  // Xcode / SwiftPM build output. Usually covered by the project's own .gitignore, but a
  // folder that holds several projects is indexed from above them, and a checkout without
  // a .gitignore still builds into these.
  ".build", "DerivedData", ".swiftpm",
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

/** One `.gitignore`, with the folder (relative to the indexed root, POSIX, "" for the root
 *  itself) its patterns are relative to. */
interface IgnoreLayer {
  base: string;
  ig: Ignorer;
}

export async function discoverFiles(root: string, cfg: Config): Promise<DiscoveredFile[]> {
  const rootAbs = path.resolve(root);
  const out: DiscoveredFile[] = [];
  await walk(rootAbs, rootAbs, [], cfg, out);
  out.sort((a, b) => a.rel.localeCompare(b.rel));
  return out;
}

async function loadGitignore(dirAbs: string, base: string): Promise<IgnoreLayer | null> {
  try {
    const text = await fs.readFile(path.join(dirAbs, ".gitignore"), "utf8");
    const ig = createIgnorer();
    ig.add(text);
    return { base, ig };
  } catch {
    return null; // no .gitignore here — fine
  }
}

/** Whether any `.gitignore` on the way down to `rel` excludes it.
 *
 *  Every level counts, not just the indexed root: a folder that holds several projects is
 *  indexed from above them, and each project's own .gitignore is the only thing that knows
 *  its build output is not source. A deeper `!pattern` cannot re-include what a shallower
 *  file excludes — a simplification of git's precedence rules that only errs towards
 *  indexing less. */
function isIgnored(layers: IgnoreLayer[], rel: string, isDir: boolean): boolean {
  for (const { base, ig } of layers) {
    const sub = base ? rel.slice(base.length + 1) : rel;
    if (sub && ig.ignores(isDir ? sub + "/" : sub)) return true;
  }
  return false;
}

async function walk(
  dir: string,
  rootAbs: string,
  inherited: IgnoreLayer[],
  cfg: Config,
  out: DiscoveredFile[],
): Promise<void> {
  let entries: import("node:fs").Dirent[];
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  const here = await loadGitignore(dir, toPosix(path.relative(rootAbs, dir)));
  const layers = here ? [...inherited, here] : inherited;

  for (const entry of entries) {
    const abs = path.join(dir, entry.name);
    const rel = toPosix(path.relative(rootAbs, abs));
    if (!rel || rel.startsWith("..")) continue;

    if (entry.isSymbolicLink()) continue;

    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      if (isIgnored(layers, rel, true)) continue;
      await walk(abs, rootAbs, layers, cfg, out);
      continue;
    }
    if (!entry.isFile()) continue;
    if (isIgnored(layers, rel, false)) continue;

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
