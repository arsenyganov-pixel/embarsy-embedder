# embarsy-qdrant-mcp

Codebase-indexing MCP server for **[Embarsy](https://github.com/arsenyganov-pixel/embarsy-embedder)** — semantic code search for Claude Code and Codex, backed by a local Qdrant + OpenAI-compatible embeddings stack.

It indexes a directory of source into Qdrant and exposes a `search_code` MCP tool. Everything runs through Embarsy's proxy on `localhost:8000`, so the API keys are honored and both the embedding **and** Qdrant counters move in Embarsy → Monitoring. Pure JS — no native build.

> Using the Embarsy app? You don't need this package: the bridge ships inside Embarsy 0.2.3+, and
> **Connections → Connect** wires up Claude Code and Codex for you. This package is for working from
> the terminal.

## Install

```bash
npm install -g embarsy-qdrant-mcp
```

Provides two commands: `embarsy-index` (index a codebase) and `embarsy-mcp` (the MCP server + config helpers).

## Configuration

Set via environment variables. Only the two API keys are required — everything else defaults to Embarsy.

| Variable | Default | Notes |
|---|---|---|
| `OPENAI_API_KEY` | — | **required** — Embarsy → Connections → Zoo / Roo Code → API Key |
| `QDRANT_API_KEY` | — | **required** — Embarsy → Connections → Zoo / Roo Code → Qdrant API Key |
| `QDRANT_COLLECTION_NAME` | see notes | indexing: `embarsy-<dir>` (or `--collection`). Search: when unset, the index covering the editor's folder is picked automatically |
| `OPENAI_BASE_URL` | `http://localhost:8000/v1` | OpenAI-compatible embeddings endpoint |
| `EMBEDDING_MODEL` | `qwen3-embedding` | |
| `EMBEDDING_DIMENSION` | `1024` | must match the model |
| `QDRANT_URL` | `http://localhost:8000/qdrant` | Qdrant REST (Embarsy proxy) |

## Index a codebase

```bash
OPENAI_API_KEY=<API Key> QDRANT_API_KEY=<Qdrant API Key> \
  embarsy-index ~/projects/my-app --collection my-app
```

Re-run any time — it's incremental (unchanged files are skipped, deleted files are pruned), respects every `.gitignore` in the tree (so a folder holding several projects honours each project's own), and skips vendored/binary/oversized files and build output.

## Wire it into your editor

The setup helpers write the config with **absolute** `node` + script paths, so the desktop apps (which don't inherit your shell `PATH`) can always launch the server.

**Codex** — appends to `~/.codex/config.toml`:

```bash
OPENAI_API_KEY=<API Key> QDRANT_API_KEY=<Qdrant API Key> embarsy-mcp --setup-codex
```

Restart Codex, run `/mcp` → `embarsy-qdrant` appears.

**Claude Code** — writes `~/.claude.json`, so it works in every indexed folder (add `--project` to write a
`.mcp.json` in the current folder instead):

```bash
OPENAI_API_KEY=<API Key> QDRANT_API_KEY=<Qdrant API Key> embarsy-mcp --setup-claude
```

One registration serves every indexed project: the server picks the index from the folder the editor
is working in. Set `QDRANT_COLLECTION_NAME` only to pin one collection everywhere.

## MCP tools

- **`search_code`** — semantic search; returns the most relevant chunks with `file:line` and a snippet. When the index covers a parent of the editor's folder (say `~/code` while you work in `~/code/my-app`), it searches `my-app/` first and widens to the whole index only if nothing there is convincing; `whole_index: true` searches everything from the start. Paths come back relative to the editor's folder, or absolute when outside it.
- **`index_status`** — how many chunks are indexed in the collection.

## License

**[PolyForm Strict 1.0.0](LICENSE)** — source-available, **not** open source: noncommercial use
only, no redistribution or modification without a separate written license. The full text ships with
this package (`LICENSE`). Commercial or modification license → **arsenyganov@gmail.com**.
