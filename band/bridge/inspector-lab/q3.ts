// q3.ts - is .read() called at all, and do mouse bytes pass through it?
//
// Three outcomes, which one failing test cannot separate:
//   reads=0            the engine does not use this stream; the tee is dead
//   reads>0, mouse=0   it reads, but motion arrives by another route
//   reads>0, mouse>0   the tee works and the fault is downstream
const ws = new WebSocket(process.argv[2]);
let id = 0;
const p = new Map<number, (v: any) => void>();
const send = (m: string, q: any = {}) =>
  new Promise<any>((r) => {
    const i = ++id;
    p.set(i, r);
    ws.send(JSON.stringify({ id: i, method: m, params: q }));
  });
ws.onmessage = (e: any) => {
  const m = JSON.parse(String(e.data));
  if (m.id && p.has(m.id)) { p.get(m.id)!(m); p.delete(m.id); }
};

const ARM = `
(() => {
  globalThis.__nfReads = 0;
  globalThis.__nfMouse = 0;
  globalThis.__nfBytes = 0;
  const st = process.stdin;
  const base = globalThis.__nfOrigRead || st.read;
  globalThis.__nfOrigRead = base;
  st.read = function () {
    const c = base.apply(this, arguments);
    globalThis.__nfReads++;
    if (c) {
      const s = typeof c === "string" ? c : c.toString("latin1");
      globalThis.__nfBytes += s.length;
      if (s.indexOf("[<") >= 0) globalThis.__nfMouse++;
    }
    return c;
  };
  return "armed";
})()`;

const READ = `JSON.stringify({
  reads: globalThis.__nfReads, mouse: globalThis.__nfMouse,
  bytes: globalThis.__nfBytes, raw: String(process.stdin.isRaw),
  listeners: process.stdin.listenerCount("readable") })`;

ws.onopen = async () => {
  await send("Runtime.enable");
  const a = await send("Runtime.evaluate", { expression: ARM, returnByValue: true });
  console.log("arm:", a?.result?.result?.value);
  console.log("INJECT NOW");
  await new Promise((r) => setTimeout(r, 9000));
  const b = await send("Runtime.evaluate", { expression: READ, returnByValue: true });
  console.log("after:", b?.result?.result?.value);
  process.exit(0);
};
setTimeout(() => process.exit(2), 25000);
