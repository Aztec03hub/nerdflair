// probe-stdin.ts - how does the engine read the terminal?
//
// Breakpoints are unavailable (Debugger.pause does not stop this realm even
// while keystrokes are being handled), but Runtime.evaluate executes fine.
// So the hover tee has to be a monkey-patch on something REACHABLE from
// inside, and the most promising thing is the input path itself: mouse
// motion arrives on stdin as ESC[<35;col;rowM, so whatever reads stdin sees
// every hover before the renderer does.
//
// This asks the engine what that path looks like before anything is patched.
const url = process.argv[2];
const ws = new WebSocket(url);
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

const QUESTIONS: [string, string][] = [
  ["stdin type", "typeof process.stdin"],
  ["stdin ctor", "process.stdin && process.stdin.constructor && process.stdin.constructor.name"],
  ["data listeners", "process.stdin.listenerCount ? process.stdin.listenerCount('data') : 'no listenerCount'"],
  ["readable listeners", "process.stdin.listenerCount ? process.stdin.listenerCount('readable') : 'n/a'"],
  ["has on()", "typeof process.stdin.on"],
  ["isRaw", "String(process.stdin.isRaw)"],
  ["isTTY", "String(process.stdin.isTTY)"],
  ["own keys", "Object.keys(process.stdin).slice(0,12).join(',')"],
  ["proto keys", "Object.getOwnPropertyNames(Object.getPrototypeOf(process.stdin)).slice(0,18).join(',')"],
  ["global hints", "Object.keys(globalThis).filter(k=>/claude|ink|tui|render|app/i.test(k)).join(',') || '(none)'"],
];

ws.onopen = async () => {
  await send("Runtime.enable");
  for (const [label, expr] of QUESTIONS) {
    const r = await send("Runtime.evaluate", {
      expression: `(() => { try { return String(${expr}) } catch (e) { return "ERR " + e.message } })()`,
      returnByValue: true,
    });
    const v = r?.result?.result?.value;
    console.log(`  ${label.padEnd(20)} ${String(v).slice(0, 150)}`);
  }
  process.exit(0);
};
setTimeout(() => process.exit(2), 25000);
