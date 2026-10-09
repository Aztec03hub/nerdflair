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
      'names from the `claude mcp list` probe, not the config files',
      'the config files list what is CONFIGURED, which is fewer',
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
          <Text color="#f87171">nerdflair-band: {lastError}</Text>
        </Box>
      )
    }

    // The Remote Control pill: always present, three states, hover panel.
    // Always present is the point. An indicator that only appears when remote
    // control is on cannot tell you it is OFF, and "no indicator" is also what
    // a broken indicator looks like, which is how the native one went missing
    // without anyone being able to say when.
    const rcOn = rcSeen.length > 0
    const rcJustLeft = !rcOn && rcLeftAt > 0 && now - rcLeftAt < RC_LINGER_MS
    const rc = rcOn
      ? { color: RC_GREEN, glyph: '⬤', label: rcSeen.join('+') }
      : rcJustLeft
        ? { color: RC_AMBER, glyph: '◌', label: `left ${ago(now - rcLeftAt)}` }
        : { color: RC_OFF, glyph: '◯', label: 'off' }
    const rcCard = rcOn
      ? [
          `attached: ${rcSeen.join(', ')}`,
          `since: ${ago(now - rcSince)} ago`,
          'this session also draws on a remote client',
          'anything typed there runs here, in this working directory',
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

    return (
      <Box flexDirection="column">
        <Box>
          <Box key="seg-rc">
            <Text color={rc.color} hover={{ bold: true, backgroundColor: LIT }}>
              {rc.glyph} RC {rc.label}
            </Text>
            <Box
              position="absolute"
              top={-(rcCard.length + 3)}
              left={0}
              display="none"
              hover={{ display: 'flex' }}
              flexDirection="column"
              borderStyle="round"
              borderColor={rc.color}
              paddingX={1}
            >
              <Text color={rc.color} bold>
                Remote Control
              </Text>
              {rcCard.map((l, j) => (
                <Text key={`rc${j}`} color={DIM}>
                  {l}
                </Text>
              ))}
            </Box>
          </Box>
          <Text color={DIM}>{SEP}</Text>
          {cache.segs.map((s, i) => {
            const card = CARDS[s.id]
            const color = card?.color ?? DIM
            // A keyed Box scopes the hover. The card is absolutely positioned
            // and drawn `display: none`, so revealing it moves nothing and it
            // paints over the rows above rather than pushing them.
            return (
              <Box key={`seg-${s.id}`}>
                {i > 0 ? <Text color={DIM}>{SEP}</Text> : null}
                <Text color={color} hover={{ bold: true, backgroundColor: LIT }}>
                  {s.text}
                </Text>
                {card ? (
                  <Box
                    position="absolute"
                    top={-(card.lines.length + 3)}
                    left={0}
                    display="none"
                    hover={{ display: 'flex' }}
                    flexDirection="column"
                    borderStyle="round"
                    borderColor={color}
                    paddingX={1}
                  >
                    <Text color={color} bold>
                      {card.title}
                    </Text>
                    {card.lines.map((l, j) => (
                      <Text key={`l${j}`} color={DIM}>
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

