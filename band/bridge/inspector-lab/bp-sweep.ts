// bp-sweep.ts - which column in the mouse handler actually fires?
//
// setBreakpoint MOVES the location to the next statement boundary it can
// use (8098 became 8116), and that landing spot may not be on the path a
// hover takes. Rather than guess one column at a time, plant several across
// the handler, each reporting its own label, and see which ones report.
const inspectorUrl = process.argv[2];
const teePort = Number(process.argv[3] ?? 39820);

// Columns from locate.ts, each named for what sits there.
const SITES: [number, string][] = [
  [7783, "test-lastHoverCol"],
  [7910, "onHoverLost"],
  [8060, "before-onHoverAt"],
  [8098, "onHoverAt"],
  [8185, "onPointerHover"],
];

const got = new Set<string>();
Bun.serve({
  port: teePort,
  fetch(req: any, server: any) {
    if (server.upgrade(req)) return;
    return new Response("sweep");
  },
  websocket: {
    open() { console.log("engine connected"); },
    message(_ws: any, msg: any) {
      const s = String(msg);
      if (!got.has(s)) console.log("  FIRED:", s);
      got.add(s);
    },
  },
});

const ws = new WebSocket(inspectorUrl);
let id = 0;
const pending = new Map<number, (v: any) => void>();
const send = (method: string, params: any = {}) => {
  const msgId = ++id;
  return new Promise<any>((res) => {
    pending.set(msgId, res);
    ws.send(JSON.stringify({ id: msgId, method, params }));
  });
};

ws.onmessage = (e: any) => {
  const m = JSON.parse(String(e.data));
  if (m.id && pending.has(m.id)) { pending.get(m.id)!(m); pending.delete(m.id); return; }
  if (m.method === "Debugger.paused") {
    console.log("PAUSED (a condition threw) at",
      JSON.stringify(m.params?.callFrames?.[0]?.location));
    send("Debugger.resume");
  }
};

ws.onopen = async () => {
  await send("Runtime.enable");
  await send("Debugger.enable");
  await send("Runtime.evaluate", {
    expression: `(() => {
      const s = new WebSocket("ws://127.0.0.1:${teePort}/");
      globalThis.__nfTee = s;
      globalThis.__nfMark = (t) => { try { if (s.readyState === 1) s.send(t); } catch {} };
      return "ok";
    })()`,
    returnByValue: true,
  });
  for (const [col, label] of SITES) {
    const r = await send("Debugger.setBreakpoint", {
      location: { scriptId: "466", lineNumber: 33, columnNumber: col },
      // Label only: no reference to minified locals, so it cannot throw for
      // the wrong reason while we are still asking "does this fire at all".
      options: { condition: `(globalThis.__nfMark("${label}"), false)` },
    });
    const a = r?.result?.actualLocation;
    console.log(`  ${label.padEnd(20)} asked ${col} -> got ${a ? a.columnNumber : "REJECTED"}`);
  }
  console.log("\nplanted; inject motion now");
};

setTimeout(() => {
  console.log(`\nsites that fired: ${got.size ? [...got].join(", ") : "NONE"}`);
  process.exit(got.size ? 0 : 3);
}, 40000);
