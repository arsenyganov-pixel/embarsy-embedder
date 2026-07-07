/** Small fetch wrapper: retries transient failures and surfaces the response body in errors. */
export async function requestJSON(
  url: string,
  init: RequestInit,
  opts: { retries?: number; label?: string } = {},
): Promise<any> {
  const retries = opts.retries ?? 2;
  const label = opts.label ?? init.method ?? "request";
  let lastErr: unknown;
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      const res = await fetch(url, init);
      const text = await res.text();
      if (!res.ok) {
        // 4xx are not retryable (bad key / bad request) — fail fast with the server's message.
        const detail = text.slice(0, 500);
        const err = new Error(`${label} → HTTP ${res.status} at ${url}\n${detail}`);
        if (res.status >= 400 && res.status < 500) throw err;
        lastErr = err;
      } else {
        return text ? JSON.parse(text) : {};
      }
    } catch (e) {
      lastErr = e;
      // Don't retry explicit 4xx errors we threw above.
      if (e instanceof Error && /HTTP 4\d\d/.test(e.message)) throw e;
    }
    if (attempt < retries) await sleep(Math.min(5000, 400 * 2 ** attempt)); // exp backoff, capped 5s
  }
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
