import { realpathSync } from "node:fs";
import path from "node:path";
import type { Config } from "./config.js";
import { listCollections, workspacePathOf } from "./qdrant.js";

/** Pick the indexed collection that covers the directory the editor is working in.
 *
 *  Without this, one server registration means one hard-coded collection — so a single
 *  machine-wide config can only ever serve one project, and anyone who registers per project
 *  runs into Claude Code's per-directory approval instead. Resolving at query time makes a
 *  single registration correct everywhere: the editor asks from a directory, and the index
 *  that actually covers that directory answers.
 *
 *  Only collections written by this bridge can be matched — they carry `workspace_path`.
 *  A collection some other tool indexed has no folder recorded in it, and guessing one from
 *  file paths would be a guess, so those are simply not candidates.
 */
export interface ResolvedCollection {
  name: string;
  /** Why this one — surfaced to the agent so a surprising answer is explainable. */
  reason: string;
}

/** The physical path, so one folder reached two ways still matches itself: macOS hands the
 *  app `/tmp/x` (and any symlinked project) while an editor's working directory is the real
 *  `/private/tmp/x`. A path that cannot be resolved (gone from disk) is compared as written. */
export const physical = (p: string): string => {
  try {
    return realpathSync(p);
  } catch {
    return path.resolve(p);
  }
};

const isInside = (dir: string, root: string): boolean =>
  dir === root || dir.startsWith(root.endsWith(path.sep) ? root : root + path.sep);

export async function resolveCollection(cfg: Config, cwd: string): Promise<ResolvedCollection> {
  if (cfg.collection) {
    return { name: cfg.collection, reason: "set explicitly by QDRANT_COLLECTION_NAME" };
  }

  const here = physical(cwd);
  const names = await listCollections(cfg);
  const rooted = (
    await Promise.all(
      names.map(async (name) => ({ name, root: await workspacePathOf(cfg, name) })),
    )
  ).filter((c): c is { name: string; root: string } => Boolean(c.root));

  // Longest matching root wins: indexing a sub-project separately is a deliberate act, and
  // the narrower index is the one its owner meant to be used there.
  const matches = rooted
    .map((c) => ({ ...c, real: physical(c.root) }))
    .filter((c) => isInside(here, c.real))
    .sort((a, b) => b.real.length - a.real.length);

  if (matches.length === 0) {
    const known = rooted.length
      ? ` Indexed folders: ${rooted.map((c) => c.root).join(", ")}.`
      : " No folder-tagged collections exist yet.";
    throw new Error(
      `No indexed collection covers ${here}.${known}\n` +
        // Most people never see a terminal for this: Embarsy indexes from its own window.
        `Index it in Embarsy → Connections → Add folder…, or run: embarsy-index ${here}`,
    );
  }

  const best = matches[0]!;
  return {
    name: best.name,
    reason: matches.length > 1
      ? `covers ${best.root} (closest of ${matches.length} matching folders)`
      : `covers ${best.root}`,
  };
}
