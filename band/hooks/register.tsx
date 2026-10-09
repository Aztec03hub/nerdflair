import type { Register } from 'claude-code'

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

const BIN = `${process_env_home()}/.local/bin/nerdflair-statusline`

function process_env_home(): string {
  // No `process` in this environment; the home path is stable for this mod.
  return '/home/plafayette'
}

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
// session reads as "just attached", which is honest enough.
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
// Card width. Wide enough for the longest explanation line without wrapping,
// narrow enough that revealing one does not displace the whole row.
const CARD_W = 68

// Card height, and the number of rows the band RESERVES above its segments so
// a card has somewhere to paint.
//
// This is the whole trick, and it is forced by how the engine clips. An
// absolutely positioned Box is "clipped, pointer and paint, by the region its
// site is in (viewport, pane, band)". The band is our site, so a card placed
// above the segment row is cut away unless the band itself is that tall: that
// is why the first attempt drew a bordered box with no body. Growing the card
// in flow fixed the clipping and bought a shift of the whole screen instead,
// which is worse.
//
// Reserving the rows gives an absolute card room INSIDE the region, and
// absolute means "no room among its siblings, painted over those before it",
// so revealing one moves nothing at all. The cost is CARD_H quiet rows above
// the band, always. That is the trade, and it is the only one available: a
// true overlay across the transcript is not, since Pane docks or sits inline
// rather than floating.
//
// Keep CARD_H and the lines a card draws in step: 2 border rows plus the
// title plus CARD_LINES of body.
const CARD_LINES = 3
const CARD_H = CARD_LINES + 3

function budget(texts: string[], sep: number, fixed = 0): string[] {
  const out = [...texts]
  const width = () =>
    fixed + out.reduce((n, t) => n + t.length, 0) + sep * Math.max(0, out.length - 1)
  // Each pass shortens only the current longest, so the result does not depend
  // on segment order and no segment is cut while a longer one is left alone.
  while (width() > BAND_MAX) {
    let i = 0
    let best = out[0]?.length ?? 0
    for (let j = 1; j < out.length; j++) {
      const n = out[j]?.length ?? 0
      if (n > best) {
        best = n
        i = j
      }
    }
    const cur = out[i]
    if (cur === undefined || cur.length <= SEG_MIN) break // at the floor: stop rather than spin
    out[i] = cur.slice(0, cur.length - 1)
  }
  return out.map((t, i) => (t.length < (texts[i]?.length ?? 0) ? t.slice(0, -1) + '…' : t))
}

// A card's body: the full value first when the row clipped it, then as much
// explanation as the reserved rows hold. Capped, never grown, because the card
// is a fixed height and overflow would spill outside the box.
function body(
  card: { lines: string[] },
  full: string,
  drawn: string,
): string[] {
  const lead = drawn !== full ? [full] : []
  return [...lead, ...card.lines].slice(0, CARD_LINES)
}

function ago(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return `${s}s`
  const m = Math.round(s / 60)
  return m < 60 ? `${m}m` : `${Math.round(m / 60)}h`
}

const TTL_MS = 2000

export const register: Register = on => {
  // Timestamp the transitions. The state itself still comes from surfaces();
  // these only make "attached 14m ago" and "left 8s ago" possible.
  on('session.attach', async ($, e, next) => {
    if (e.surface !== 'terminal' && rcSince === 0) rcSince = await $.clock.now()
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

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const now = await $.clock.now()
    if (!cache || now - cache.at > TTL_MS) {
      const segs = await (async () => {
        try {
          const u = await $.session.usage()
          const cwd = await $.session.cwd()
          // The REAL session id, not a made-up one. The renderer appends the
          // session's cumulative cost to ~/.claude/nerdflair-usage.tsv keyed
          // by this; a phantom id would add a second row carrying the same
          // real dollars, and burn, block and the repo total would all count
          // this session twice. With the true id the append is idempotent:
          // same key, same value, and a shared 60s stamp rate-limits it.
          const sid = await $.session.id()
          const five = u.rateLimits?.find(r => r.kind === 'five_hour')
          const seven = u.rateLimits?.find(r => r.kind === 'seven_day')
          // resetsAt is an ISO string here; the renderer reads an epoch,
          // which is the shape the host's own status-line payload uses.
          const epoch = (t?: string) =>
            t ? Math.floor(Date.parse(t) / 1000) : undefined
          const payload = {
            session_id: sid,
            transcript_path: '/nonexistent/band.jsonl',
            workspace: { current_dir: cwd, project_dir: cwd },
            model: { display_name: 'Opus 5', id: 'claude-opus-5' },
            context_window: {
              context_window_size: u.context?.window ?? 200000,
              total_input_tokens: u.context?.tokens ?? 0,
              total_output_tokens: 0,
              used_percentage: u.context?.percent ?? 0,
            },
            cost: {
              total_cost_usd: u.cost?.usd ?? 0,
              total_duration_ms: 1,
              total_api_duration_ms: 1,
            },
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
          const r = await $.process.run([BIN, '--json'], {
            stdin: JSON.stringify(payload),
            timeoutMs: 5000,
          })
          if (r.exitCode !== 0 || !r.stdout) {
            // The OTHER silent path. The catch below reports throws, but a
            // non-zero exit or empty stdout returned null with no message,
            // so the band vanished and said nothing, which is exactly as
            // undiagnosable as the swallowed exception was.
            lastError = `exit ${r.exitCode}: ${(r.stderr || '(no stderr)').slice(0, 160)}`
            return null
          }
          return (JSON.parse(r.stdout) as { segments: Seg[] }).segments ?? []
        } catch (err) {
          // Do NOT swallow this. A silent catch here is why the first version
          // drew nothing with no way to find out why: the band simply was not
          // there, which is indistinguishable from "hover does not work".
          // Surface it IN the band instead, where it cannot be missed.
          lastError = String(err).slice(0, 200)
          return null
        }
      })()
      if (segs) cache = { at: now, segs }
    }
    // Cheap and never rejects, so it is read every render rather than cached:
    // the whole point of this chip is that it is never stale.
    rcSeen = (await $.session.surfaces()).filter(x => x !== 'terminal').slice()
    if (rcSeen.length > 0 && rcSince === 0) rcSince = now
    if (rcSeen.length === 0 && rcSince !== 0) {
      rcLeftAt = now
      rcSince = 0
    }

    const { Box, Text } = $.ui.resolve(e)
    if (!cache || cache.segs.length === 0) {
      if (!lastError) return next(e)
      return (
        <Box>
          <Text color="#f87171">nerdflair-band: {plain(lastError)}</Text>
        </Box>
      )
    }

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
    const rcSeg = cache.segs.find(s => s.id === 'remote_control')
    const rcOn = rcSeg ? rcSeg.text === 'rc on' : rcSeen.length > 0
    const rcJustLeft = !rcOn && rcLeftAt > 0 && now - rcLeftAt < RC_LINGER_MS
    // rcSeen can be empty while rcOn is true: a bridge is attached but no
    // remote client is painting. "on" is the honest label for that.
    const rc = rcOn
      ? { color: RC_GREEN, glyph: '⬤', label: rcSeen.length > 0 ? rcSeen.join('+') : 'on' }
      : rcJustLeft
        ? { color: RC_AMBER, glyph: '◌', label: `left ${ago(now - rcLeftAt)}` }
        : { color: RC_OFF, glyph: '◯', label: 'off' }
    const rcCard = rcOn
      ? [
          'a Remote Control bridge is attached to this session',
          rcSeen.length > 0
            ? `drawing on: ${rcSeen.join(', ')}`
            : 'no remote client is drawing right now',
          `seen attached for: ${ago(now - rcSince)}`,
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
    const shown = budget(segs.map(s => plain(s.text)), SEP.length, rcText.length + SEP.length)

    return (
      <Box flexDirection="column">
        {/* The reserved overlay space: always present, and the reason a card
            can paint above the row without moving it. Each row holds a space
            rather than being an empty Box, because a Box with a height and no
            content collapses and the reservation silently does nothing. */}
        {Array.from({ length: CARD_H }, (_, j) => (
          <Text key={`pad${j}`}> </Text>
        ))}
        <Box>
          <Box key="seg-rc">
            <Text color={rc.color} hover={{ bold: true, backgroundColor: LIT }}>
              {rcText}
            </Text>
            <Box
              position="absolute"
              top={-CARD_H}
              left={0}
              display="none"
              hover={{ display: 'flex' }}
              flexDirection="column"
              borderStyle="round"
              borderColor={rc.color}
              paddingX={1}
              width={CARD_W}
              height={CARD_H}
            >
              <Text color={rc.color} bold>
                Remote Control
              </Text>
              {/* Capped to the reserved rows, same as every other card. */}
              {rcCard.slice(0, CARD_LINES).map((l, j) => (
                <Text key={`rc${j}`} color={DIM}>
                  {l}
                </Text>
              ))}
            </Box>
          </Box>
          <Text color={DIM}>{SEP}</Text>
          {segs.map((s, i) => {
            const card = CARDS[s.id]
            const color = card?.color ?? DIM
            // A keyed Box scopes the hover: the card is a DESCENDANT of the
            // box being hovered, which is what makes a declarative
            // `hover={{display:'flex'}}` fire on it at all. It cannot be
            // hovered itself while hidden, and no hover event reaches the
            // plugin, so this nesting is the only mechanism available.
            //
            // Absolute, into the reserved rows above: out of the flow, so it
            // takes no room among its siblings and paints over what is
            // already there. Revealing it moves NOTHING, which is the point.
            return (
              <Box key={`seg-${s.id}`}>
                {i > 0 ? <Text color={DIM}>{SEP}</Text> : null}
                <Text color={color} hover={{ bold: true, backgroundColor: LIT }}>
                  {shown[i]}
                </Text>
                {card ? (
                  <Box
                    position="absolute"
                    top={-CARD_H}
                    left={0}
                    display="none"
                    hover={{ display: 'flex' }}
                    flexDirection="column"
                    borderStyle="round"
                    borderColor={color}
                    paddingX={1}
                    width={CARD_W}
                    height={CARD_H}
                  >
                    <Text color={color} bold>
                      {card.title}
                    </Text>
                    {/* The full value leads whenever the row had to cut it,
                        or hover would explain a number you cannot read. The
                        body is then capped to the reserved rows: the card has
                        a FIXED height now, so anything longer would spill out
                        of the box rather than enlarge it. */}
                    {body(card, plain(s.text), shown[i] ?? '').map((l, j) => (
                      <Text key={`l${j}`} color={j === 0 && l === plain(s.text) ? color : DIM}>
                        {l}
                      </Text>
                    ))}
                  </Box>
                ) : null}
              </Box>
            )
          })}
        </Box>
      </Box>
    )
  })
}

