// locate.ts - pull one script's source and find the exact hover call sites.
//
// searchInContent gives a LINE, and minified lines are tens of thousands of
// characters wide, so a line number alone cannot place a breakpoint. This
// fetches the source and converts a string index into {line, column}, which
// is what Debugger.setBreakpoint wants.
const url = process.argv[2];
const scriptId = process.argv[3];
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

ws.onmessage = (e: any) => {
  const m = JSON.parse(String(e.data));
  if (m.id && pending.has(m.id)) {
    pending.get(m.id)!(m);
    pending.delete(m.id);
  }
};

function at(src: string, idx: number) {
  const before = src.slice(0, idx);
  const line = before.split("\n").length - 1;
  const col = idx - (before.lastIndexOf("\n") + 1);
  return { line, col };
}

ws.onopen = async () => {
  await send("Debugger.enable");
  const r = await send("Debugger.getScriptSource", { scriptId });
  const src: string = r?.result?.scriptSource ?? "";
  console.log(`source length: ${src.length}`);
  if (!src) { process.exit(1); }

  for (const needle of [
    "onHoverAt(",
    "onHoverLost",
    "lastHoverCol",
    "onPointerHover",
  ]) {
    let from = 0;
    let n = 0;
    while (n < 3) {
      const i = src.indexOf(needle, from);
      if (i < 0) break;
      const { line, col } = at(src, i);
      console.log(`${needle}  #${n}  line=${line} col=${col}`);
      console.log(`    ...${src.slice(Math.max(0, i - 90), i + 90).replace(/\n/g, " ")}...`);
      from = i + 1;
      n++;
    }
    if (n === 0) console.log(`${needle}  not found`);
  }
  process.exit(0);
};

ws.onerror = (e: any) => { console.log("err", e?.message); process.exit(1); };
setTimeout(() => { console.log("timed out"); process.exit(2); }, 30000);
