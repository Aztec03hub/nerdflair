// can-pause.ts - can the debugger actually stop this realm's code?
//
// Five breakpoints in the mouse handler fired zero times, which has two very
// different explanations: the code is not running in the realm we attached
// to, or the debugger has no grip on it at all. Debugger.pause separates
// them: it stops on the next statement WHEREVER that is. If it pauses, the
// grip is real and script 466 is simply not the code doing the work. If it
// never pauses, the attachment is cosmetic and breakpoints were never going
// to fire.
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

let paused = false;
ws.onmessage = (e: any) => {
  const m = JSON.parse(String(e.data));
  if (m.id && pending.has(m.id)) { pending.get(m.id)!(m); pending.delete(m.id); return; }
  if (m.method === "Debugger.paused") {
    paused = true;
    const f = m.params?.callFrames?.[0];
    console.log("PAUSED in script", f?.location?.scriptId,
      "line", f?.location?.lineNumber, "fn:", f?.functionName || "(anon)");
    // Resume at once. Leaving the engine paused would freeze the session.
    send("Debugger.resume").then(() => console.log("resumed"));
  }
};

ws.onopen = async () => {
  await send("Runtime.enable");
  await send("Debugger.enable");
  console.log("asking the engine to pause on its next statement");
  await send("Debugger.pause");
  setTimeout(() => {
    console.log(paused ? "\nVERDICT: debugger has a real grip on this realm"
                       : "\nVERDICT: no pause - the attachment does not control running code");
    if (paused) send("Debugger.resume");
    process.exit(paused ? 0 : 3);
  }, 9000);
};
setTimeout(() => process.exit(4), 20000);
