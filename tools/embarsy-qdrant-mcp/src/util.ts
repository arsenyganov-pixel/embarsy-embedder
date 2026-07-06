import { createHash } from "node:crypto";

export function sha256(input: string): string {
  return createHash("sha256").update(input, "utf8").digest("hex");
}

/**
 * Deterministic Qdrant point ID (UUID string) from a stable key, so re-indexing a chunk
 * overwrites its previous point instead of piling up duplicates.
 */
export function pointId(key: string): string {
  const h = createHash("md5").update(key, "utf8").digest("hex"); // 32 hex chars
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}

export function languageForExtension(ext: string): string {
  const map: Record<string, string> = {
    ts: "TypeScript", tsx: "TypeScript", js: "JavaScript", jsx: "JavaScript", mjs: "JavaScript", cjs: "JavaScript",
    py: "Python", rb: "Ruby", go: "Go", rs: "Rust", java: "Java", kt: "Kotlin", swift: "Swift",
    c: "C", h: "C", cc: "C++", cpp: "C++", hpp: "C++", cs: "C#", php: "PHP", scala: "Scala",
    sh: "Shell", bash: "Shell", zsh: "Shell", sql: "SQL", md: "Markdown", mdx: "Markdown",
    json: "JSON", yaml: "YAML", yml: "YAML", toml: "TOML", html: "HTML", css: "CSS", scss: "CSS",
    vue: "Vue", svelte: "Svelte", lua: "Lua", ex: "Elixir", exs: "Elixir", dart: "Dart", r: "R",
  };
  return map[ext.toLowerCase()] ?? (ext ? ext.toUpperCase() : "Text");
}
