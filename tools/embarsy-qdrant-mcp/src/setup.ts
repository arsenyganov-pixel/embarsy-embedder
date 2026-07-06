import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { Config } from "./config.js";

/**
 * The editor apps (Codex / Claude Code desktop) spawn MCP servers with a minimal PATH that
 * does NOT include nvm/homebrew bin dirs — so a bare `embarsy-mcp` command fails to launch.
 * We sidestep that entirely by writing ABSOLUTE paths: the current `node` binary + the
 * absolute path to this package's compiled mcp.js.
 */
function resolveSpawn(): { command: string; args: string[] } {
  const mcpJs = fileURLToPath(new URL("./bin/mcp.js", import.meta.url));
  return { command: process.execPath, args: [mcpJs] };
}

/** Env block written into the editor config so the server has everything it needs. */
function serverEnv(cfg: Config): Record<string, string> {
  return {
    OPENAI_BASE_URL: cfg.openaiBaseUrl,
    OPENAI_API_KEY: cfg.openaiApiKey,
    EMBEDDING_MODEL: cfg.embeddingModel,
    EMBEDDING_DIMENSION: String(cfg.embeddingDimension),
    QDRANT_URL: cfg.qdrantUrl,
    QDRANT_API_KEY: cfg.qdrantApiKey,
    QDRANT_COLLECTION_NAME: cfg.collection,
  };
}

const SERVER_NAME = "embarsy-qdrant";

/** Append an `[mcp_servers.embarsy-qdrant]` block to ~/.codex/config.toml (respects $CODEX_HOME). */
export async function setupCodex(cfg: Config): Promise<string> {
  const home = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  await fs.mkdir(home, { recursive: true });
  const file = path.join(home, "config.toml");
  const existing = await readOrEmpty(file);
  if (existing.includes(`[mcp_servers.${SERVER_NAME}]`)) {
    throw new Error(`~/.codex/config.toml already has [mcp_servers.${SERVER_NAME}]. Remove it first to re-run setup.`);
  }
  const { command, args } = resolveSpawn();
  const env = serverEnv(cfg);
  const lines = [
    "",
    `[mcp_servers.${SERVER_NAME}]`,
    `command = ${toml(command)}`,
    `args = [${args.map(toml).join(", ")}]`,
    "",
    `[mcp_servers.${SERVER_NAME}.env]`,
    ...Object.entries(env).map(([k, v]) => `${k} = ${toml(v)}`),
    "",
  ];
  const next = (existing.trimEnd() + "\n" + lines.join("\n")).replace(/^\n+/, "");
  await fs.writeFile(file, next, "utf8");
  return file;
}

/** Merge an `embarsy-qdrant` server into ./.mcp.json (project-scoped Claude Code config). */
export async function setupClaude(cfg: Config): Promise<string> {
  const file = path.resolve(".mcp.json");
  let json: any = {};
  const existing = await readOrEmpty(file);
  if (existing.trim()) {
    try { json = JSON.parse(existing); } catch { throw new Error(`${file} is not valid JSON — fix or remove it first.`); }
  }
  if (typeof json !== "object" || json === null) json = {};
  json.mcpServers = json.mcpServers ?? {};
  const { command, args } = resolveSpawn();
  json.mcpServers[SERVER_NAME] = { command, args, env: serverEnv(cfg) };
  await fs.writeFile(file, JSON.stringify(json, null, 2) + "\n", "utf8");
  return file;
}

async function readOrEmpty(file: string): Promise<string> {
  try { return await fs.readFile(file, "utf8"); } catch { return ""; }
}

/** Minimal TOML basic-string quoting (JSON escaping is a valid superset for our values). */
function toml(value: string): string {
  return JSON.stringify(value);
}
