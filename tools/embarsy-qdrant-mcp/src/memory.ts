import { execFile } from "node:child_process";
import { existsSync, promises as fs, readFileSync, realpathSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import type { Config } from "./config.js";
import { chunkFile } from "./chunker.js";
import { embedBatch, embedOne } from "./embeddings.js";
import { deleteByFilePath, ensureCollection, scrollFileHashes, search, stampCollection, upsertPoints, type SearchHit } from "./qdrant.js";
import { pointId, sha256 } from "./util.js";

/** The memory base: one folder of markdown shared by every agent (docs/memory-spec.md §5).
 *
 *  The bridge finds it through a small pointer file the Embarsy app writes, not through the
 *  editor's config — so moving or recreating the base never needs agents reconnected.
 *  EMBARSY_MEMORY_DIR overrides it, for terminal use and tests. */

/** EMBARSY_MEMORY_COLLECTION exists for tests, so they never touch the real index. */
export const MEMORY_COLLECTION = process.env.EMBARSY_MEMORY_COLLECTION?.trim() || "embarsy-memory";

/** Folders recall never reads: service files, history, and what is not memory yet (inbox)
 *  or not any more (archive). */
const SKIP = new Set([".git", ".embarsy", "inbox", "archive", "node_modules", ".obsidian"]);

const AGENT_FOLDERS = ["claude", "codex", "roo", "manual"] as const;
export type AgentFolder = (typeof AGENT_FOLDERS)[number];

export function pointerFile(): string {
  return path.join(os.homedir(), "Library", "Application Support", "Embarsy", "memory.json");
}

/** The base's folder, or null when none is set up (or the one recorded is gone). */
export function locateVault(): string | null {
  const fromEnv = process.env.EMBARSY_MEMORY_DIR?.trim();
  let candidate = fromEnv || null;
  if (!candidate) {
    try {
      candidate = JSON.parse(readFileSync(pointerFile(), "utf8"))?.vault ?? null;
    } catch {
      candidate = null;
    }
  }
  if (!candidate) return null;
  const resolved = path.resolve(candidate.replace(/^~(?=$|\/)/, os.homedir()));
  return existsSync(path.join(resolved, "memory.yaml")) ? resolved : null;
}

/** Which inbox folder a proposal goes to: what Embarsy's Connect wrote into the editor's
 *  config, else what the editor called itself in the MCP handshake. */
export function agentFolder(clientName?: string): AgentFolder {
  const hint = `${process.env.EMBARSY_CLIENT ?? ""} ${clientName ?? ""}`.toLowerCase();
  if (hint.includes("claude")) return "claude";
  if (hint.includes("codex")) return "codex";
  if (hint.includes("roo") || hint.includes("zoo") || hint.includes("cline")) return "roo";
  return "manual";
}

// MARK: - Notes

interface Frontmatter {
  [key: string]: string;
}

/** Flat `key: value` frontmatter — all recall needs from a note. */
export function parseFrontmatter(text: string): { fields: Frontmatter; body: string; bodyStartLine: number } {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  if (lines[0]?.trim() !== "---") return { fields: {}, body: text, bodyStartLine: 1 };
  const end = lines.findIndex((l, i) => i > 0 && l.trim() === "---");
  if (end < 0) return { fields: {}, body: text, bodyStartLine: 1 };
  const fields: Frontmatter = {};
  for (const line of lines.slice(1, end)) {
    const m = /^([A-Za-z0-9_.-]+):\s*(.*)$/.exec(line);
    if (!m) continue;
    let value = m[2]!.trim();
    if (value.startsWith('"')) {
      try { value = JSON.parse(value); } catch { /* keep as written */ }
    } else if (value.startsWith("'") && value.endsWith("'")) {
      value = value.slice(1, -1);
    }
    fields[m[1]!] = value;
  }
  return { fields, body: lines.slice(end + 1).join("\n"), bodyStartLine: end + 2 };
}

export async function listNotes(vault: string): Promise<string[]> {
  const out: string[] = [];
  const walk = async (dir: string): Promise<void> => {
    let entries: import("node:fs").Dirent[];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (e.name.startsWith(".")) continue;
      const abs = path.join(dir, e.name);
      const rel = path.relative(vault, abs).split(path.sep).join("/");
      let isDir = e.isDirectory();
      let isFile = e.isFile();
      if (e.isSymbolicLink()) {
        try {
          const st = await fs.stat(abs);
          isDir = st.isDirectory();
          isFile = st.isFile();
        } catch {
          continue;
        }
      }
      if (isDir) {
        // inbox/ and archive/ are skipped only at the top: a note may well have a folder
        // called "archive" inside knowledge/.
        if (SKIP.has(e.name) && !rel.includes("/")) continue;
        await walk(abs);
      } else if (isFile && e.name.toLowerCase().endsWith(".md") && rel !== "AGENTS.md") {
        // AGENTS.md is assembled from core/*.md, which is indexed — reading both would answer twice.
        out.push(rel);
      }
    }
  };
  await walk(vault);
  return out.sort();
}

export interface MemoryChunk {
  heading: string;
  startLine: number;
  endLine: number;
  text: string;
}

/** Markdown split at headings (# to ###), each piece carrying the headings above it, so a
 *  hit says where in the note it sits. Long sections are windowed like code. */
export function chunkMarkdown(body: string, firstLine: number, cfg: Config): MemoryChunk[] {
  const lines = body.split("\n");
  const sections: { trail: string[]; start: number; lines: string[] }[] = [];
  const trail: string[] = [];
  let current = { trail: [] as string[], start: firstLine, lines: [] as string[] };
  lines.forEach((line, i) => {
    const m = /^(#{1,3})\s+(.*)$/.exec(line);
    if (m) {
      // A heading with nothing under it yet (e.g. "# Title" right before "## Part") is not a
      // passage of its own; it only extends the trail of what follows.
      const hasContent = current.lines.some((l) => l.trim() && !/^#{1,6}\s/.test(l));
      if (hasContent) sections.push(current);
      const level = m[1]!.length;
      trail.splice(level - 1);
      trail[level - 1] = m[2]!.trim();
      current = { trail: trail.filter(Boolean), start: firstLine + i, lines: [line] };
    } else {
      current.lines.push(line);
    }
  });
  if (current.lines.some((l) => l.trim() && !/^#{1,6}\s/.test(l))) sections.push(current);

  const out: MemoryChunk[] = [];
  for (const s of sections) {
    const text = s.lines.join("\n");
    for (const c of chunkFile(text, cfg)) {
      out.push({
        heading: s.trail.join(" › "),
        startLine: s.start + c.startLine - 1,
        endLine: s.start + c.endLine - 1,
        text: c.text,
      });
    }
  }
  return out;
}

// MARK: - Index

let lastFreshen = 0;
let freshening: Promise<FreshenResult> | null = null;

export interface FreshenResult {
  notes: number;
  updated: number;
  removed: number;
}

/** Brings the index up to date with the base: re-embeds changed notes, drops deleted ones.
 *  Called before each recall, at most every `minIntervalMs`; the base is small, so an
 *  unchanged one costs a directory walk and one hash listing. */
export async function freshen(vault: string, cfg: Config, minIntervalMs = 15_000): Promise<FreshenResult | null> {
  if (freshening) return freshening;
  if (Date.now() - lastFreshen < minIntervalMs) return null;
  freshening = (async () => {
    try {
      const mcfg = { ...cfg, collection: MEMORY_COLLECTION };
      await ensureCollection(mcfg);
      const notes = await listNotes(vault);
      const existing = await scrollFileHashes(mcfg);
      const result: FreshenResult = { notes: notes.length, updated: 0, removed: 0 };
      const seen = new Set<string>();
      let pending: { key: string; text: string; payload: Record<string, unknown> }[] = [];
      const flush = async () => {
        if (pending.length === 0) return;
        const vectors = await embedBatch(pending.map((p) => p.text), mcfg);
        await upsertPoints(mcfg, pending.map((p, i) => ({ id: pointId(p.key), vector: vectors[i]!, payload: p.payload })));
        pending = [];
      };

      for (const rel of notes) {
        seen.add(rel);
        let content: string;
        try {
          content = await fs.readFile(path.join(vault, rel), "utf8");
        } catch {
          continue;
        }
        const hash = sha256(content);
        if (existing.get(rel) === hash) continue;
        if (existing.has(rel)) await deleteByFilePath(mcfg, rel);

        const { fields, body, bodyStartLine } = parseFrontmatter(content);
        const section = rel.split("/")[0] ?? "";
        const title = fields.title || fields.name || path.basename(rel, ".md");
        const lead = fields.description ? `${fields.description}\n\n` : "";
        const before = pending.length;
        chunkMarkdown(lead + body, bodyStartLine, mcfg).map((c) => {
          // A note's own "# Title" heading repeats its title; keep the trail to what's below it.
          const parts = c.heading ? c.heading.split(" › ") : [];
          if (parts[0] === title) parts.shift();
          return { ...c, heading: parts.join(" › ") };
        }).forEach((c, idx) => {
          pending.push({
            key: `memory:${rel}:${idx}`,
            text: `${rel}\n${title}${c.heading ? ` › ${c.heading}` : ""}\n\n${c.text}`,
            payload: {
              file_path: rel,
              file_hash: hash,
              chunk_index: idx,
              section,
              note_type: fields.type || (rel.endsWith("SKILL.md") ? "skill" : section),
              title,
              heading: c.heading,
              verified_at: fields.verified_at || "",
              start_line: c.startLine,
              end_line: c.endLine,
              text: c.text.length > 4000 ? c.text.slice(0, 4000) : c.text,
            },
          });
        });
        // A note with no text yields no passages; it isn't "indexed", just seen.
        if (pending.length > before) result.updated++;
        if (pending.length >= mcfg.embedBatch) await flush();
      }
      await flush();
      for (const rel of existing.keys()) {
        if (!seen.has(rel)) {
          await deleteByFilePath(mcfg, rel);
          result.removed++;
        }
      }
      // Named and dated for Embarsy's screens. No workspace_path on purpose: the memory is not
      // a project folder, and search_code must never pick it as the index for one.
      if (notes.length > 0) {
        await stampCollection(mcfg, { workspace: "Memory", memory: true, indexed_at: Math.floor(Date.now() / 1000) });
      }
      lastFreshen = Date.now();
      return result;
    } finally {
      freshening = null;
    }
  })();
  return freshening;
}

/** Below this a hit is flagged as weak. Lower than search_code's 0.52: notes are short prose,
 *  often Russian, and score lower than code does. Measured on a small base — relevant
 *  passages scored 0.49-0.69, unrelated queries (a recipe) 0.28-0.29. A heuristic: it only
 *  adds a caveat, never withholds results. */
const WEAK_SCORE = 0.4;

export async function recall(vault: string, cfg: Config, query: string, limit: number, types?: string[]): Promise<string> {
  const mcfg = { ...cfg, collection: MEMORY_COLLECTION };
  await freshen(vault, cfg);
  const vector = await embedOne(query, mcfg);
  const raw: SearchHit[] = await search(mcfg, vector, types?.length ? limit * 4 : limit * 2);
  const hits = raw
    .filter((h) => !types?.length || types.includes(String(h.payload?.section)) || types.includes(String(h.payload?.note_type)))
    .slice(0, limit);
  if (hits.length === 0) {
    return `Nothing in the memory base matches this. The base is ${vault}; inbox/ (proposals not yet reviewed) isn't searched.`;
  }
  const best = hits[0]!.score;
  const header =
    `${hits.length} ${hits.length === 1 ? "match" : "matches"} in the memory base (${vault}). ` +
    "Paths are relative to it; open a note to read it whole." +
    (best < WEAK_SCORE
      ? `\n\n⚠︎ Weak matches (best ${best.toFixed(2)}) — the base probably doesn't know this. Say so rather than guessing.`
      : "");
  const body = hits.map((h, i) => {
    const p = h.payload ?? {};
    const where = `${p.file_path}:${p.start_line}-${p.end_line}`;
    const meta = [p.note_type, p.verified_at ? `verified ${p.verified_at}` : ""].filter(Boolean).join(", ");
    const title = `${p.title}${p.heading ? ` › ${p.heading}` : ""}`;
    return `### ${i + 1}. ${title}\n${where}${meta ? ` · ${meta}` : ""} · score ${h.score.toFixed(3)}\n\n${String(p.text ?? "").trim()}`;
  });
  return `${header}\n\n${body.join("\n\n")}`;
}

// MARK: - Remember

export const SECRET_PATTERNS: [string, RegExp][] = [
  ["GitHub token", /(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}/],
  ["GitLab token", /glpat-[A-Za-z0-9_\-]{20,}/],
  ["Anthropic key", /sk-ant-[A-Za-z0-9_\-]{30,}/],
  ["OpenAI key", /sk-(proj-)?[A-Za-z0-9]{32,}/],
  ["AWS access key", /AKIA[0-9A-Z]{16}/],
  ["Slack token", /xox[abpr]-[A-Za-z0-9-]{10,}/],
  ["private key", /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
];

export interface Proposal {
  text: string;
  title?: string;
  proposedType?: string;
  proposedPath?: string;
  mergeWith?: string[];
  reason: string;
  confidence?: string;
}

const PROPOSED_TYPES = new Set(["knowledge", "experience", "person", "core"]);
const CONFIDENCE = new Set(["stated", "observed", "inferred"]);

function slugify(s: string): string {
  const slug = s
    .toLowerCase()
    .normalize("NFC")
    .replace(/[^\p{Letter}\p{Number}]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48)
    .replace(/-+$/, "");
  return slug || "note";
}

const q = (v: string) => JSON.stringify(v);

/** Writes a proposal to inbox/<agent>/. Never anywhere else: what becomes memory is the
 *  user's call, made in Embarsy. */
export async function remember(vault: string, agent: AgentFolder, p: Proposal, now = new Date()): Promise<string> {
  const text = p.text.trim();
  if (!text) throw new Error("text is empty — write the fact itself.");
  if (text.length > 4000) throw new Error("text is over 4000 characters. Propose one fact per call; split longer material.");
  for (const [kind, re] of SECRET_PATTERNS) {
    if (re.test(text) || re.test(p.reason ?? "")) {
      throw new Error(`This looks like it contains a ${kind}. Secrets never go into memory — remove it and try again.`);
    }
  }
  const pad = (n: number) => String(n).padStart(2, "0");
  const stamp = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}T${pad(now.getHours())}:${pad(now.getMinutes())}`;
  const fileStamp = stamp.replace("T", "-").replace(":", "");
  const title = (p.title ?? "").trim() || text.split("\n")[0]!.slice(0, 80);
  const folder = path.join(vault, "inbox", agent);
  await fs.mkdir(folder, { recursive: true });

  let name = `${fileStamp}-${slugify(title)}.md`;
  for (let n = 2; existsSync(path.join(folder, name)); n++) name = `${fileStamp}-${slugify(title)}-${n}.md`;

  const lines = ["---", "type: inbox", `title: ${q(title)}`, `created: ${stamp}`, `agent: ${agent}`];
  const proposedType = p.proposedType && PROPOSED_TYPES.has(p.proposedType) ? p.proposedType : "knowledge";
  lines.push(`proposed_type: ${proposedType}`);
  if (p.proposedPath?.trim()) lines.push(`proposed_path: ${q(p.proposedPath.trim())}`);
  if (p.mergeWith?.length) lines.push(`merge_with: ${q(p.mergeWith.join(", "))}`);
  lines.push(`reason: ${q((p.reason ?? "").trim())}`);
  lines.push(`confidence: ${p.confidence && CONFIDENCE.has(p.confidence) ? p.confidence : "inferred"}`);
  lines.push("---", "", text, "");
  const file = path.join(folder, name);
  await fs.writeFile(file, lines.join("\n"), { encoding: "utf8", flag: "wx" });
  return path.relative(vault, file).split(path.sep).join("/");
}

// MARK: - Status

export async function status(vault: string): Promise<string> {
  const notes = await listNotes(vault);
  const bySection = new Map<string, number>();
  for (const rel of notes) {
    const section = rel.split("/")[0] ?? "";
    bySection.set(section, (bySection.get(section) ?? 0) + 1);
  }
  const inbox: string[] = [];
  for (const agent of AGENT_FOLDERS) {
    try {
      const files = (await fs.readdir(path.join(vault, "inbox", agent))).filter((f) => f.endsWith(".md") && f !== "MEMORY.md");
      if (files.length) inbox.push(`${agent} ${files.length}`);
    } catch { /* no folder yet */ }
  }
  const sections = [...bySection.entries()].map(([s, n]) => `${s || "(root)"} ${n}`).join(", ");
  return [
    `Memory base: ${vault}`,
    `Notes: ${notes.length} (${sections || "none"})`,
    `Inbox waiting for review: ${inbox.length ? inbox.join(", ") : "empty"}`,
    `Core instructions: ${path.join(vault, "AGENTS.md")}`,
  ].join("\n");
}

// MARK: - History

const execFileAsync = promisify(execFile);
const GIT_CANDIDATES = [
  "/Library/Developer/CommandLineTools/usr/bin/git",
  "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
  "/opt/homebrew/bin/git",
  "/usr/local/bin/git",
];

/** A git that runs without the system prompting to install developer tools — which a bare
 *  /usr/bin/git does on a Mac without them. */
function gitBinary(): string | null {
  return GIT_CANDIDATES.find((g) => existsSync(g)) ?? null;
}

/** The note's path inside the base, refusing anything outside it. */
export function insideVault(vault: string, p: string): string {
  const abs = path.resolve(vault, p);
  const rel = path.relative(vault, abs);
  if (rel.startsWith("..") || path.isAbsolute(rel)) throw new Error(`${p} is outside the memory base (${vault}).`);
  return rel.split(path.sep).join("/");
}

interface Commit {
  hash: string;
  date: string;
  subject: string;
  trailers: Record<string, string>;
}

function parseTrailers(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of body.split("\n")) {
    const m = /^([A-Za-z-]+):\s*(.+)$/.exec(line.trim());
    if (m) out[m[1]!] = m[2]!;
  }
  return out;
}

export async function history(vault: string, file: string, limit: number, lines: boolean): Promise<string> {
  const git = gitBinary();
  if (!git || !existsSync(path.join(vault, ".git"))) {
    return "This memory base has no history (git isn't available on this Mac, or history was never started).";
  }
  const rel = insideVault(vault, file);
  const run = (args: string[]) => execFileAsync(git, ["-C", vault, "-c", "core.quotepath=false", ...args], { maxBuffer: 8 * 1024 * 1024 });

  const { stdout } = await run(["log", `-n${limit}`, "--date=iso-strict", "--format=%H%x1f%ad%x1f%s%x1f%b%x1e", "--", rel]);
  const commits: Commit[] = stdout.split("\x1e").map((r) => r.trim()).filter(Boolean).map((r) => {
    const [hash = "", date = "", subject = "", body = ""] = r.split("\x1f");
    return { hash, date, subject, trailers: parseTrailers(body) };
  });
  if (commits.length === 0) return `${rel} has no recorded history yet — it hasn't been committed since it was created.`;

  const who = (c: Commit) => {
    const parts = [c.trailers["Agent"] ? `agent: ${c.trailers["Agent"]}` : "", c.trailers["Approved-by"] ? `approved by ${c.trailers["Approved-by"]}` : "", c.trailers["Source"] ? `source: ${c.trailers["Source"]}` : ""];
    return parts.filter(Boolean).join(", ");
  };
  const out = [`History of ${rel} (newest first):`, ...commits.map((c) => `- ${c.date.slice(0, 16).replace("T", " ")} ${c.hash.slice(0, 7)} ${c.subject}${who(c) ? ` (${who(c)})` : ""}`)];

  if (lines && existsSync(path.join(vault, rel))) {
    const { stdout: blame } = await run(["blame", "--line-porcelain", "--", rel]);
    const ranges: { hash: string; from: number; to: number }[] = [];
    let hash = "";
    let lineNo = 0;
    for (const l of blame.split("\n")) {
      const head = /^([0-9a-f]{40}) \d+ (\d+)/.exec(l);
      if (head) {
        hash = head[1]!;
        lineNo = Number(head[2]);
        const last = ranges[ranges.length - 1];
        if (last && last.hash === hash && last.to === lineNo - 1) last.to = lineNo;
        else ranges.push({ hash, from: lineNo, to: lineNo });
      }
    }
    const subjects = new Map(commits.map((c) => [c.hash, c]));
    out.push("", "Who wrote which lines:");
    for (const r of ranges) {
      const c = subjects.get(r.hash);
      const label = r.hash.startsWith("0000000") ? "not committed yet" : c ? `${c.subject}${who(c) ? ` (${who(c)})` : ""}` : r.hash.slice(0, 7);
      out.push(`- lines ${r.from}${r.to > r.from ? `-${r.to}` : ""}: ${label}`);
    }
  }
  return out.join("\n");
}

// MARK: - Migration

/** The migration Embarsy is preparing, if any: its staging folder, from the same pointer file. */
export function locateMigration(): string | null {
  try {
    const dir = JSON.parse(readFileSync(pointerFile(), "utf8"))?.migration;
    return typeof dir === "string" && existsSync(path.join(dir, "TASK.md")) ? dir : null;
  } catch {
    return null;
  }
}

export async function migrationScan(staging: string): Promise<string> {
  const task = await fs.readFile(path.join(staging, "TASK.md"), "utf8");
  let inventory = "";
  try {
    inventory = await fs.readFile(path.join(staging, "inventory.md"), "utf8");
  } catch { /* the task points at it anyway */ }
  const cap = 60_000;
  return `${task}\n\n---\n\n${inventory.length > cap ? inventory.slice(0, cap) + `\n\n…(truncated — read ${path.join(staging, "inventory.md")} for the rest)` : inventory}`;
}

const NAME_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const NOTE_RE = /^(knowledge|experience|people)\/[^\0]+\.md$/;

/** Checks a migration plan and saves it for the user's review. Problems come back as a list
 *  for the agent to fix; nothing is saved until there are none that block reading it. */
export async function migrationPropose(staging: string, plan: unknown): Promise<string> {
  if (!plan || typeof plan !== "object" || Array.isArray(plan)) throw new Error("The plan must be a JSON object (see the plan format in TASK.md).");
  const p = plan as Record<string, any>;
  const problems: string[] = [];
  const text = JSON.stringify(plan);
  for (const [kind, re] of SECRET_PATTERNS) {
    if (re.test(text)) problems.push(`The plan contains what looks like a ${kind}. Leave secrets out entirely.`);
  }
  const skills: any[] = Array.isArray(p.skills) ? p.skills : [];
  const notes: any[] = Array.isArray(p.notes) ? p.notes : [];

  // Only what the user chose to bring in may be referenced — the same rule Embarsy applies.
  let roots: string[] = [path.join(staging, "experience"), path.join(staging, "proposed")];
  try {
    const state = JSON.parse(await fs.readFile(path.join(staging, "migration.json"), "utf8"));
    roots = roots.concat((state.sources ?? []).map((s: any) => String(s.path)));
  } catch { /* without the state file, Embarsy's own check still applies */ }
  const real = (p: string) => { try { return realpathSync(p); } catch { return path.resolve(p); } };
  const inside = (p: string) => roots.some((r) => {
    const a = path.resolve(p), b = path.resolve(r), ra = real(p), rb = real(r);
    return a === b || a.startsWith(b + path.sep) || ra === rb || ra.startsWith(rb + path.sep);
  });
  for (const item of [...skills, ...notes]) {
    if (item?.from && !inside(String(item.from))) problems.push(`"${item.name ?? item.path}": ${item.from} is outside the folders the user chose to bring in.`);
  }
  for (const s of skills) {
    if (typeof s?.name !== "string" || !NAME_RE.test(s.name) || s.name.length > 64) problems.push(`Skill "${s?.name}": name must be lowercase letters, digits and single hyphens.`);
    if (s?.from && !existsSync(path.join(String(s.from), "SKILL.md"))) problems.push(`Skill "${s.name}": ${s.from} has no SKILL.md.`);
    if (!s?.from && !String(s?.skill_md ?? "").trim()) problems.push(`Skill "${s?.name}": give either "from" or "skill_md".`);
    if (s?.origin && !["own", "adopted", "vendor"].includes(s.origin)) problems.push(`Skill "${s.name}": origin must be own, adopted or vendor.`);
  }
  for (const n of notes) {
    if (typeof n?.path !== "string" || !NOTE_RE.test(n.path) || n.path.includes("..")) problems.push(`Note "${n?.path}": path must be a .md file inside knowledge/, experience/ or people/.`);
    if (n?.from && !existsSync(String(n.from))) problems.push(`Note "${n.path}": ${n.from} doesn't exist.`);
    if (!n?.from && !n?.content_file && !String(n?.content ?? "").trim()) problems.push(`Note "${n?.path}": give "from", "content" or "content_file".`);
  }
  const choices = new Set([...skills, ...notes].map((i) => i?.choice).filter(Boolean));
  const asked = new Set((Array.isArray(p.questions) ? p.questions : []).map((q: any) => q?.choice));
  for (const c of choices) if (!asked.has(c)) problems.push(`Choice "${c}" has no question in "questions".`);
  if (problems.length) {
    return `Not saved — fix these and call memory_propose again:\n- ${problems.join("\n- ")}`;
  }
  const core = p.core ?? {};
  const coreSize = JSON.stringify(core).length;
  await fs.writeFile(path.join(staging, "plan.json"), JSON.stringify({ version: 1, ...p }, null, 2), "utf8");
  return [
    `Saved. ${skills.length} skills, ${notes.length} notes, ${Array.isArray(p.skip) ? p.skip.length : 0} skipped, ${choices.size} choices for the user.`,
    coreSize > 4500 ? "Note: the core is long; every agent loads it in every session — consider moving detail into notes." : "",
    "Tell the user the plan is ready to review in Embarsy → Memory.",
  ].filter(Boolean).join("\n");
}
