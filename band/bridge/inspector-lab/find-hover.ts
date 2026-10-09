// find-hover.ts - locate the engine's hover dispatch from inside its realm.
//
// The mouse dispatcher in the bundle reads:
//
//   if (!_) n.lastHoverCol = m, n.lastHoverRow = y, n.props.onHoverAt(m, y)
//   ... n.props.onHoverLost?.()
//
// so the engine computes the hovered cell and hands it to a props callback.
// Those live inside module closures, not on globalThis, so the first job is
// to find WHERE. Debugger.searchInContent answers it without pausing.
//
// The bundle is CHUNKED: 1648 scripts parse, and the largest by line count is
// not the one with the renderer in it. So every script gets searched, in
// batches, rather than guessing which one matters.
const url = process.argv[2];
const query = process.argv[3] ?? "lastHoverCol";
const ws = new WebSocket(url);
let id = 0;
const pending = new Map<number, (v: any) => void>();
const scripts: { id: string; url: string }[] = [];

function send(method: string, params: any = {}): Promise<any> {
  const msgId = ++id;
  return new Promise((resolve) => {
    pending.set(msgId, resolve);
    ws.send(JSON.stringify({ id: msgId, method, params }));
  });
}

ws.onmessage = (e: any) => {
  const m = JSON.parse(String(e.data));
  if (m.id && pending.has(m.id)) {
    pending.get(m.id)!(m);
    pending.delete(m.id);
    return;
  }
  if (m.method === "Debugger.scriptParsed") {
    scripts.push({ id: m.params.scriptId, url: m.params.url || "(anon)" });
  }
};

ws.onopen = async () => {
  await send("Debugger.enable");
  await new Promise((r) => setTimeout(r, 3000));
  console.log(`scripts: ${scripts.length}; searching all for ${JSON.stringify(query)}`);

  const found: { id: string; url: string; line: number; text: string }[] = [];
  const BATCH = 60;
  for (let i = 0; i < scripts.length; i += BATCH) {
    const slice = scripts.slice(i, i + BATCH);
    const results = await Promise.all(
      slice.map((s) =>
        send("Debugger.searchInContent", {
          scriptId: s.id,
          query,
          caseSensitive: true,
          isRegex: false,
        }).then((r) => ({ s, hits: r?.result?.result ?? [] }))
      )
    );
    for (const { s, hits } of results) {
      for (const h of hits.slice(0, 2)) {
        found.push({
          id: s.id,
          url: s.url,
          line: h.lineNumber,
          text: String(h.lineContent ?? "").slice(0, 160),
        });
      }
    }
    if (found.length >= 6) break;
  }

  console.log(`hits: ${found.length}`);
  for (const f of found.slice(0, 6)) {
    console.log(`  script=${f.id} line=${f.line} ${f.url.slice(0, 60)}`);
    console.log(`    ${f.text}`);
  }
  process.exit(0);
};

ws.onerror = (e: any) => {
  console.log("socket error:", e?.message ?? String(e));
  process.exit(1);
};
setTimeout(() => { console.log("timed out"); process.exit(2); }, 110000);
