# Roo Code setup for Embarsy

Use the **Codebase Indexing** popover in Roo Code.

| Field | Value |
|---|---|
| Embedder Provider | OpenAI Compatible |
| Base URL | `http://localhost:8000` |
| API Key | `EMBARSY_API_KEY` from Embarsy.app, or `.env` in dev mode, or empty if disabled |
| Model | `qwen3-embedding` |
| Embedding Dimension | `1024` |
| Qdrant URL | `http://localhost:6333` |
| Qdrant API Key | `QDRANT_API_KEY` from Embarsy.app, or `.env` in dev mode |
| Search Score Threshold | `0.4` |
| Maximum Search Results | `50` |

After saving, click **Start Indexing** and wait until Roo shows a green status.

Before using **Clear Index Data** in Roo Code, make sure Embarsy/Qdrant is running and Roo Code contains the current `QDRANT_API_KEY` from Embarsy.app. Roo Code deletes the workspace Qdrant collection through the configured Qdrant endpoint.

Embarsy supports both OpenAI-compatible embedding paths:

- `POST /v1/embeddings` for clients that append `/v1/embeddings` to the base URL.
- `POST /embeddings` for Roo Code builds that append `/embeddings` directly to the base URL.

Keep **Embedding Dimension** set to `1024`. If Roo was previously configured with another dimension, click **Clear Index Data** before starting indexing again. If Roo Code cannot run cleanup because Qdrant is unreachable, use Embarsy.app → Status → **Clear Roo Index** for the selected default project.

## Sanity checks

1. `curl http://127.0.0.1:8000/health` returns `dimension: 1024`.
2. `POST http://127.0.0.1:8000/v1/embeddings` and `POST http://127.0.0.1:8000/embeddings` both return vectors with length `1024`.
3. Qdrant dashboard opens at `http://127.0.0.1:6333/dashboard`.
4. Roo creates a collection with `size=1024` and `distance=Cosine`.
5. `points_count` grows during indexing.

## Dimension changes

If the embedding model or dimension changes later, use **Clear Index Data** in Roo before re-indexing. If the command fails with a Qdrant connection error, start Embarsy/Qdrant and retry. If Roo cleanup still does not start, use Embarsy.app → Status → **Clear Roo Index**.

## Embarsy fallback cleanup

Embarsy.app provides **Clear Roo Index** on the Status screen for broken-state scenarios where Roo Code cannot clear its own index. Select the same default project that is opened in VSCode, then click **Clear Roo Index**.

The fallback cleanup is scoped to the selected workspace path:

- deletes Qdrant collection `ws-<sha256(workspacePath)[0:16]>`;
- resets Roo local cache file `roo-index-cache-<sha256(workspacePath)>.json` in VSCode global storage;
- starts Qdrant first when Embarsy is installed but Qdrant is stopped;
- writes detailed events to `embarsy-debug.log` under category `roo-index`.
