/** How this process identifies itself to Embarsy, so Activity can say who made a request.
 *
 *  Claude Code and Codex both spawn this same binary, so nothing about the connection can
 *  tell them apart — the editor name is knowable only because `--setup-claude` /
 *  `--setup-codex` wrote it into the config they launch us with. When it is absent we say
 *  so plainly (the bridge, editor unknown) instead of guessing.
 */

export type ToolRole = "index" | "search";

let toolRole: ToolRole = "search";

/** Set once at startup by each bin: `embarsy-index` writes vectors, `embarsy-mcp` reads. */
export function setToolRole(role: ToolRole): void {
  toolRole = role;
}

export function clientHeaders(): Record<string, string> {
  const editor = (process.env.EMBARSY_CLIENT ?? "").trim();
  return {
    "X-Embarsy-Client": editor || "embarsy-qdrant-mcp",
    "X-Embarsy-Tool": toolRole,
  };
}
