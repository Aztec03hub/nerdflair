// stdin-tee.ts - the hover tee, installed as plain JS inside the engine.
//
// WHY NOT A BREAKPOINT. Debugger.pause does not stop this realm even while
// it is handling keystrokes, and five breakpoints planted across the mouse
// handler fired zero times. The Debugger domain is attached but has no grip.
// Runtime.evaluate, on the other hand, executes perfectly. So the tee is a
// monkey-patch, not an instrumentation point.
//
// WHY STDIN. The engine reads the terminal through process.stdin, a
// ReadStream in raw mode with one 'readable' listener, which means it pulls
// bytes with .read(). Mouse motion arrives there as ESC[<35;col;rowM before
// any of the renderer's own hover logic runs. Wrapping .read() sees every
// byte the app consumes, in order, and alters nothing: the original chunk is
// returned untouched, so Claude Code's own hover, focus and highlighting
// carry on exactly as before.
//
// WHY NOT FRIDA. A native hook would work, but this is a few lines of JS
// riding an interface Bun is not going to change, it costs one evaluate at
// startup, and there is nothing to re-apply when Claude Code updates.
const inspectorUrl = process.argv[2];
const teePort = Number(process.argv[3] ?? 39830);

let events = 0;
const sample: string[] = [];
Bun.serve({
  port: teePort,
  fetch(req: any, server: any) {
    if (server.upgrade(req)) return;
    return new Response("nerdflair hover tee");
  },
  websocket: {
    open() { console.log("engine connected to the tee"); },
    message(_ws: any, msg: any) {
      events++;
      if (sample.length < 8) sample.push(String(msg));
    },
  },
});
console.log("tee listening on", teePort);

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
  if (m.id && pending.has(m.id)) { pending.get(m.id)!(m); pending.delete(m.id); }
};

const INSTALL = `
(() => {
  try {
    if (globalThis.__nfTeeInstalled) return "already installed";
    const sock = new WebSocket("ws://127.0.0.1:${teePort}/");
    globalThis.__nfSock = sock;

    // Only the LAST mouse report in a chunk matters: the terminal coalesces
    // motion, and acting on stale positions would lag the pointer.
    const RE = /\\x1b\\[<(\\d+);(\\d+);(\\d+)([Mm])/g;
    globalThis.__nfFeed = (chunk) => {
      try {
        const str = typeof chunk === "string" ? chunk : chunk.toString("latin1");
        if (str.indexOf("[<") < 0) return;
        RE.lastIndex = 0;
        let m, last = null;
        while ((m = RE.exec(str)) !== null) last = m;
        if (!last) return;
        if (sock.readyState !== 1) return;
        sock.send(JSON.stringify({
          t: "ptr",
          btn: +last[1],
          col: +last[2],
          row: +last[3],
          release: last[4] === "m",
        }));
      } catch (e) {}
    };

    const st = process.stdin;
    const orig = st.read;
    // Return the chunk UNCHANGED. This is a tee, not a filter: if it ever
    // alters or swallows input, the session stops responding to the user.
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
  console.log("install ->", r?.result?.result?.value);
  console.log("inject motion now");
};

setTimeout(() => {
  console.log(`\nhover events received: ${events}`);
  for (const s of sample) console.log("  ", s);
  process.exit(events ? 0 : 3);
}, 30000);
