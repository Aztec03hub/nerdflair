#!/usr/bin/env bun
// nfbridge.ts - the bridge. Hover in, floating panel out.
//
// SHAPE OF THE THING
//
//   Claude Code (Bun)                     this daemon
//   ─────────────────                     ───────────
//   BUN_INSPECT opens an inspector  <──   connects, Runtime.evaluate
//   stdin tee installed as plain JS  ──>  {t:"ptr",col,row} over a WebSocket
//                                         hit-test against the band layout
//   the pane's tty                   <──  panel painted straight to /dev/pts/N
//
// Nothing is patched on disk and nothing is injected natively. The engine's
// own hover, focus and highlighting are untouched: the tee returns every
// input chunk unchanged, and the painter writes to the tty as any other
// process may.
//
// WHY THE PAINTER IS NOT INSIDE THE ENGINE. Bun issues its write syscalls
// directly rather than through libc, and the engine repaints its frame
// whenever it likes. Painting from outside, on the tty, sidesteps both.

const ESC = "\x1b";
const RESET = `${ESC}[0m`;

type Seg = { id: string; x: number; w: number; title: string; body: string[]; rgb: [number, number, number] };

// ── the panel ───────────────────────────────────────────────────────────────

const TRAIL = 14;
const FPS = 28;
const REST = 26;

function rgb(c: [number, number, number]) {
  return `${ESC}[38;2;${c[0]};${c[1]};${c[2]}m`;
}
function lerp(a: [number, number, number], b: [number, number, number], t: number) {
  return [0, 1, 2].map((i) => Math.round(a[i] + (b[i] - a[i]) * t)) as [number, number, number];
}

class Painter {
  tty: number | null = null;
  path: [number, number, string][][] = [];
  rect: [number, number, number, number] | null = null;
  accent: [number, number, number] = [255, 255, 255];
  head = 0;
  shown: string | null = null;

  constructor(private ttyPath: string, private rows: number, private cols: number) {}

  private w(s: string) {
    try {
      // Opened per paint: the pane's tty can go away under us when the
      // session exits, and a stale fd would throw on every frame.
      Bun.write(Bun.file(this.ttyPath), s);
    } catch {}
  }

  private buildPaths(x: number, y: number, w: number, h: number, title: string) {
    const top = "╭─ " + title + " " + "─".repeat(Math.max(0, w - title.length - 5)) + "╮";
    const bottom = "╰" + "─".repeat(w - 2) + "╯";
    const a: [number, number, string][] = [...top].map((ch, i) => [y, x + i, ch]);
    for (let r = 1; r < h - 1; r++) a.push([y + r, x + w - 1, "│"]);
    a.push([y + h - 1, x + w - 1, "╯"]);
    const b: [number, number, string][] = [[y, x, "╭"]];
    for (let r = 1; r < h - 1; r++) b.push([y + r, x, "│"]);
    [...bottom].forEach((ch, i) => b.push([y + h - 1, x + i, ch]));
    return [a, b];
  }

  show(seg: Seg, bandRow: number) {
    const w = Math.min(
      this.cols - 4,
      Math.max(seg.title.length + 6, ...seg.body.map((b) => b.length + 4)),
    );
    const h = seg.body.length + 2;
    const x = Math.max(1, Math.min(seg.x - 2, this.cols - w - 1));
    const y = Math.max(1, bandRow - h);

    if (this.shown === seg.id && this.rect) return; // already up, let it shine
    if (this.rect) this.hide();

    const acc = rgb(seg.rgb);
    let out = `${ESC}[s${ESC}[?25l`;
    seg.body.forEach((line, i) => {
      out += `${ESC}[${y + 1 + i};${x}H${acc}│${RESET} ${line.padEnd(w - 4)} ${acc}│${RESET}`;
    });
    this.w(out + `${ESC}[?25h${ESC}[u`);

    this.accent = seg.rgb;
    this.path = this.buildPaths(x, y, w, h, seg.title);
    this.rect = [x, y, w, h];
    this.head = 0;
    this.shown = seg.id;
    this.paint(true);
  }

  hide() {
    if (!this.rect) return;
    // We do not know what the engine had under the panel, so ask IT to
    // repaint rather than guessing and smearing the transcript. A resize
    // nudge of zero is the cheapest full redraw a TUI reliably honours.
    const [x, y, w, h] = this.rect;
    let out = `${ESC}[s${ESC}[?25l`;
    for (let r = y; r < y + h; r++) out += `${ESC}[${r};${x}H${" ".repeat(w)}`;
    this.w(out + `${ESC}[?25h${ESC}[u`);
    this.rect = null;
    this.path = [];
    this.shown = null;
    try { process.kill(this.enginePid ?? 0, "SIGWINCH"); } catch {}
  }

  enginePid: number | null = null;

  paint(full = false) {
    if (!this.path.length) return;
    const white: [number, number, number] = [255, 255, 255];
    let out = `${ESC}[s${ESC}[?25l`;
    for (const path of this.path) {
      const n = path.length;
      const lo = full ? 0 : Math.max(0, this.head - TRAIL - 2);
      const hi = full ? n - 1 : Math.min(n - 1, this.head);
      for (let i = lo; i <= hi; i++) {
        const cell = path[i];
        if (!cell) continue;
        const [row, col, ch] = cell;
        const d = this.head - i;
        let colour = this.accent;
        let bold = "";
        if (d >= 0 && d < TRAIL) {
          const t = (1 - d / TRAIL) ** 2;
          colour = lerp(this.accent, white, Math.min(1, t * 1.15));
          bold = t > 0.72 ? `${ESC}[1m` : "";
        }
        out += `${ESC}[${row};${col}H${bold}${rgb(colour)}${ch}${RESET}`;
      }
    }
    this.w(out + `${ESC}[?25h${ESC}[u`);
  }

  tick() {
    if (!this.path.length) return;
    const longest = Math.max(...this.path.map((p) => p.length));
    if (this.head > longest + TRAIL + REST) {
      this.head = 0;
      this.paint(true);
      return;
    }
    this.head++;
    this.paint();
  }
}

// ── layout: which readout sits where ────────────────────────────────────────
//
// The band's own columns come from the renderer, which is the only thing that
// knows them. Until the plugin publishes them over this socket, the layout is
// read from a JSON file it writes; the daemon re-reads it when it changes.

async function readLayout(path: string): Promise<{ row: number; segs: Seg[] } | null> {
  try {
    const f = Bun.file(path);
    if (!(await f.exists())) return null;
    return JSON.parse(await f.text());
  } catch {
    return null;
  }
}

// ── main ────────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
const opt = (k: string, d = "") => {
  const i = argv.indexOf(`--${k}`);
  return i >= 0 ? (argv[i + 1] ?? d) : d;
};

const ttyPath = opt("tty");
const layoutPath = opt("layout", `${process.env.HOME}/.claude/nerdflair-band-layout.json`);
const port = Number(opt("port", "39840"));
const rows = Number(opt("rows", "50"));
const cols = Number(opt("cols", "200"));
const enginePid = Number(opt("pid", "0"));

if (!ttyPath) {
  console.error("usage: nfbridge.ts --tty /dev/pts/N [--layout f] [--port n] [--rows n] [--cols n] [--pid n]");
  process.exit(2);
}

const painter = new Painter(ttyPath, rows, cols);
painter.enginePid = enginePid || null;
let layout = await readLayout(layoutPath);
let lastHit: string | null = null;
let seen = 0;

setInterval(async () => {
  const l = await readLayout(layoutPath);
  if (l) layout = l;
}, 2000);

setInterval(() => painter.tick(), 1000 / FPS);

Bun.serve({
  port,
  fetch(req, server) {
    if (server.upgrade(req)) return;
    return new Response("nerdflair bridge");
  },
  websocket: {
    open() {
      console.log("engine attached");
    },
    message(_ws, raw) {
      let m: any;
      try { m = JSON.parse(String(raw)); } catch { return; }
      // First few events logged whatever they are: the failure mode when
      // this goes quiet is indistinguishable from "no pointer moved", and
      // guessing which it was wastes more time than the lines cost.
      if (seen < 8) {
        seen++;
        console.log(`ptr col=${m.col} row=${m.row} (band row ${layout?.row ?? "?"})`);
      }
      if (m.t !== "ptr" || !layout) return;
      // Only the band's own row counts: a pointer anywhere else is not a
      // hover over a readout, and treating it as one would flash the panel
      // as the pointer crossed the transcript.
      const hit =
        m.row === layout.row
          ? layout.segs.find((s) => m.col >= s.x && m.col < s.x + s.w)
          : undefined;
      const id = hit?.id ?? null;
      if (id === lastHit) return;
      lastHit = id;
      if (hit) painter.show(hit, layout.row);
      else painter.hide();
    },
  },
});

console.log(`bridge up: tty=${ttyPath} port=${port} layout=${layoutPath}`);
console.log(layout ? `layout: row ${layout.row}, ${layout.segs.length} readouts` : "layout: none yet");

export {};  // top-level await needs this file to be a module
