# Changelog

All notable changes to Embarsy are documented here. This project follows [Semantic Versioning](https://semver.org).

## 0.1.1 — beta (2026-07-06)

Download `Embarsy-0.1.1-arm64.dmg` from the release assets (see 0.1.0 below for full setup, requirements, and first-launch instructions).

### Fixed

- **Editor bridge** — the setup previously relied on `@kindash/qdrant-mcp-server`, which was removed from npm. Replaced with own published [`embarsy-qdrant-mcp`](https://www.npmjs.com/package/embarsy-qdrant-mcp), so the Claude Code / Codex steps in **How To** install cleanly again — with one-command `embarsy-mcp --setup-codex` / `--setup-claude`.
- **Start All** is now disabled while any service is running (avoids "Start All finished with status: Failed" when the stack is already up).

## 0.1.0 — beta (2026-07-06)

First public beta of **Embarsy** — a native macOS menu-bar app that runs a **local semantic code-index stack** (Qdrant + Ollama + a small FastAPI proxy), so your editor and AI clients can search code by meaning, fully offline.

### Highlights

- **One-click install** — sets up and manages the whole stack (Qdrant vector DB, Ollama embeddings, Embarsy API). No terminal needed.
- **Start / stop in one place** — bring the stack up or down from a button or the menu-bar icon.
- **Content view** — browse indexed Qdrant collections with file / language / area previews; slide to delete a collection.
- **Live monitoring** — reads/writes, embedding latency, and system resources (memory, CPU, temperature) with time-range and refresh controls.
- **Request activity** — inspect embedding / read / write events to see exactly what's being indexed.
- **Editor bridge** — [`embarsy-qdrant-mcp`](https://www.npmjs.com/package/embarsy-qdrant-mcp) indexes your codebase into Qdrant and serves an MCP `search_code` tool, with one-command setup for Claude Code and Codex (Zoo / Roo Code has built-in indexing). Everything routes through Embarsy's proxy, so both the embedding and Qdrant counters move.
- **Built-in setup guides** — How-To for Claude Code, Codex, and Zoo / Roo Code.

### Requirements

- macOS 13 (Ventura) or later
- Apple Silicon (arm64)

### Install

1. Download `Embarsy-0.1.0-arm64.dmg` from the release assets.
2. Open it and drag **Embarsy** into Applications.
3. **First launch** (self-signed beta): if macOS blocks it, open **System Settings → Privacy & Security**, scroll to the bottom and click **Open Anyway**, then launch again. If it says the app is "damaged", clear the download quarantine once and launch:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Embarsy.app
   ```

4. In Embarsy, open **Install → Install and Start**, then copy the connection values from **Status** into your editor's codebase-indexing settings.

### Known limitations

- Not signed with a Developer ID / not notarized yet — Gatekeeper needs a one-time approval (see Install step 3).
- Apple Silicon only — no Intel build.
- Memory / CPU / temperature history is kept in memory (~1h) and resets on relaunch.
