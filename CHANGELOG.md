# Changelog

All notable changes to Embarsy are documented here. This project follows [Semantic Versioning](https://semver.org).

## 0.2.0 — beta (2026-07-07)

Download `Embarsy-0.2.0-arm64.dmg` from the release assets (see 0.1.0 below for full setup, requirements, and first-launch instructions).

### Added
- **One-click API update on the Status screen.** After installing a new Embarsy version, the previous API process can still be serving on port 8000 — new features (like vector quantization) silently wouldn't apply. The app now compares the running API's version (`/health` reports it) with the one bundled in the app, and shows an **Update** button next to the API row that restarts only the API — Qdrant, Ollama, the model and all indexed data stay untouched. On its first start the updated API migrates existing collections to the quantized layout automatically.

### Fixed
- **Install no longer fails while the API is still warming up.** The final install step used to give the Embarsy API a hard 15-second health budget — but the API's very first start after a fresh install can spend ~20s just unpacking and validating itself, so installs failed moments before the API came up (and only a reboot seemed to help). The health wait now keeps waiting while the process is alive (up to 2 minutes for the API), fails fast with the real exit reason if the process dies, retries the API step once, and no longer claims "Components are not installed" when only the API step failed — Qdrant, Ollama and the model stay put.
- **Failure evidence survives.** If a service fails to start, its log tail and exit status are copied into the debug log automatically; the debug log is rotated (not overwritten) on every launch; and Remove Components archives the logs to `~/Library/Logs/Embarsy/` before deleting anything.
- **Service status self-corrects after start.** A service that was slow to pass its health check (usually the API loading its model) no longer stays stuck on "Failed" — the Status page and the menu-bar dropdown now re-check for a while after any start and flip to "Running" automatically, so you don't have to press Refresh.

### Performance
- **Monitoring is dramatically smoother.** Scrolling no longer hitches at large time ranges: refresh ticks only re-render the Monitoring tab (not the whole window), each chart skips re-layout when its data hasn't changed, client-side series are decimated peak-preservingly (up to 1800 points → ≤300), and chart JSON is decoded off the main thread. Same pixels, same refresh behavior.
- **Big battery savings on laptops.** The API no longer rewrites its multi-megabyte metrics state file up to once per second (now a background flush every 30s); service logs are rotated instead of growing unbounded (ollama.log could reach hundreds of MB per day); per-request access logging is off (the Activity screen still shows everything); HTTP connections to Qdrant/Ollama are pooled; Activity polls now fetch only new events; polling and decorative animations pause while the window can't be seen; system-metrics sampling slows to 15s when Monitoring isn't visible; and the embedding model unloads after 30 idle minutes instead of staying pinned in RAM.

### Changed
- **"What seems indexed" is human-readable now.** The Content column no longer opens with the raw collection id ("ws-… collection workspace: …") — it reads like a sentence: *"Looks like a PHP project: 224 files, mostly PHP and Markdown. Key areas: app, AppBundle and Maxposter."* Languages are ordered by how often they actually occur (not alphabetically), the project kind is inferred from the dominant code language, and the expanded preview no longer repeats the name twice.
- **New app icon.** The icon now follows the macOS icon grid (824px squircle on the 1024px canvas with standard margins) instead of filling the whole canvas, so it sits at the same visual size as other apps in Finder and the Dock — and the washed-out white background is replaced with the brand dark gradient and teal mark. Small sizes (16/32px) are rendered from vectors with a slightly heavier stroke so the mark stays legible in list views.
- **Optimal vector quantization by default.** Every collection created through the Embarsy proxy now gets int8 scalar quantization (quantile 0.99, always in RAM) with full-precision originals on disk — searches run on a 4x-smaller SIMD-accelerated copy and the top candidates are rescored against the originals, so quality is unchanged while RAM and disk I/O drop substantially. Existing unquantized collections are migrated automatically in the background (no re-indexing needed); the `embarsy-qdrant-mcp` bridge (0.1.2) creates its collections with the same layout.
- **How To** now includes an "Updating the bridge" section (Claude Code / Codex) — how to update the `embarsy-qdrant-mcp` bridge and re-index.
- Bridge `embarsy-qdrant-mcp` 0.1.1 (published separately on npm) fixes a crash when indexing minified / one-line files: character-bounded chunking, an embedding-input cap, resilient retries, and skipping minified blobs.

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
