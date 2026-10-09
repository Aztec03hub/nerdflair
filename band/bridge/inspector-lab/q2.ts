// q2.ts - where does `read` really live, and what else reads the terminal?
//
// Patching process.stdin itself proved unreliable: the tee fired in one
// session and not in another, and listenerCount('readable') read 1 then 0,
// so the engine is not always holding that stream. A patch has to sit
// somewhere the engine cannot sidestep: the prototype that owns read, or
// the tty module's ReadStream class that every such stream is built from.
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

const QS: [string, string][] = [
  ["proto chain", `(() => { let o = process.stdin, out = [], n = 0;
      while (o && n++ < 6) { out.push((o.constructor && o.constructor.name) || "?"); o = Object.getPrototypeOf(o) }
      return out.join(" -> ") })()`],
  ["who owns read", `(() => { let o = process.stdin, n = 0;
      while (o && n++ < 6) { if (Object.prototype.hasOwnProperty.call(o, "read"))
        return (o.constructor && o.constructor.name) + " depth " + n; o = Object.getPrototypeOf(o) }
      return "not found" })()`],
  ["tty module", `(() => { try { const t = require("tty");
      return "ReadStream=" + (typeof t.ReadStream) } catch (e) { return "ERR " + e.message } })()`],
  ["tty proto read", `(() => { try { const t = require("tty");
      return typeof t.ReadStream.prototype.read } catch (e) { return "ERR " + e.message } })()`],
  ["stdin fd", `String(process.stdin.fd)`],
  ["raw now", `String(process.stdin.isRaw)`],
  ["readable listeners", `String(process.stdin.listenerCount("readable"))`],
  ["stdin === cached", `String(process.stdin === process.stdin)`],
];

ws.onopen = async () => {
  await send("Runtime.enable");
  for (const [label, expr] of QS) {
    const r = await send("Runtime.evaluate", {
      expression: `(()=>{try{return String(${expr})}catch(e){return "ERR "+e.message}})()`,
      returnByValue: true,
    });
    console.log(" ", label.padEnd(20), "=", String(r?.result?.result?.value).slice(0, 120));
  }
  process.exit(0);
};
setTimeout(() => process.exit(2), 15000);
