// q.ts - ask the engine what state the tee is actually in.
//
// "engine attached" proves a socket connected; it does not prove the tee is
// installed, that it still holds a live socket, or that .read() is still
// wrapped. Those are separate facts and only the engine can answer them.
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
ws.onopen = async () => {
  await send("Runtime.enable");
  const qs = [
    "globalThis.__nfTeeInstalled",
    "typeof globalThis.__nfFeed",
    "process.stdin.read.toString().slice(0,52).replace(/\\n/g,' ')",
    "process.stdin.listenerCount('readable')",
    "process.stdin.listenerCount('data')",
  ];
  for (const q of qs) {
    const r = await send("Runtime.evaluate", {
      expression: `(()=>{try{return String(${q})}catch(e){return "ERR "+e.message}})()`,
      returnByValue: true,
    });
    console.log(" ", q.padEnd(56), "=", r?.result?.result?.value);
  }
  process.exit(0);
};
setTimeout(() => process.exit(2), 15000);
