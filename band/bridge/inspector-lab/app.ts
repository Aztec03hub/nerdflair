// app.ts - the smallest program that can answer the arming question.
//
// It must stay alive long enough for an inspector to dial out, and it must
// print something so we know it ran. Nothing else.
//
// The question: `BUN_INSPECT_CONNECT_TO` makes a Bun process connect OUT to a
// debugger at startup. The Claude Code binary reads that variable (it is in
// the runtime's env-name table) and never dials. Is that because
// `bun build --compile` strips or gates the inspector, or because of how we
// invoked it? Comparing interpreted against compiled, with the same script
// and the same listener, separates those.
let n = 0;
console.log("app: up, pid", process.pid);
const t = setInterval(() => {
  n++;
  if (n > 40) {
    clearInterval(t);
    console.log("app: done");
  }
}, 250);
