# Embarsy — turn on semantic code search in your editor

## Before you start (once)

1. Open **Embarsy** and click **Install and Start**. Wait until every status line turns green.
2. The Embarsy window has a connection block with two keys — **API Key** and **Qdrant API Key**. Copy them from there; you'll need them below. (After a **Hard Reset** the keys change — just copy the new ones.)

The other values are always the same and don't need changing:

- Embeddings: `http://localhost:8000`
- Model: `qwen3-embedding`, dimension `1024`
- Qdrant: `http://localhost:8000/qdrant`

---

## 1. Claude Code

Claude Code doesn't search your code on its own — Embarsy's bridge (`embarsy-qdrant-mcp`) indexes your project into Qdrant and exposes it to Claude Code over MCP.

1. Install the bridge:

   ```bash
   npm install -g embarsy-qdrant-mcp
   ```

2. Index the project once (substitute your own path and the keys from Embarsy):

   ```bash
   OPENAI_API_KEY=<API Key from Embarsy> \
   QDRANT_API_KEY=<Qdrant API Key from Embarsy> \
   embarsy-index ~/projects/my-app --collection cc-my-app
   ```

3. Connect it to Claude Code — run this **in your project folder** (it writes `.mcp.json` with absolute paths):

   ```bash
   OPENAI_API_KEY=<API Key from Embarsy> \
   QDRANT_API_KEY=<Qdrant API Key from Embarsy> \
   QDRANT_COLLECTION_NAME=cc-my-app \
   embarsy-mcp --setup-claude
   ```

4. Check it: ask Claude about your code — for example, "where is authorization handled?". It will find the relevant files, and the counters in Embarsy → **Monitoring** will start moving.

> Both API keys come from Embarsy → **Status** (the connection block). Copy the current values — they change after a Hard Reset. The bridge defaults to Embarsy's proxy (`http://localhost:8000`) and `qwen3-embedding` / `1024`, so only the two keys are needed.

---

## 2. Codex

Same bridge as Claude Code, registered with Codex. If the project is already indexed in section 1, skip step 2.

1. Install the bridge (skip if you already did it for Claude Code):

   ```bash
   npm install -g embarsy-qdrant-mcp
   ```

2. Index the project once:

   ```bash
   OPENAI_API_KEY=<API Key from Embarsy> \
   QDRANT_API_KEY=<Qdrant API Key from Embarsy> \
   embarsy-index ~/projects/my-app --collection cc-my-app
   ```

3. Register it with Codex — this writes `~/.codex/config.toml` with **absolute** `node` + script paths, so the Codex desktop app (which doesn't inherit your shell `PATH`) can always launch it:

   ```bash
   OPENAI_API_KEY=<API Key from Embarsy> \
   QDRANT_API_KEY=<Qdrant API Key from Embarsy> \
   QDRANT_COLLECTION_NAME=cc-my-app \
   embarsy-mcp --setup-codex
   ```

4. Restart Codex and type `/mcp` — `embarsy-qdrant` should appear in the list.
5. Ask about your code — Codex will find the files, and the counters in Embarsy → **Monitoring** will move.

---

## 3. Zoo Code / Roo Code

The simplest option: search is built in, no bridge needed.

1. Open the project in VSCode.
2. In the Zoo/Roo chat, click the **Codebase Indexing** icon at the bottom right.
3. Fill the fields with the values from Embarsy:

   | Field | Value |
   |---|---|
   | Embedder Provider | `OpenAI Compatible` |
   | Base URL | `http://localhost:8000` |
   | API Key | **API Key** from Embarsy (leave empty if it's empty there) |
   | Model | `qwen3-embedding` |
   | Embedding Dimension | `1024` |
   | Qdrant URL | `http://localhost:8000/qdrant` |
   | Qdrant API Key | **Qdrant API Key** from Embarsy |
   | Search Score Threshold | `0.4` |
   | Maximum Search Results | `50` |

4. Click **Save**, then **Start Indexing**, and wait for the green status.
5. Done — ask about your code in plain language. You'll see the counters in Embarsy → **Monitoring**.

If you changed the model or the dimension, click **Clear Index Data** in Roo and start indexing again (Embarsy must be running). If that doesn't help, use Embarsy → **Status** → **Clear Roo Index**.

---

## If something goes wrong

- **Search finds nothing / a dimension error.** The dimension must be `1024`. Recreate the collection (in Zoo/Roo — **Clear Index Data**) and start again.
- **401 / access denied.** Copy the fresh **API Key** and **Qdrant API Key** from Embarsy — they change after a Hard Reset.
- **Monitoring shows all zeros.** The client must talk to `http://localhost:8000/qdrant`, not directly to `:6333`.
- **Nothing starts up.** Make sure every status line in Embarsy is green (the **Install and Start** button).
