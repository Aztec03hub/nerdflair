// probe-client.ts - can we execute code inside the running engine?
//
// Bun's inspector speaks the WebKit protocol over a WebSocket. If
// Runtime.evaluate comes back with an answer, we have arbitrary execution in
// Claude Code's own JS realm, which is what the hover tee needs: find the
// renderer's hover dispatch, wrap it, post to our socket, detach.
const url = process.argv[2];
const ws = new WebSocket(url);
let id = 0;
const pending = new Map<number, (v: any) => void>();

function send(method: string, params: any = {}): Promise<any> {
  const msgId = ++id;
  return new Promise((resolve) => {
    pending.set(msgId, resolve);
    ws.send(JSON.stringify({ id: msgId, method, params }));
  });
}

ws.onopen = async () => {
  console.log("connected to", url);
  await send("Runtime.enable");
  const r = await send("Runtime.evaluate", {
    expression: "({ v: process.version, argv0: process.argv[0], " +
      "keys: Object.keys(globalThis).length })",
    returnByValue: true,
  });
  console.log("evaluate ->", JSON.stringify(r?.result?.result?.value ?? r));
  process.exit(0);
};

ws.onmessage = (e: any) => {
  const m = JSON.parse(String(e.data));
  if (m.id && pending.has(m.id)) {
    pending.get(m.id)!(m);
    pending.delete(m.id);
  }
};

ws.onerror = (e: any) => {
  console.log("socket error:", e?.message ?? String(e));
  process.exit(1);
};

setTimeout(() => {
  console.log("timed out with no reply");
  process.exit(2);
}, 8000);
