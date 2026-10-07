import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import type { Config } from "./config.js";
import { embedOne } from "./embeddings.js";
import { search, collectionInfo, sampleLocation, type SearchHit } from "./qdrant.js";
import { resolveCollection } from "./resolve-collection.js";
import { establishRoot, scopePrefix, displayPath } from "./scope.js";

/** The published package version — read from package.json (which ships in the tarball)
 *  so the MCP handshake never drifts from the real release. */
const PKG_VERSION: string = (() => {
  // A single-file bundle has no package.json beside it, so the packaging step stamps the
  // version in at build time. Without this the MCP handshake reports 0.0.0 and nobody can
  // tell which bridge an editor is actually running.
  const stamped = process.env.EMBARSY_BRIDGE_VERSION;
  if (stamped) return stamped;
  try {
    const pkgPath = fileURLToPath(new URL("../package.json", import.meta.url));
    return JSON.parse(readFileSync(pkgPath, "utf8")).version ?? "0.0.0";
  } catch {
    return "0.0.0";
  }
})();

/** Server-level guidance, delivered to the agent in the MCP handshake.
 *
 *  The thing this has to overcome is a habit: an agent asked to find code reaches for grep,
 *  because grep is always there and always works. A tool description alone rarely moves that
 *  — it is read while choosing between tools, not while forming the plan. Server instructions
 *  arrive before the first decision, which is where the preference has to be set.
 *
 *  It deliberately also says when NOT to use the index. A tool that claims everything gets
 *  distrusted the first time it disappoints; one with an honest boundary keeps being used for
 *  the thing it is actually good at. */
const SERVER_INSTRUCTIONS = [
  "This project has a local semantic index of its own source code, served by Embarsy.",
  "",
  "Reach for `search_code` FIRST when the question is about meaning rather than spelling:",
  "where something is handled, what decides a behaviour, how a flow works, which file owns a",
  "concept. It matches intent, so it finds the right code even when the words in the question",
  "appear nowhere in it — and it answers with a few ranked snippets (file + line range)",
  "instead of thousands of matching lines to sift.",
  "",
  "Keep using grep / file search for what it is better at: an exact symbol, a literal string,",
  "a file name, or an exhaustive list of every occurrence.",
  "",
  "If `search_code` returns nothing useful, say so and fall back to grep — the index may not",
  "cover this folder, or may be stale until `embarsy-index` is run again.",
].join("\n");

/** Below this cosine score the hit is reported as weak rather than presented as an answer.
 *
 *  Measured, not guessed: 10 queries against a real 20k-chunk index of this workspace —
 *  5 about code that is actually in it scored 0.579-0.664, and 5 deliberately about
 *  something else entirely (recipes, train timetables, the weather) scored 0.393-0.476.
 *  Note how high that floor is: cosine similarity never approaches zero for unrelated text,
 *  which is exactly why a naive low threshold never fires. 0.52 sits in the 0.103-wide gap.
 *
 *  It is a heuristic over one model and one codebase, so it can misjudge either way —
 *  which is why a weak score only adds a caveat and never withholds the results. */
const WEAK_SCORE = 0.52;

/** Build and run the Embarsy MCP server over stdio (for Claude Code / Codex). */
export async function runMcpServer(baseCfg: Config): Promise<void> {
  // Resolved on first use, not at startup: the editor may spawn the server before Embarsy's
  // stack is reachable, and failing then would look like a broken integration rather than a
  // stack that is still coming up. Cached for the process — the working directory of an
  // editor session does not change under it.
  let resolved: { cfg: Config; reason: string; root: string | null } | null = null;
  const configured = async (): Promise<{ cfg: Config; reason: string; root: string | null }> => {
    if (!resolved) {
      const pick = await resolveCollection(baseCfg, process.cwd());
      const cfg = { ...baseCfg, collection: pick.name };
      resolved = { cfg, reason: pick.reason, root: establishRoot(await sampleLocation(cfg)) };
    }
    return resolved;
  };
  const server = new McpServer(
    { name: "embarsy-qdrant", version: PKG_VERSION },
    { instructions: SERVER_INSTRUCTIONS },
  );

  server.tool(
    "search_code",
    "Find code by MEANING across this project's semantic index. Prefer this over grep for " +
      "questions like 'where is X handled', 'what decides Y', 'how does Z flow' — it matches " +
      "intent rather than literal words, and returns a few ranked snippets with file and line " +
      "range instead of thousands of matching lines. Use grep instead when you already know the " +
      "exact symbol, string or file name, or need every occurrence. When the index covers more " +
      "than the folder you are working in, it searches your folder first and widens to the " +
      "whole index only when your folder has nothing convincing.",
    {
      query: z.string().describe("Natural-language description of the code you are looking for."),
      limit: z.number().int().min(1).max(50).optional().describe("Max results (default 8)."),
      path_contains: z.string().optional().describe("Only return chunks whose file path contains this substring."),
      whole_index: z.boolean().optional().describe(
        "Search the entire index even when it covers more than your working folder " +
          "(default false: your folder first, widening only when it has nothing convincing).",
      ),
    },
    async ({ query, limit, path_contains, whole_index }) => {
      const { cfg, reason, root } = await configured();
      const want = limit ?? 8;
      const vector = await embedOne(query, cfg);
      const cwd = process.cwd();
      const prefix = whole_index ? null : scopePrefix(root, cwd);

      const run = async (under: string | null): Promise<SearchHit[]> => {
        // Qdrant's `text` match on a field without a full-text index is a plain substring
        // match — it narrows the search server-side without listing the folder's files. A
        // substring can also hit mid-path ("x/proxiq-macos/…"), so the exact prefix is
        // re-checked here, over-fetching a little to make up for what that drops.
        const filter = under ? { must: [{ key: "file_path", match: { text: under } }] } : undefined;
        const fetch = (path_contains ? want * 6 : want) * (under ? 2 : 1);
        const raw = await search(cfg, vector, fetch, filter);
        return raw
          .filter((h) => {
            const fp = String(h.payload?.file_path ?? "");
            return (!under || fp.startsWith(under)) && (!path_contains || fp.includes(path_contains));
          })
          .slice(0, want);
      };

      let hits = await run(prefix);
      // Widen when the agent's folder has nothing convincing: it may not be indexed (new, or
      // excluded by a .gitignore), or the answer may live in a shared sibling. The wider
      // result is kept only if it is actually better — otherwise the folder's own weak
      // matches are the more honest answer.
      let widened = false;
      if (prefix && (hits.length === 0 || hits[0]!.score < WEAK_SCORE)) {
        const everywhere = await run(null);
        if (everywhere.length > 0 && (hits.length === 0 || everywhere[0]!.score > hits[0]!.score)) {
          hits = everywhere;
          widened = true;
        }
      }
      if (hits.length === 0) {
        return {
          content: [{
            type: "text",
            text:
              `No matches in "${cfg.collection}". This folder may not be indexed yet ` +
              "(run `embarsy-index <path>`), or the question may be about something the index " +
              "does not cover — grep is the better tool for an exact symbol or string.",
          }],
        };
      }

      const pathOf = (h: SearchHit) => displayPath(String(h.payload?.file_path ?? ""), root, cwd);
      const files = new Set(hits.map(pathOf));
      const where = !prefix
        ? ""
        : widened
          ? `\nNothing convincing under ${prefix} (your folder), so this searched the whole index at ${root}. ` +
            "Paths outside your folder are absolute."
          : `\nSearched ${prefix} only (your folder) — pass whole_index: true to search all of ${root}.`;
      const best = hits[0]!.score;
      // A tool that keeps claiming success teaches the agent to stop believing it. Saying
      // plainly when the match is weak — and naming the better tool — is what keeps the
      // strong answers trusted.
      const header =
        `${hits.length} ranked ${hits.length === 1 ? "match" : "matches"} across ` +
        `${files.size} ${files.size === 1 ? "file" : "files"} · semantic index ` +
        `"${cfg.collection}" (${reason})` +
        where +
        (best < WEAK_SCORE
          ? `\n\n⚠︎ Weak matches (best score ${best.toFixed(2)}). The index may not cover this ` +
            "area, or may be stale — re-run `embarsy-index`. For an exact symbol or string, grep " +
            "will be more reliable than this."
          : "");

      const body = hits
        .map((h, i) => {
          const p = h.payload ?? {};
          const loc = `${pathOf(h)}:${p.start_line}-${p.end_line}`;
          const lang = p.language ? ` [${p.language}]` : "";
          const snippet = String(p.text ?? "").trimEnd();
          return `### ${i + 1}. ${loc}${lang}  (score ${h.score.toFixed(3)})\n\n\`\`\`\n${snippet}\n\`\`\``;
        })
        .join("\n\n");
      return { content: [{ type: "text", text: `${header}\n\n${body}` }] };
    },
  );

  server.tool(
    "index_status",
    "Report how many chunks are indexed in the current collection.",
    {},
    async () => {
      const { cfg, reason } = await configured();
      const info = await collectionInfo(cfg);
      const text = info
        ? `Collection "${cfg.collection}" (${reason}): ${info.pointsCount} indexed chunks.`
        : `Collection "${cfg.collection}" does not exist yet. Run: embarsy-index <path> --collection ${cfg.collection}`;
      return { content: [{ type: "text", text }] };
    },
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);
}
