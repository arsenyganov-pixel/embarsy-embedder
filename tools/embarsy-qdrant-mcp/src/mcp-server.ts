import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import type { Config } from "./config.js";
import { embedOne } from "./embeddings.js";
import { search, collectionInfo } from "./qdrant.js";

/** The published package version — read from package.json (which ships in the tarball)
 *  so the MCP handshake never drifts from the real release. */
const PKG_VERSION: string = (() => {
  try {
    const pkgPath = fileURLToPath(new URL("../package.json", import.meta.url));
    return JSON.parse(readFileSync(pkgPath, "utf8")).version ?? "0.0.0";
  } catch {
    return "0.0.0";
  }
})();

/** Build and run the Embarsy MCP server over stdio (for Claude Code / Codex). */
export async function runMcpServer(cfg: Config): Promise<void> {
  const server = new McpServer({ name: "embarsy-qdrant", version: PKG_VERSION });

  server.tool(
    "search_code",
    "Semantic search over the indexed codebase. Returns the most relevant code chunks with " +
      "their file path and line range. Use natural language (e.g. 'where is auth handled').",
    {
      query: z.string().describe("Natural-language description of the code you are looking for."),
      limit: z.number().int().min(1).max(50).optional().describe("Max results (default 8)."),
      path_contains: z.string().optional().describe("Only return chunks whose file path contains this substring."),
    },
    async ({ query, limit, path_contains }) => {
      const want = limit ?? 8;
      const vector = await embedOne(query, cfg);
      // Over-fetch and filter by path client-side (substring match works regardless of index type).
      const raw = await search(cfg, vector, path_contains ? want * 6 : want);
      const hits = (path_contains
        ? raw.filter((h) => String(h.payload?.file_path ?? "").includes(path_contains))
        : raw
      ).slice(0, want);
      if (hits.length === 0) {
        return { content: [{ type: "text", text: "No matches. Has the codebase been indexed with `embarsy-index`?" }] };
      }
      const text = hits
        .map((h, i) => {
          const p = h.payload ?? {};
          const loc = `${p.file_path}:${p.start_line}-${p.end_line}`;
          const lang = p.language ? ` [${p.language}]` : "";
          const snippet = String(p.text ?? "").trimEnd();
          return `### ${i + 1}. ${loc}${lang}  (score ${h.score.toFixed(3)})\n\n\`\`\`\n${snippet}\n\`\`\``;
        })
        .join("\n\n");
      return { content: [{ type: "text", text }] };
    },
  );

  server.tool(
    "index_status",
    "Report how many chunks are indexed in the current collection.",
    {},
    async () => {
      const info = await collectionInfo(cfg);
      const text = info
        ? `Collection "${cfg.collection}": ${info.pointsCount} indexed chunks.`
        : `Collection "${cfg.collection}" does not exist yet. Run: embarsy-index <path> --collection ${cfg.collection}`;
      return { content: [{ type: "text", text }] };
    },
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);
}
