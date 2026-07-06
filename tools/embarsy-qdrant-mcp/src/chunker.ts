import type { Config } from "./config.js";

export interface Chunk {
  startLine: number; // 1-based, inclusive
  endLine: number;   // 1-based, inclusive
  text: string;
}

/**
 * Line-oriented chunking with a character budget and overlap. Chunks prefer to start at a
 * "definition-ish" line (function/class/etc.) when the current chunk is already sizeable, so
 * chunks tend to align with logical code boundaries. Pure-JS, no native parser.
 */
const BOUNDARY = /^\s*(export\s+)?(async\s+)?(function|class|struct|enum|interface|trait|impl|def|func|fn|type|module|namespace|public|private|protected|static)\b/;

export function chunkFile(content: string, cfg: Config): Chunk[] {
  const lines = content.split(/\r?\n/);
  const chunks: Chunk[] = [];
  const maxChars = Math.max(400, cfg.chunkMaxChars);
  const overlapChars = Math.max(0, Math.min(cfg.chunkOverlapChars, maxChars - 100));

  let startIdx = 0; // 0-based line index where the current chunk starts
  let curChars = 0;
  let i = 0;

  const flush = (endIdxExclusive: number) => {
    if (endIdxExclusive <= startIdx) return;
    const slice = lines.slice(startIdx, endIdxExclusive);
    const text = slice.join("\n").trim();
    if (text.length > 0) {
      chunks.push({ startLine: startIdx + 1, endLine: endIdxExclusive, text: slice.join("\n") });
    }
  };

  while (i < lines.length) {
    const line = lines[i] ?? "";
    const lineChars = line.length + 1;

    // Break BEFORE a definition line if the current chunk already has real content.
    if (i > startIdx && curChars >= maxChars * 0.5 && BOUNDARY.test(line)) {
      flush(i);
      startIdx = backfillOverlap(lines, i, overlapChars);
      curChars = charsBetween(lines, startIdx, i);
    }

    curChars += lineChars;
    i++;

    if (curChars >= maxChars) {
      flush(i);
      startIdx = backfillOverlap(lines, i, overlapChars);
      curChars = charsBetween(lines, startIdx, i);
    }
  }
  flush(lines.length);
  return chunks;
}

/** Walk back from `idx` to include ~overlapChars of trailing context; returns new start index. */
function backfillOverlap(lines: string[], idx: number, overlapChars: number): number {
  if (overlapChars <= 0) return idx;
  let chars = 0;
  let j = idx;
  while (j > 0 && chars < overlapChars) {
    j--;
    chars += (lines[j]?.length ?? 0) + 1;
  }
  return j;
}

function charsBetween(lines: string[], from: number, to: number): number {
  let c = 0;
  for (let k = from; k < to; k++) c += (lines[k]?.length ?? 0) + 1;
  return c;
}
