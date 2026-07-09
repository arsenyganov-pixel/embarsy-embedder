import type { Config } from "./config.js";

export interface Chunk {
  startLine: number; // 1-based, inclusive
  endLine: number;   // 1-based, inclusive
  text: string;
}

/**
 * Character-window chunking with a HARD size cap, so no single chunk can ever exceed the
 * embedding model's context — not even a minified/bundled file that is one enormous line.
 *
 * Windows prefer to end at a newline (cleaner code boundaries), but a line longer than the cap
 * is split by character count instead of being embedded whole. The old line-based chunker sent
 * a one-line 800 KB JSON as a single chunk, which tokenised past 32k and crashed llama-server.
 */
export function chunkFile(content: string, cfg: Config): Chunk[] {
  const maxChars = Math.max(400, cfg.chunkMaxChars);
  const overlap = Math.max(0, Math.min(cfg.chunkOverlapChars, Math.floor(maxChars / 2)));
  if (content.trim().length === 0) return [];

  // Line-start offsets → 1-based line number for any character offset (binary search).
  const lineStarts: number[] = [0];
  for (let i = 0; i < content.length; i++) {
    if (content.charCodeAt(i) === 10 /* \n */) lineStarts.push(i + 1);
  }
  const lineAt = (offset: number): number => {
    let lo = 0, hi = lineStarts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid]! <= offset) lo = mid; else hi = mid - 1;
    }
    return lo + 1;
  };

  const chunks: Chunk[] = [];
  let pos = 0;
  while (pos < content.length) {
    let end = Math.min(content.length, pos + maxChars);
    if (end < content.length) {
      // Snap to the last newline in the back half of the window for a tidy cut; a window with
      // no newline (one giant line) falls through and is hard-cut at maxChars.
      const nl = content.lastIndexOf("\n", end);
      if (nl > pos + Math.floor(maxChars / 2)) end = nl;
    }
    end = snapToCodePoint(content, end);
    const text = content.slice(pos, end);
    if (text.trim().length > 0) {
      chunks.push({ startLine: lineAt(pos), endLine: lineAt(Math.max(pos, end - 1)), text });
    }
    if (end >= content.length) break;
    pos = snapToCodePoint(content, Math.max(pos + 1, end - overlap));
  }
  return chunks;
}

/** A boundary that lands between the two halves of a surrogate pair would cut an emoji
 *  in half; the resulting lone surrogate is invalid Unicode that embedding backends
 *  reject (Python's UTF-8 encoder raises on it, turning the request into a 500).
 *  If the index points at a low surrogate, step back one unit to keep the pair whole. */
function snapToCodePoint(s: string, index: number): number {
  if (index > 0 && index < s.length) {
    const code = s.charCodeAt(index);
    if (code >= 0xdc00 && code <= 0xdfff) return index - 1;
  }
  return index;
}
