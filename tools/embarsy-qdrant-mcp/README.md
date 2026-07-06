# embarsy-qdrant-mcp

Codebase-indexing MCP server for **[Embarsy](https://github.com/arsenyganov-pixel/embarsy-embedder)** — semantic code search for Claude Code and Codex, backed by a local Qdrant + OpenAI-compatible embeddings stack.

It indexes a directory of source into Qdrant and exposes a `search_code` MCP tool. Everything runs through Embarsy's proxy on `localhost:8000`, so the API keys are honored and both the embedding **and** Qdrant counters move in Embarsy → Monitoring. Pure JS — no native build.

## Install

```bash
npm install -g embarsy-qdrant-mcp
```

Provides two commands: `embarsy-index` (index a codebase) and `embarsy-mcp` (the MCP server + config helpers).

## Configuration

Set via environment variables. Only the two API keys are required — everything else defaults to Embarsy.

| Variable | Default | Notes |
|---|---|---|
| `OPENAI_API_KEY` | — | **required** — Embarsy → Status → API Key |
| `QDRANT_API_KEY` | — | **required** — Embarsy → Status → Qdrant API Key |
| `QDRANT_COLLECTION_NAME` | `embarsy-<dir>` | collection name (or `--collection`) |
| `OPENAI_BASE_URL` | `http://localhost:8000/v1` | OpenAI-compatible embeddings endpoint |
| `EMBEDDING_MODEL` | `qwen3-embedding` | |
| `EMBEDDING_DIMENSION` | `1024` | must match the model |
| `QDRANT_URL` | `http://localhost:8000/qdrant` | Qdrant REST (Embarsy proxy) |

## Index a codebase

```bash
OPENAI_API_KEY=<API Key> QDRANT_API_KEY=<Qdrant API Key> \
  embarsy-index ~/projects/my-app --collection my-app
```

Re-run any time — it's incremental (unchanged files are skipped, deleted files are pruned), respects `.gitignore`, and skips vendored/binary/oversized files.

## Wire it into your editor

The setup helpers write the config with **absolute** `node` + script paths, so the desktop apps (which don't inherit your shell `PATH`) can always launch the server.

**Codex** — appends to `~/.codex/config.toml`:

```bash
OPENAI_API_KEY=<API Key> QDRANT_API_KEY=<Qdrant API Key> \
QDRANT_COLLECTION_NAME=my-app embarsy-mcp --setup-codex
```

Restart Codex, run `/mcp` → `embarsy-qdrant` appears.

**Claude Code** — run in your project folder (writes `.mcp.json`):

```bash
OPENAI_API_KEY=<API Key> QDRANT_API_KEY=<Qdrant API Key> \
QDRANT_COLLECTION_NAME=my-app embarsy-mcp --setup-claude
```

## MCP tools

- **`search_code`** — semantic search; returns the most relevant chunks with `file:line` and a snippet.
- **`index_status`** — how many chunks are indexed in the collection.

## License

PolyForm Strict 1.0.0 — see the Embarsy repository.
