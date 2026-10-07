import { existsSync } from "node:fs";
import path from "node:path";
import { physical } from "./resolve-collection.js";

/** Narrowing a search to the folder the agent is working in.
 *
 *  One index often covers more than the agent's project: indexing a folder that holds
 *  several projects is the easy way to cover them all, and collection resolution then hands
 *  that one index to an editor opened in any of them. Searching all of it from inside one
 *  project lets a larger sibling crowd out the answer — so a search starts in the agent's
 *  own folder, and only widens when that folder has nothing convincing. */

const toPosix = (p: string) => p.split(path.sep).join("/");

const isInside = (dir: string, root: string): boolean =>
  dir === root || dir.startsWith(root.endsWith(path.sep) ? root : root + path.sep);

/** The folder this collection's `file_path`s are relative to, or null when it cannot be
 *  established.
 *
 *  `index_root` says so exactly; collections indexed before it existed only carry
 *  `workspace_path`, which is the same folder unless a source container (`myproj/src`) was
 *  indexed. Returned as a physical path, to compare with the editor's working directory.
 *  Either candidate is trusted only if the sampled file is really there — a wrong
 *  root would scope searches to nothing and point the agent at files that do not exist,
 *  while no root simply keeps the old whole-index behaviour. */
export function establishRoot(
  sample: { indexRoot: string; workspacePath: string; filePath: string } | null,
  exists: (p: string) => boolean = existsSync,
): string | null {
  if (!sample || !sample.filePath) return null;
  for (const candidate of [sample.indexRoot, sample.workspacePath]) {
    if (candidate && path.isAbsolute(candidate) && exists(path.join(candidate, sample.filePath))) {
      return physical(candidate);
    }
  }
  return null;
}

/** `file_path` prefix ("proxiq-macos/") selecting what lies under `cwd`, or null when the
 *  agent works at the index root (nothing to narrow) or outside it (nothing to narrow to). */
export function scopePrefix(root: string | null, cwd: string): string | null {
  if (!root) return null;
  const here = physical(cwd);
  if (here === root || !isInside(here, root)) return null;
  return toPosix(path.relative(root, here)) + "/";
}

/** A hit's path as the agent should use it: relative to its own working directory when the
 *  file is under it, absolute otherwise. The stored path is relative to the index root,
 *  which is a different folder whenever the index covers more than the agent's project —
 *  handed over unchanged, it names a file that does not exist from where the agent stands. */
export function displayPath(filePath: string, root: string | null, cwd: string): string {
  if (!root) return filePath;
  const here = physical(cwd);
  if (here === root) return filePath;
  const abs = path.join(root, filePath);
  return isInside(abs, here) ? toPosix(path.relative(here, abs)) : abs;
}
