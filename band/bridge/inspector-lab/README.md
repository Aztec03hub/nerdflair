# The inspector route, and why it is closed

Kept so nobody spends another night on it. Everything here works exactly as
advertised, and the route still cannot deliver a hover.

## What was proved to work

- **Arming.** `BUN_INSPECT=ws://127.0.0.1:PORT/path` makes a Bun binary
  *listen*. It survives `bun build --compile`; the inspector is gated, not
  stripped. (`BUN_INSPECT_CONNECT_TO` dials out and does not work here.)
  Proved on a micro project built with the same flags, then on Claude Code.
- **Code execution.** `Runtime.evaluate` works fully against the live engine:
  `probe-client.ts`, `q.ts`, `q2.ts`.
- **Finding the code.** `find-hover.ts` searched 1648 scripts and located the
  hover dispatch in script 466; `locate.ts` pinned the line and column.

## What does not work, and how that was established

- **The Debugger domain attaches but has no grip.** Five breakpoints planted,
  zero hits; `Debugger.pause` never pauses. See `bp-test.ts`, `bp-sweep.ts`,
  `can-pause.ts`.
- **The engine does not read the terminal through `process.stdin`.** This is
  the one that closes the route. `q3.ts` arms a call counter on
  `process.stdin.read`, then a burst of injected mouse motion is fired at the
  session. The result, with the TUI plainly rendering and this process holding
  the inspector port:

      reads=0  mouse=0  bytes=0  isRaw=undefined  listeners(readable)=0

  A tee on that object therefore sees nothing. An earlier tee appeared to work
  once, in a session that happened to be using the stream; it is not
  reproducible, and `install-tee.ts` is kept only as the record of that.

The wrong-process explanation was checked and ruled out: `claude` is a direct
symlink to the binary with no wrapper, the pid was alive, `ss` showed it
holding the port on fd 9, and the pane showed its TUI drawing.

## What replaced it

`../nfpty.py`. Claude Code runs behind a pty we own, so every input byte
passes through us on the way in and every output byte on the way out. Nothing
inside Claude Code is patched, injected or read off the screen, so an update
cannot break it.

`../nfbridge.ts`, `../install-tee.ts` and `../nfband` are the inspector-based
bridge those findings retired. They are superseded, not deleted: each one is
the evidence for a different closed door.
