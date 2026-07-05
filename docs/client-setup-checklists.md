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

Claude Code doesn't search your code on its own — we'll add a small bridge plugin (MCP) that pulls the embeddings and the vector store from Embarsy.

1. Install the bridge:

   ```bash
   npm install -g @kindash/qdrant-mcp-server
   ```

2. Index the project once (substitute your own path and the **Qdrant API Key** from Embarsy):

   ```bash
   OPENAI_BASE_URL=http://localhost:8000/v1 \
   OPENAI_API_KEY=<API Key from Embarsy> \
   EMBEDDING_MODEL=qwen3-embedding \
   QDRANT_URL=http://localhost:8000/qdrant \
   QDRANT_API_KEY=<Qdrant API Key from Embarsy> \
   QDRANT_COLLECTION_NAME=cc-my-app \
   qdrant-indexer ~/projects/my-app
   ```

3. Connect the bridge to Claude Code:

   ```bash
   claude mcp add embarsy-qdrant \
     -e OPENAI_BASE_URL=http://localhost:8000/v1 \
     -e OPENAI_API_KEY=<API Key from Embarsy> \
     -e EMBEDDING_MODEL=qwen3-embedding \
     -e QDRANT_URL=http://localhost:8000/qdrant \
     -e QDRANT_API_KEY=<Qdrant API Key from Embarsy> \
     -- qdrant-mcp --collection cc-my-app
   ```

4. Check it: ask Claude about your code — for example, "where is authorization handled?". It will find the relevant files, and the counters in Embarsy → **Monitoring** will start moving.

> Both `OPENAI_API_KEY` and the **Qdrant API Key** come from Embarsy → **Status** (the connection block). Copy the current values — they change after a Hard Reset.

---

## 2. Codex

Same as Claude Code, but the bridge goes into Codex's config file. If the project is already indexed in section 1, you don't need to re-index it.

1. Connect the bridge (substitute the **Qdrant API Key** from Embarsy):

   ```bash
   codex mcp add embarsy-qdrant \
     --env OPENAI_BASE_URL=http://localhost:8000/v1 \
     --env OPENAI_API_KEY=<API Key from Embarsy> \
     --env EMBEDDING_MODEL=qwen3-embedding \
     --env QDRANT_URL=http://localhost:8000/qdrant \
     --env QDRANT_API_KEY=<Qdrant API Key from Embarsy> \
     -- qdrant-mcp --collection cc-my-app
   ```

   Or write the same thing by hand into `~/.codex/config.toml`:

   ```toml
   [mcp_servers.embarsy-qdrant]
   command = "qdrant-mcp"
   args = ["--collection", "cc-my-app"]

   [mcp_servers.embarsy-qdrant.env]
   OPENAI_BASE_URL = "http://localhost:8000/v1"
   OPENAI_API_KEY = "<API Key from Embarsy>"
   EMBEDDING_MODEL = "qwen3-embedding"
   QDRANT_URL = "http://localhost:8000/qdrant"
   QDRANT_API_KEY = "<Qdrant API Key from Embarsy>"
   ```

2. Launch Codex and type `/mcp` — `embarsy-qdrant` should appear in the list.
3. Ask about your code — Codex will find the files, and the counters in Embarsy → **Monitoring** will move.

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
