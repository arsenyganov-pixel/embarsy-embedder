// Drives the MCP stdio server: initialize → tools/list → call search_code. Keys come from env.
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dir = path.dirname(fileURLToPath(import.meta.url));
const child = spawn("node", [path.join(dir, "dist/bin/mcp.js")], {
  env: { ...process.env },
  stdio: ["pipe", "pipe", "inherit"],
});

let buf = "";
child.stdout.on("data", (d) => (buf += d.toString()));

const send = (m) => child.stdin.write(JSON.stringify(m) + "\n");
send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "t", version: "0" } } });
send({ jsonrpc: "2.0", method: "notifications/initialized" });
send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "search_code", arguments: { query: "deterministic point id from a stable key", limit: 2 } } });

setTimeout(() => {
  for (const line of buf.split("\n")) {
    if (!line.trim()) continue;
    let m;
    try { m = JSON.parse(line); } catch { continue; }
    if (m.id === 2) console.log("tools/list →", m.result.tools.map((t) => t.name).join(", "));
    if (m.id === 3) {
      const txt = m.result?.content?.[0]?.text ?? JSON.stringify(m.error);
      console.log("search_code →\n  " + txt.split("\n").slice(0, 3).join("\n  "));
    }
  }
  child.kill();
  process.exit(0);
}, 8000);
