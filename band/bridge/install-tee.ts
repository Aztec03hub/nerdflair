#!/usr/bin/env bun
// install-tee.ts - put the hover tee inside the engine. Nothing else.
//
// Split out from the lab's stdin-tee.ts, which also RAN a server to catch
// the events. That is fine for an experiment and wrong in the product: the
// bridge owns that socket, and two listeners on one port means whichever
// starts second dies. This installs and exits; the engine then talks to the
// bridge directly.
//
//   install-tee.ts <inspector-ws-url> <bridge-port>
const inspectorUrl = process.argv[2];
const bridgePort = Number(process.argv[3]);

if (!inspectorUrl || !bridgePort) {
  console.error("usage: install-tee.ts ws://127.0.0.1:PORT/claude BRIDGE_PORT");
  process.exit(2);
}

const ws = new WebSocket(inspectorUrl);
let id = 0;
const pending = new Map<number, (v: any) => void>();
const send = (method: string, params: any = {}) =>
  new Promise<any>((res) => {
    const msgId = ++id;
    pending.set(msgId, res);
    ws.send(JSON.stringify({ id: msgId, method, params }));
  });

ws.onmessage = (e: any) => {
  const m = JSON.parse(String(e.data));
  if (m.id && pending.has(m.id)) { pending.get(m.id)!(m); pending.delete(m.id); }
};

// Reconnects itself: the bridge may restart (a new layout, a crash, a
// resize) while the engine runs for hours, and a dead socket would silently
// stop the hover for the rest of the session.
const INSTALL = `
(() => {
  try {
    if (globalThis.__nfTeeInstalled) return "already installed";
    let sock = null;
    const connect = () => {
      try {
        sock = new WebSocket("ws://127.0.0.1:${bridgePort}/");
        sock.addEventListener("close", () => { sock = null; setTimeout(connect, 1000); });
        sock.addEventListener("error", () => { try { sock.close() } catch {} });
      } catch { setTimeout(connect, 1000); }
    };
    connect();
    globalThis.__nfReconnect = connect;

    const RE = /\\x1b\\[<(\\d+);(\\d+);(\\d+)([Mm])/g;
    globalThis.__nfFeed = (chunk) => {
      try {
        if (!sock || sock.readyState !== 1) return;
        const str = typeof chunk === "string" ? chunk : chunk.toString("latin1");
        if (str.indexOf("[<") < 0) return;
        RE.lastIndex = 0;
        let m, last = null;
        while ((m = RE.exec(str)) !== null) last = m;
        if (!last) return;
        sock.send(JSON.stringify({
          t: "ptr", btn: +last[1], col: +last[2], row: +last[3],
          release: last[4] === "m",
        }));
      } catch {}
    };

    // A TEE, not a filter: the chunk is returned exactly as received, so the
    // engine's own input handling is unchanged.
    const st = process.stdin;
    const orig = st.read;
    st.read = function () {
      const c = orig.apply(this, arguments);
      if (c) globalThis.__nfFeed(c);
      return c;
    };
    globalThis.__nfTeeInstalled = true;
    return "installed";
  } catch (e) { return "error: " + e.message; }
})()`;

ws.onopen = async () => {
  await send("Runtime.enable");
  const r = await send("Runtime.evaluate", { expression: INSTALL, returnByValue: true });
  const v = r?.result?.result?.value;
  console.log("tee:", v);
  process.exit(String(v).startsWith("error") ? 1 : 0);
};
ws.onerror = (e: any) => { console.error("inspector:", e?.message); process.exit(1); };
setTimeout(() => { console.error("timed out attaching"); process.exit(3); }, 20000);
