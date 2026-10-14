import type { Hook, Register } from 'claude-code'

// The nerdflair status line, drawn as a tree instead of a line of text, so
// each readout can light under the pointer and explain itself.
//
// WHY IT SHELLS OUT. The figures come from `nerdflair-statusline --json`,
// the same binary the native status line runs, rather than being recomputed
// here. That renderer already has two implementations held byte-identical by
// a 162-payload differential test; a third one in TypeScript would be a third
// thing to keep in step, and the first to drift. `--json` re-emits the
// segments it already built, each with a stable id, so this file only decides
// presentation.
//
// WHERE THE PAYLOAD COMES FROM. Claude Code pipes the status line a JSON
// payload; a plugin never sees it. `$.session.usage()` returns the same
// figures ("as the status line has them") and the plain call costs nothing,
// so the payload is reconstructed from it.

// No `process` in this environment, so HOME is asked of the system once, on
// the first render. It used to be a hardcoded path, which made the band work
// on exactly one machine.
let HOME = ''
let homeLookup: Promise<void> | null = null // the lookup in flight: overlapping renders share it instead of seeing HOME empty
let homeTriedAt = -Infinity // when the HOME lookup last ran: a failing one is retried every 30 s, not every render
const BIN = () => `${HOME}/.local/bin/nerdflair-statusline`
// The popup helper, installed beside this file. tmux draws it, because the
// engine cannot float anything here; see the note above the width budget.
const POPUP = () => `${HOME}/.claude/local-marketplace/plugins/nerdflair-band/popup.sh`

const DIM = '#6b7280'
const LIT = '#1f2937' // hover background
const SEP = ' · '

// What each readout is, where its number comes from, and the trap worth
// knowing. Keyed by the id `--json` emits.
const CARDS: Record<string, { title: string; lines: string[]; color: string }> = {
  folder: {
    title: 'Folder and branch',
    color: '#7dd3fc',
    lines: [
      'workspace.project_dir, else current_dir',
      'branch from `git rev-parse --abbrev-ref HEAD`, cached 5s',
      'a worktree branch in the payload wins over git',
    ],
  },
  model: {
    title: 'Model and effort',
    color: '#c4b5fd',
    lines: ['model.display_name, else model.id', 'effort.level, after any silent downgrade'],
  },
  dirty: {
    title: 'Working tree',
    color: '#fbbf24',
    lines: ['changed files, then +added/-removed lines', 'from `git status --porcelain` and `git diff --numstat`'],
  },
  ahead: {
    title: 'Divergence from upstream',
    color: '#fbbf24',
    lines: ['commits ahead and behind the tracking branch'],
  },
  mcp: {
    title: 'MCP servers',
    color: '#c084fc',
    lines: [
      'names from the `claude mcp list` probe when its cache is warm',
      'else the config files: what is CONFIGURED, not what connected',
      'cached 300s, refreshed by one locked background job',
    ],
  },
  mcp_health: {
    title: 'MCP health',
    color: '#4ade80',
    lines: ['connected / total, then ! failed and ? needing auth', 'same probe as the names above'],
  },
  tmux: { title: 'tmux session', color: '#38bdf8', lines: ['the tmux session this pane belongs to'] },
  limits: {
    title: 'Plan rate limits',
    color: '#4ade80',
    lines: [
      "5h and 7d windows from the payload's rate_limits",
      'percentage used, then time until the window resets',
      "Anthropic's own server-side metering, not an estimate",
    ],
  },
  compact_eta: {
    title: 'Compaction ETA',
    color: '#a3a3a3',
    lines: [
      'when the context window is projected to fill',
      'Theil-Sen slope over a 16-sample ring, idle gaps excluded',
      'measured ~68% median error, so it is rounded and always ~',
    ],
  },
  throughput: {
    title: 'Token throughput',
    color: '#60a5fa',
    lines: ['output tokens per second of API time', 'from the delta between two samples, not a lifetime average'],
  },
  api_time: {
    title: 'API duration',
    color: '#a3a3a3',
    lines: ['cumulative time awaiting the API this session', 'cost.total_api_duration_ms'],
  },
  burn: {
    title: 'Burn rate',
    color: '#fb923c',
    lines: [
      'dollars per hour across EVERY session, last 60 minutes',
      'from ~/.claude/nerdflair-usage.tsv, read by seeking from the end',
      'sums positive increments, so a session reset cannot erase it',
      'suppressed when the newest sample is over 3 minutes old',
    ],
  },
  block: {
    title: 'Billing block',
    color: '#c084fc',
    lines: [
      'spend inside the CURRENT 5-hour rate-limit window',
      'window is rate_limits.five_hour.resets_at less 5h',
      'says idle rather than guess when that window has lapsed',
    ],
  },
  repo_cost: {
    title: 'Repo total',
    color: '#4ade80',
    lines: ['everything this repo has cost over 30 days', 'max cumulative cost per session, summed'],
  },
  session_cost: {
    title: 'Session cost',
    color: '#86efac',
    lines: ["cost.total_cost_usd: Claude Code's own figure for this session"],
  },
  chime: { title: 'Chime', color: '#d8b4fe', lines: ['the chime style and volume in use'] },
}

type Seg = { id: string; text: string }

// One subprocess per render would be wasteful: the band redraws far more often
// than any of these numbers move, and the renderer itself costs ~6ms.
let cache: { at: number; segs: Seg[] } | null = null
let lastError = ''

// Remote Control state. Claude Code used to show a green indicator for this
// and no longer does, so the band carries its own.
//
// `$.session.surfaces()` is the source of truth: it lists every surface the
// session draws on, `terminal` for the REPL plus any remote client in attach
// order, so anything that is not `terminal` IS remote control. The attach and
// detach events only timestamp the transitions; they are never the state
// itself, because a reload would miss any that happened while we were gone.
//
// These are module variables, so a hot reload forgets them. That costs only
// the two timestamps: the attached/not-attached state is re-read from
// surfaces() on every render and is always correct. After a reload an active
// session reads as "just attached"; the card says "since reload" then, via
// rcSinceGuess, rather than presenting a guess as an observed time.
let rcSinceGuess = false // rcSince was set by a render, not by an attach event
let rcSince = 0 // when the current remote attachment began
let rcLeftAt = 0 // when the last one ended
let rcSeen: string[] = [] // the remote surfaces currently attached

const RC_GREEN = '#4ade80'
const RC_AMBER = '#fbbf24'
const RC_OFF = '#4b5563'
// How long a departure stays called out before the chip settles to "off". A
// detach that merely made the chip vanish would be easy to miss, which is the
// whole complaint about the indicator that was removed.
const RC_LINGER_MS = 30000

// The engine REFUSES a whole render whose Text child holds a control
// character, and draws its own fallback instead. That cost a long debug: the
// stale binary returned the normal ANSI status line, JSON.parse threw, and
// Node's parse error embeds the offending input in its message, so a raw ESC
// byte travelled from the subprocess into lastError and out into a Text. The
// band then vanished with no error, because the error WAS the thing being
// refused. Nothing reaches a Text without passing through here.
function plain(s: string): string {
  // eslint-disable-next-line no-control-regex
  return s.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '').replace(/[\x00-\x1f\x7f]/g, ' ')
}

// THE RULE: no silent failures. A fallback is fine, but every absorbed failure
// is logged or shown, once, with the reason. `note` logs to the debug log only
// (`to: 'debug'` keeps it off the transcript); `report` also makes it the
// band's current error, which the red band and the stale marker display.
// Deduped on the text, so a failure that repeats every render logs one line.
// Callers keep the reason stable (no ages or counters in it) so the dedupe holds.
type Log = { ui: { log: (text: string, opts: { to: 'debug' }) => unknown } }
type RenderArgs = Parameters<Hook<'ui.render'>>
const seen = new Set<string>()
function note($: Log, where: string, why: unknown): string {
  const msg = `${where}: ${plain(String(why)).slice(0, 300)}`
  if (!seen.has(msg)) {
    if (seen.size >= 200) seen.clear() // bounded: a reason that varies would grow this forever
    seen.add(msg)
    $.ui.log(`nerdflair-band: ${msg}`, { to: 'debug' })
  }
  return msg
}
function report($: Log, where: string, why: unknown): void {
  lastError = note($, where, why)
}

// The band must never wrap. `--json` hands over UNTRUNCATED text (the MCP
// segment alone can be 17 server names and ~180 columns), and a row of flex
// children that each wrap on their own turns the band into three ragged lines,
// which is what it was doing.
//
// A per-segment cap does NOT achieve this, which is worth stating because it
// was the first thing I wrote: ten segments capped at 26 still total ~290
// columns with separators, so every pane narrower than that still wraps. The
// budget has to be on the WHOLE row.
//
// So: spend a total budget, taking it off the longest segment first. That
// converges on equal-width segments only when everything is long, and leaves
// short ones ($1.23, ↑3) untouched, which is what you want, since the long one
// is almost always the MCP list and the short ones are the numbers.
//
// Hover is what makes this free: the row carries the short form, the card
// carries the whole value, so clipping loses nothing.
const BAND_MAX = 120
const SEG_MIN = 6

// WHY THERE IS NO FLOATING CARD *FROM IN HERE*.
//
// There IS one now, and it floats over the status line with no reserved row:
// band/bridge/nfpty.py runs Claude Code behind a pty it owns, so it sees the
// pointer in the input stream and paints panels into the output stream. What
// follows is why it had to be done from OUTSIDE the engine rather than here,
// and it is all still true of a plugin.
//
// Three overlay designs were built and each died on a different engine rule,
// two of them read out of the 2.1.295 binary rather than guessed:
//
//  1. Absolute, above the row. The renderer does
//         if (P < 0 && n.style.position === "absolute") P = 0
//     to every absolute node, and again in the absolute-descendant pass. It
//     is a CLAMP, not a clip: the card was not cut off, it was slammed onto
//     row 0 of the live frame, which is the band's own row, and painted its
//     border over the segment text. It has to work that way, because rows
//     above the live frame are terminal scrollback the engine does not own.
//     That is also why tmux can paint over your history and a plugin cannot:
//     tmux owns the screen.
//
//  2. Absolute, below the row. Never clamped, and clipping is opt-in (`gC`
//     returns a clip rect only where overflow is "hidden" or "scroll"), so
//     it draws. It is then painted over by the prompt, which is a later
//     sibling: absolute paints over "those before it", not those after.
//
//  3. In flow. Renders perfectly and shoves the entire screen down, which is
//     the one outcome Phil ruled out by name.
//
// What works INSIDE the engine is its own documented pattern: a hover GROUP,
// whose members light together "in any site on the surface", swapping an
// entry into a fixed row of the band. The detail then does not need to live
// inside the hovered element, which is the constraint every design above was
// fighting. It costs a permanently reserved row, which is why the real
// floating panel ended up outside the engine instead.

// Cells, not UTF-16 units: a Nerd Font glyph is one astral code point, which
// .length counts as 2 and .slice can cut in half.
const len = (t: string): number => Array.from(t).length
const cut = (t: string, n: number): string => Array.from(t).slice(0, n).join('')

function budget(texts: string[], sep: number, fixed = 0): string[] {
  const out = [...texts]
  const width = () =>
    fixed + out.reduce((n, t) => n + len(t), 0) + sep * Math.max(0, out.length - 1)
  // Each pass shortens only the current longest, so the result does not depend
  // on segment order and no segment is cut while a longer one is left alone.
  while (width() > BAND_MAX) {
    let i = 0
    let best = len(out[0] ?? '')
    for (let j = 1; j < out.length; j++) {
      const n = len(out[j] ?? '')
      if (n > best) {
        best = n
        i = j
      }
    }
    const cur = out[i]
    if (cur === undefined || len(cur) <= SEG_MIN) break // at the floor: stop rather than spin
    out[i] = cut(cur, len(cur) - 1)
  }
  return out.map((t, i) => (len(t) < len(texts[i] ?? '') ? cut(t, len(t) - 1) + '…' : t))
}

function ago(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return `${s}s`
  const m = Math.round(s / 60)
  return m < 60 ? `${m}m` : `${Math.round(m / 60)}h`
}

const TTL_MS = 2000
const STALE_MS = 30000
let inflight: Promise<Seg[] | null> | null = null
let lastFailAt = 0
const FAIL_BACKOFF_MS = 5000

// Test seam: module state outlives a hook registration, so cases in one test
// file would see each other's cache and errors. The engine never calls this.
export function resetStateForTests(): void {
  HOME = ''
  homeTriedAt = -Infinity
  homeLookup = null
  cache = null
  lastError = ''
  inflight = null
  lastFailAt = 0
  seen.clear()
  rcSince = 0
  rcLeftAt = 0
  rcSeen = []
  rcSinceGuess = false
}

export const register: Register = on => {
  // Timestamp the transitions. The state itself still comes from surfaces();
  // these only make "attached 14m ago" and "left 8s ago" possible.
  on('session.attach', async ($, e, next) => {
    if (e.surface !== 'terminal' && rcSince === 0) {
      rcSince = await $.clock.now()
      rcSinceGuess = false
    }
    return next(e)
  })
  on('session.detach', async ($, e, next) => {
    const r = await next(e)
    if (e.surface !== 'terminal') {
      const left = (await $.session.surfaces()).filter(x => x !== 'terminal')
      if (left.length === 0) {
        rcLeftAt = await $.clock.now()
        rcSince = 0
      }
    }
    return r
  })

  // The whole render is guarded: an exception anywhere below is reported (debug
  // log, once) and the engine draws its own UI, so the plugin can neither break
  // the screen nor fail without a trace.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    try {
      return await band($, e)
    } catch (err) {
      report($, 'render failed, engine UI drawn instead', err)
      return next(e)
    }
  })

}

async function band($: RenderArgs[0], e: RenderArgs[1]) {
  const now = await $.clock.now()
  if (!HOME && !homeLookup && now - homeTriedAt > 30000) {
    homeTriedAt = now
    // No home, no renderer path. Say so in the band (red, with the reason)
    // instead of silently handing the screen back to the engine, which
    // would repeat every render forever with no explanation.
    homeLookup = (async () => {
      let why = ''
      try {
        const h = await $.process.run(['printenv', 'HOME'], { timeoutMs: 2000 })
        HOME = h.exitCode === 0 ? h.stdout.trim() : ''
        if (!HOME) why = `printenv HOME exit ${h.exitCode}, ${h.stdout.trim() ? 'output unusable' : 'empty'}: ${h.stderr || '(no stderr)'}`
      } catch (err) {
        why = `printenv HOME failed: ${err}`
      }
      if (!HOME) report($, 'HOME lookup', why)
    })().finally(() => {
      homeLookup = null
    })
  }
  // A render that arrives while the lookup runs waits for it, rather than finding
  // HOME empty and drawing a false "no recorded reason" error.
  if (homeLookup) await homeLookup
  if (HOME && (!cache || now - cache.at > TTL_MS) && now - lastFailAt > FAIL_BACKOFF_MS) {
    // One refresh at a time: renders arrive faster than the renderer returns,
    // and each would otherwise spawn its own.
    const segs = await (inflight ??= (async () => {
      // Which step is running, so a failure says WHERE it happened.
      let stage = 'usage'
      try {
        const u = await $.session.usage()
        stage = 'session'
        const cwd = await $.session.cwd()
        // The REAL session id, not a made-up one. The renderer appends the
        // session's cumulative cost to ~/.claude/nerdflair-usage.tsv keyed
        // by this; a phantom id would add a second row carrying the same
        // real dollars, and burn, block and the repo total would all count
        // this session twice. With the true id the append is idempotent:
        // same key, same value, and a shared 60s stamp rate-limits it.
        const sid = await $.session.id()
        const model = await $.session.model()
        const five = u.rateLimits?.find(r => r.kind === 'five_hour')
        const seven = u.rateLimits?.find(r => r.kind === 'seven_day')
        // resetsAt is an ISO string here; the renderer reads an epoch,
        // which is the shape the host's own status-line payload uses.
        // An unparseable time is OMITTED (and noted), never sent as NaN, which
        // JSON turns into null and the renderer would take for "no reset".
        const epoch = (t?: string) => {
          if (!t) {
            note($, 'payload', 'rate limit has no resetsAt: resets_at omitted')
            return undefined
          }
          const s = Math.floor(Date.parse(t) / 1000)
          if (Number.isFinite(s)) return s
          note($, 'payload', `rate limit resetsAt is not a date, resets_at omitted: ${t}`)
          return undefined
        }
        // NEVER invent a figure. A field the host did not give is OMITTED from
        // the payload and noted once, so its segments vanish honestly instead
        // of showing 200000 tokens, 0% or $0, which the renderer would also
        // append to the shared usage ledger as if real.
        const ctx = u.context as typeof u.context | undefined
        if (!ctx) note($, 'payload', 'usage.context missing: context segments omitted')
        else {
          if (ctx.tokens === undefined) note($, 'payload', 'usage.context.tokens missing: omitted')
          if (ctx.percent === undefined) note($, 'payload', 'usage.context.percent missing: omitted')
          if (ctx.window === undefined) note($, 'payload', 'usage.context.window missing: omitted')
        }
        if (!u.cost) note($, 'payload', 'usage.cost missing: cost segments omitted')
        else if (u.cost.usd === undefined) note($, 'payload', 'usage.cost.usd missing: omitted')
        if (five && five.percentUsed === undefined) note($, 'payload', 'five_hour percentUsed missing: omitted')
        if (seven && seven.percentUsed === undefined) note($, 'payload', 'seven_day percentUsed missing: omitted')
        if (!five) note($, 'payload', 'no five_hour rate limit reported: that window is omitted')
        if (!seven) note($, 'payload', 'no seven_day rate limit reported: that window is omitted')
        const payload = {
          session_id: sid,
          transcript_path: '/nonexistent/band.jsonl',
          workspace: { current_dir: cwd, project_dir: cwd },
          // The real model, as /model shows it; this used to say "Opus 5"
          // whatever was running.
          model: { display_name: model, id: model },
          ...(ctx && {
            context_window: {
              context_window_size: ctx.window,
              ...(ctx.tokens !== undefined && { total_input_tokens: ctx.tokens }),
              ...(ctx.percent !== undefined && { used_percentage: ctx.percent }),
            },
          }),
          ...(u.cost && {
            cost: {
              total_cost_usd: u.cost.usd,
              // PLACEHOLDERS, not measurements: a plugin is not given the
              // session's wall-clock or API durations. 1 keeps the renderer
              // from dividing by zero; the throughput and API-time segments
              // are therefore not meaningful in the band.
              total_duration_ms: 1,
              total_api_duration_ms: 1,
            },
          }),
          rate_limits: {
            ...(five && {
              five_hour: {
                used_percentage: five.percentUsed,
                resets_at: epoch(five.resetsAt),
              },
            }),
            ...(seven && {
              seven_day: {
                used_percentage: seven.percentUsed,
                resets_at: epoch(seven.resetsAt),
              },
            }),
          },
        }
        stage = 'run'
        const r = await $.process.run([BIN(), '--json'], {
          stdin: JSON.stringify(payload),
          timeoutMs: 5000,
        })
        if (r.exitCode !== 0) {
          // Non-zero exit: say which, with the renderer's own words. 127 is
          // the shell's "command not found".
          const err = (r.stderr || '(no stderr; a signal reads as exit 1)').slice(0, 160)
          report(
            $,
            r.exitCode === 127 ? `renderer not found at ${BIN()}; run the installer` : 'renderer failed',
            `exit ${r.exitCode}: ${err}`,
          )
          return null
        }
        if (r.stderr) note($, 'renderer warned on stderr (exit 0)', r.stderr.slice(0, 200))
        if (r.isStdoutTruncated) {
          report($, 'renderer output truncated', 'stdout exceeded the capture limit, so it cannot be parsed')
          return null
        }
        if (!r.stdout) {
          report($, 'renderer printed nothing', 'exit 0 but empty stdout')
          return null
        }
        stage = 'parse'
        let j: unknown
        try {
          j = JSON.parse(r.stdout)
        } catch (err) {
          // The sample is what the renderer actually said, which is how a
          // stale binary printing the plain status line shows itself.
          report($, 'renderer output is not JSON', `${err}; starts: ${r.stdout.slice(0, 80)}`)
          return null
        }
        stage = 'validate'
        const segs = (j as { segments?: unknown } | null)?.segments
        if (!Array.isArray(segs)) {
          report($, 'renderer JSON has no segments array', `starts: ${r.stdout.slice(0, 80)}`)
          return null
        }
        if (segs.length === 0) {
          report($, 'renderer returned 0 segments', 'an empty list is an error here, not "nothing to show"')
          return null
        }
        if (!segs.every(s => s && typeof s.id === 'string' && typeof s.text === 'string')) {
          report($, 'renderer segments malformed', 'each needs a string id and text')
          return null
        }
        return segs as Seg[]
      } catch (err) {
        // Do NOT swallow this. A silent catch here is why the first version
        // drew nothing with no way to find out why. It is reported, with the
        // step that failed, to the debug log and into the band.
        const msg = String(err)
        if (stage === 'run' && /ENOENT|not found|No such file/i.test(msg)) {
          report($, `renderer not found at ${BIN()}; run the installer`, msg)
        } else if (stage === 'run' && /time(d)? ?out/i.test(msg)) {
          report($, 'renderer timed out (5 s)', msg)
        } else {
          report($, `refresh failed at ${stage}`, msg)
        }
        return null
      }
    })().finally(() => {
      inflight = null
    }))
    if (segs) {
      // Stamped when the refresh FINISHED: a 2 s+ renderer would otherwise cache figures
      // that are already past TTL_MS and get re-run by the very next render.
      cache = { at: await $.clock.now(), segs }
      // A good refresh ends the failure; forget its log line so a later
      // recurrence is logged again rather than swallowed as a duplicate.
      if (lastError) seen.delete(lastError)
      lastError = ''
      lastFailAt = 0
    } else {
      // A renderer that keeps failing must not leave figures frozen as if
      // they were live: until 30 s pass the old ones stay, marked `stale`
      // below with the reason; after that they go and the red error shows.
      // Back off: a renderer that fails is not re-run on every render. Stamped AFTER the
      // refresh settled (a 5 s timeout would otherwise leave a stamp 5 s old, no back-off).
      lastFailAt = await $.clock.now()
      if (cache && now - cache.at > STALE_MS) cache = null
    }
  }
  // Cheap and never rejects, so it is read every render rather than cached:
  // the whole point of this chip is that it is never stale.
  // plain(): surface names come from outside and reach a Text and a tmux popup
  rcSeen = (await $.session.surfaces()).filter(x => x !== 'terminal').map(plain)
  if (rcSeen.length > 0 && rcSince === 0) {
    rcSince = now
    rcSinceGuess = true // not observed: could have been attached before we loaded
  }
  if (rcSeen.length === 0 && rcSince !== 0) {
    rcLeftAt = now
    rcSince = 0
  }

  const { Box, Text, Button } = $.ui.resolve(e)
  if (!cache) {
    // No figures to show. Say why in the band. An empty reason cannot happen
    // (every failed refresh sets one), so if it does, that is itself reported.
    if (!lastError) report($, 'band', 'no figures and no recorded reason (plugin bug)')
    return (
      <Box>
        <Text color="#f87171">nerdflair-band: {plain(lastError)}</Text>
      </Box>
    )
  }
  // Old figures after a failed refresh are drawn, but marked: the age and the
  // reason, in red at the end of the row, so they are not read as live.
  const staleText = lastError ? `stale ${ago(now - cache.at)}: ${plain(lastError).slice(0, 60)}` : ''

  // The Remote Control pill: always present, three states, hover panel.
  // Always present is the point. An indicator that only appears when remote
  // control is on cannot tell you it is OFF, and "no indicator" is also what
  // a broken indicator looks like, which is how the native one went missing
  // without anyone being able to say when.
  // The BRIDGE decides the state, not surfaces(). The renderer reports it
  // from CLAUDE_CODE_BRIDGE_SESSION_ID, which Claude Code maintains in its
  // own process as bridges attach and detach. surfaces() answers a
  // different question, "who is drawing right now", and measured on this
  // machine it said terminal-only while the session file carried a live
  // bridgeSessionId: the chip read "RC off" with remote control attached.
  // surfaces() is still worth showing, as the detail of WHERE it is drawing,
  // so it stays in the card.
  // The renderer says exactly `rc on` or `rc off`. Anything else, or no
  // segment at all (an older or newer binary), is UNKNOWN and shown as such,
  // in amber, with a log line. It used to fall back to surfaces(), which the
  // note above says is wrong, so the chip could read "off" while attached.
  const rcSeg = cache.segs.find(s => s.id === 'remote_control')
  const rcRaw = rcSeg ? plain(rcSeg.text).trim() : undefined
  const rcUnknown = rcRaw !== 'rc on' && rcRaw !== 'rc off'
  if (rcUnknown) {
    note(
      $,
      'remote control chip',
      rcRaw === undefined
        ? 'renderer sent no remote_control segment (old binary?), state unknown'
        : `unexpected remote_control text "${rcRaw.slice(0, 40)}", state unknown`,
    )
  }
  const rcOn = rcRaw === 'rc on'
  const rcJustLeft = !rcUnknown && !rcOn && rcLeftAt > 0 && now - rcLeftAt < RC_LINGER_MS
  // rcSeen can be empty while rcOn is true: a bridge is attached but no
  // remote client is painting. "on" is the honest label for that.
  const rc = rcUnknown
    ? { color: RC_AMBER, glyph: '?', label: 'unknown' }
    : rcOn
      ? { color: RC_GREEN, glyph: '⬤', label: rcSeen.length > 0 ? rcSeen.join('+') : 'on' }
      : rcJustLeft
        ? { color: RC_AMBER, glyph: '◌', label: `left ${ago(now - rcLeftAt)}` }
        : { color: RC_OFF, glyph: '◯', label: 'off' }
  const rcCard = rcUnknown
    ? [
        'the renderer did not say whether Remote Control is on',
        rcRaw === undefined ? 'no remote_control segment in its output' : `it sent "${rcRaw.slice(0, 40)}"`,
        'the binary may be out of step with this plugin; see the debug log',
      ]
    : rcOn
    ? [
        'a Remote Control bridge is attached to this session',
        rcSeen.length > 0
          ? `drawing on: ${rcSeen.join(', ')}`
          : 'no remote client is drawing right now',
        `seen attached for: ${ago(now - rcSince)}${rcSinceGuess ? ' (since reload)' : ''}`,
        'anything typed there runs here, in this working directory',
        'source: CLAUDE_CODE_BRIDGE_SESSION_ID, read fresh each render',
      ]
    : rcJustLeft
      ? [
          `last remote client detached ${ago(now - rcLeftAt)} ago`,
          'the terminal is the only surface again',
        ]
      : [
          'no remote client attached; terminal only',
          'from $.session.surfaces(): anything not "terminal" is remote',
          'Claude Code used to show this in green and no longer does',
        ]

  // Clipped once for the whole row, before anything is drawn: the budget is
  // a property of the row, so it cannot be decided inside a per-segment map.
  // The RC chip is charged against the budget too, as it occupies the row
  // like any other segment.
  // remote_control is drawn by the chip, so it must not also appear as an
  // ordinary segment. One list from here on, so the chip and the segments
  // cannot disagree about who is charged against the width budget.
  const segs = cache.segs.filter(s => s.id !== 'remote_control')
  // The chip is NOT in the budget. It was, and the budget duly clipped it to
  // "RC …", which throws away the one thing it exists to say. A state
  // indicator that can be shortened into ambiguity is worse than no
  // indicator, so it is charged against the budget as a fixed cost and the
  // other segments share what is left.
  const rcText = `${rc.glyph} RC ${rc.label}`
  // The stale marker is charged too, so it cannot push the row into wrapping.
  const shown = budget(
    segs.map(s => plain(s.text)),
    SEP.length,
    rcText.length + SEP.length + (staleText ? staleText.length + SEP.length : 0),
  )

  // A CLICK opens a real floating popup, drawn by tmux.
  //
  // This is the way out of the whole overlay problem. The engine cannot
  // float anything here (see the note above the budget), but tmux can,
  // because tmux owns the screen: its own menus are drawn exactly this way.
  // Verified before wiring, by attaching a throwaway client to a scratch
  // session and finding the popup's title and 105 border cells in the
  // client's pty stream.
  //
  // It has to be a click rather than a hover IN HERE, and that is not a
  // preference. No hover event ever crosses to a plugin: the engine puts
  // the terminal in mouse mode 1003 and consumes motion itself, so this
  // code never learns the pointer moved. `ui.press` IS delivered, so a
  // press is the only moment a plugin can act on.
  //
  // The pointer CAN be had from outside the process, and the hover panels
  // in band/bridge/nfpty.py do exactly that: it holds the pty, so motion
  // reaches it before the engine, and it forwards every byte unchanged so
  // the engine's own highlighting is untouched. Routes that look easier
  // and are not, each closed by a measurement rather than a guess, are in
  // band/bridge/inspector-lab/README.md.
  //
  // `plain` draws "the label alone", no [ brackets ], so the band looks
  // exactly as it did and the pointer still lights the label.
  //
  // The result is READ. popup.sh exits non-zero, with a one-line reason on
  // stderr, when it cannot draw (no tmux, not inside tmux, display-popup
  // failed); that reason is toasted and logged. A 60 s timeout is NOT a
  // failure: it is the popup's own lifetime, left open and reaped.
  const popup = (title: string, bodyText: string, x: number) => {
    const fail = (why: string) => {
      const msg = note($, 'popup', why)
      // A toast that cannot be shown is itself reported (the cause is already logged by note).
      try {
        void Promise.resolve($.ui.toast(`nerdflair-band: ${msg}`)).catch(err => note($, 'toast', `could not show: ${err}`))
      } catch (err) {
        note($, 'toast', `could not show: ${err}`)
      }
    }
    void (async () => {
      try {
        const r = await $.process.run(['bash', POPUP(), String(x), title, bodyText], {
          timeoutMs: 60000,
        })
        if (r.exitCode !== 0) fail(`exit ${r.exitCode}: ${(r.stderr || '(no stderr)').trim().slice(0, 160)}`)
      } catch (err) {
        if (!/time(d)? ?out/i.test(String(err))) fail(`could not run ${POPUP()}: ${err}`)
      }
    })()
  }
  // Where each readout starts, so the popup opens under the thing clicked
  // instead of in the corner. The press event carries no coordinates, but
  // the widths are already known here: they are what the budget produced.
  let col = 0
  const colOf: number[] = []
  for (const t of shown) {
    colOf.push(col)
    col += t.length + SEP.length
  }

  const rcChipWidth = rcText.length + SEP.length

  // budget() stops at the per-segment floor rather than spin. If the row is
  // STILL too wide then it will wrap, which is what it exists to prevent:
  // say so, once, instead of wrapping unexplained.
  if (rcChipWidth + shown.reduce((n, t) => n + len(t) + SEP.length, 0) > BAND_MAX + SEP.length) {
    note($, 'band width', `row still over ${BAND_MAX} columns at the segment floor; it will wrap`)
  }

  return (
    <Box flexDirection="column">
      <Box>
        {/* A Text with a hover style needs a KEYED Box around it: Claude Code
            2.1.296 refuses the whole tree otherwise ("Text hover has no Box
            with a key around it") and draws its own, which is why the band
            and the Remote Control pill never appeared. */}
        <Box key="rc">
          <Button
            plain
            key="rc-button"
            onPress={() => popup('Remote Control', rcCard.join(' · '), 0)}
          >
            <Text color={rc.color} hover={{ bold: true, backgroundColor: LIT }}>
              {rcText}
            </Text>
          </Button>
        </Box>
        <Text color={DIM}>{SEP}</Text>
        {segs.map((s, i) => {
          const card = CARDS[s.id]
          // Drawn grey with its own text, which is fine, but a renderer newer
          // than the CARDS table is drift worth one line in the log.
          if (!card) note($, 'segment', `unknown id "${s.id}", drawn without a card (renderer newer than this plugin?)`)
          const color = card?.color ?? DIM
          const full = plain(s.text)
          // The full value leads whenever the row had to clip it, or the
          // popup would explain a number you cannot read.
          const detail = card
            ? (shown[i] !== full ? `${full}  —  ` : '') + card.lines.join(' · ')
            : full
          return (
            <Box key={`seg-${s.id}`}>
              {i > 0 ? <Text color={DIM}>{SEP}</Text> : null}
              <Button
                plain
                key={s.id}
                onPress={() => {
                  const at = colOf[i]
                  if (at === undefined) note($, 'popup', `no column known for ${s.id}, opened at the chip`)
                  popup(card?.title ?? s.id, detail, rcChipWidth + (at ?? 0))
                }}
              >
                <Text color={color} hover={{ bold: true, backgroundColor: LIT }}>
                  {shown[i]}
                </Text>
              </Button>
            </Box>
          )
        })}
        {staleText ? <Text color="#f87171">{SEP + staleText}</Text> : null}
      </Box>
    </Box>
  )
}

