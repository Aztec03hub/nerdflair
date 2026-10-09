// bp-test.ts - is the breakpoint hit, and is `m`/`y` in scope there?
//
// Two separate questions that one failing test cannot tell apart:
//   A. the breakpoint never fires (wrong location, or no motion arriving)
//   B. it fires but the condition throws, because the variables the
//      minifier chose are not named `m` and `y` at that exact column
//
// So the condition here reports a CONSTANT first. If constants arrive, the
// location is right and the problem is scope; if nothing arrives, the
// location or the input is wrong.
const inspectorUrl = process.argv[2];
const teePort = Number(process.argv[3] ?? 39810);
const expr = process.argv[4] ?? "(globalThis.__nfHover && globalThis.__nfHover('HIT','HIT'), false)";

let got = 0;
Bun.serve({
  port: teePort,
  fetch(req: any, server: any) {
    if (server.upgrade(req)) return;
    return new Response("bp-test");
  },
  websocket: {
    open() { console.log("engine connected"); },
    message(_ws: any, msg: any) { got++; console.log("  from engine:", String(msg)); },
  },
});

const ws = new WebSocket(inspectorUrl);
let id = 0;
const pending = new Map<number, (v: any) => void>();
const sendRaw = (method: string, params: any = {}) => {
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
    const top = m.params?.callFrames?.[0];
    console.log("PAUSED at", JSON.stringify(top?.location),
      "- the condition threw, so the location is RIGHT and scope is wrong");
    // Report the names actually in scope at this point, which is the thing
    // we cannot guess from minified source.
    sendRaw("Debugger.evaluateOnCallFrame", {
      callFrameId: top.callFrameId,
      expression: "Object.keys(this||{}).slice(0,5).join(',')",
      returnByValue: true,
    }).then((r) => console.log("  this keys:", r?.result?.result?.value));
    sendRaw("Debugger.resume");
  }
};

ws.onopen = async () => {
  await sendRaw("Runtime.enable");
  await sendRaw("Debugger.enable");
  const r1 = await sendRaw("Runtime.evaluate", {
    expression: `(() => { try {
      const s = new WebSocket("ws://127.0.0.1:${teePort}/");
      globalThis.__nfTee = s;
      globalThis.__nfHover = (c, r) => { try { if (s.readyState === 1) s.send(c + "," + r); } catch {} };
      return "installed";
    } catch (e) { return "err " + e.message } })()`,
    returnByValue: true,
  });
  console.log("install ->", r1?.result?.result?.value);
  const r2 = await sendRaw("Debugger.setBreakpoint", {
    location: { scriptId: "466", lineNumber: 33, columnNumber: 8098 },
    options: { condition: expr },
  });
  console.log("breakpoint ->", JSON.stringify(r2?.result?.actualLocation ?? r2?.error));
  console.log("condition:", expr);
};

setTimeout(() => {
  console.log(`\nevents received: ${got}`);
  process.exit(got ? 0 : 3);
}, 45000);
