// hover-tee.ts - make Claude Code report its own hover, live.
//
// THE MECHANISM. A conditional breakpoint whose condition has a side effect
// and evaluates FALSE. JSC runs the condition in-process and, because it is
// false, never pauses and never notifies the debugger client. So the hover
// is teed with no client round-trip per mouse move: the only per-event cost
// is JSC evaluating a short expression.
//
// That is why this is a breakpoint rather than prototype surgery. The call
// site is `n.props.onHoverAt(m, y)`, and `props` is rebuilt whenever the
// component re-renders, so anything patched onto it would silently fall off.
// A breakpoint is attached to the CODE, which does not move.
//
// The engine opens a WebSocket back to this script, so hover events travel
// out of the process on their own connection rather than through the
// debugger protocol.
const inspectorUrl = process.argv[2];
const scriptId = process.argv[3] ?? "466";
const line = Number(process.argv[4] ?? 33);
const col = Number(process.argv[5] ?? 8098);
const teePort = Number(process.argv[6] ?? 39800);

// Where the engine will send its hover events.
const seen: string[] = [];
Bun.serve({
  port: teePort,
  fetch(req, server) {
    if (server.upgrade(req)) return;
    return new Response("nerdflair hover bridge");
  },
  websocket: {
    open() {
      console.log("engine connected to the hover bridge");
    },
    message(_ws, msg) {
      const s = String(msg);
      seen.push(s);
      console.log("  hover:", s);
    },
  },
});
console.log(`hover bridge listening on ${teePort}`);

const ws = new WebSocket(inspectorUrl);
let id = 0;
const pending = new Map<number, (v: any) => void>();

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
  if (m.method === "Debugger.paused") {
    // Must never happen: a condition that returns false does not pause. If
    // it does, the expression threw, and leaving the engine paused would
    // freeze Phil's session, so resume immediately and say so.
    console.log("UNEXPECTED PAUSE - the condition threw; resuming");
    send("Debugger.resume");
  }
};

ws.onopen = async () => {
  await send("Runtime.enable");
  await send("Debugger.enable");

  // 1. Give the engine a way out: its own socket back to us.
  const install = `
    (() => {
      try {
        if (globalThis.__nfTee && globalThis.__nfTee.readyState === 1) return "already";
        const s = new WebSocket("ws://127.0.0.1:${teePort}/");
        globalThis.__nfTee = s;
        globalThis.__nfHover = (c, r) => {
          try { if (s.readyState === 1) s.send(c + "," + r); } catch {}
        };
        return "installed";
      } catch (e) { return "error: " + e.message; }
    })()`;
  const r1 = await send("Runtime.evaluate", {
    expression: install,
    returnByValue: true,
  });
  console.log("install ->", JSON.stringify(r1?.result?.result?.value ?? r1?.result));

  // 2. The tee itself. `m` and `y` are the column and row the engine just
  //    computed; the trailing `false` is what keeps execution running.
  const condition = "(globalThis.__nfHover && globalThis.__nfHover(m, y), false)";
  const r2 = await send("Debugger.setBreakpoint", {
    location: { scriptId, lineNumber: line, columnNumber: col },
    options: { condition },
  });
  console.log("breakpoint ->", JSON.stringify(r2?.result ?? r2?.error));

  console.log("\nready: move the pointer over the Claude Code pane");
};

ws.onerror = (e: any) => { console.log("inspector socket error:", e?.message); };
setTimeout(() => {
  console.log(`\n${seen.length} hover event(s) received`);
  process.exit(seen.length ? 0 : 3);
}, 60000);
