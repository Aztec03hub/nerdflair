import { expect, mock, test } from 'claude-code/testing'

import { bandRowDefaultForTests, register, resetStateForTests } from './register'

// One case per class of failure the band used to absorb silently. Each asserts
// BOTH halves of the rule: the failure is visible (red band, stale marker,
// toast) and it is logged once, with the reason, to the debug log.

const BAND = {
  component: 'AbovePrompt',
  surface: 'terminal',
  requestId: 'band',
  viewport: { columns: 180, rows: 48, isFullscreen: true },
  props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 100, scroll: { offset: 0, bodyRows: 19 }, view: {} },
} as const

const result = (exitCode: number, stdout = '', stderr = '', extra = {}) => ({
  value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false, ...extra },
})
const GOOD = JSON.stringify({
  segments: [
    { id: 'folder', text: 'myrepo main' },
    { id: 'remote_control', text: 'rc off' },
  ],
})

type Run = (argv: readonly string[], stdin: string | undefined) => unknown

/** The world beneath the band: a renderer that answers as `renderer` says, and a record of what it logged and toasted. */
function world(
  on: any,
  renderer: Run,
  // debug: what `--rc-sync` answers (the band row wanted?); sync: replaces that answer; sid/surfaces: the session's
  opts: { usage?: object; now?: number; debug?: boolean; sync?: Run; sid?: string; surfaces?: string[] } = {},
) {
  resetStateForTests()
  const w = { logs: [] as string[], toasts: [] as string[], stdins: [] as string[], popups: [] as string[][], syncs: [] as string[][] }
  const clock = mock.clock(on, { now: opts.now ?? 1_000_000 })
  register(on, {} as never)
  on('session.usage', async () => ({
    value: opts.usage ?? { startedAt: 0, context: { window: 200000, tokens: 1000, percent: 1 }, rateLimits: [], cost: { usd: 1 } },
  }))
  on('session.cwd', async () => ({ value: '/work' }))
  on('session.id', async () => ({ value: opts.sid ?? 'sid-1' }))
  on('session.model', async () => ({ value: 'opus' }))
  on('session.surfaces', async () => ({ value: opts.surfaces ?? ['terminal'] }))
  on('ui.log', async (_$: any, e: any) => {
    w.logs.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', async (_$: any, e: any) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('process.run', async (_$: any, e: any) => {
    if (e.argv[1] === '--rc-sync') {
      w.syncs.push([...e.argv])
      return opts.sync ? opts.sync(e.argv, undefined) : result(0, `debug=${opts.debug === false ? 0 : 1}\n`)
    }
    if (e.argv[0] === 'bash') {
      w.popups.push([...e.argv])
    } else if (e.argv[0] !== 'printenv') {
      w.stdins.push(e.init?.stdin ?? '')
    }
    if (e.argv[0] === 'printenv') return renderer(e.argv, undefined)
    return renderer(e.argv, e.init?.stdin)
  })
  return { w, clock }
}

/** Every string a drawn tree holds. */
function textOf(node: any): string {
  if (node === null || node === undefined || typeof node === 'boolean') return ''
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  const kids = node.children ?? node.props?.children ?? []
  return (Array.isArray(kids) ? kids : [kids]).map(textOf).join('')
}

const ok = (argv: readonly string[]) => (argv[0] === 'printenv' ? result(0, '/home/t\n') : result(0, GOOD))

test('printenv HOME failing is shown in the band and logged once, not silently handed to the engine', async ($, on) => {
  const { w } = world(on, argv => (argv[0] === 'printenv' ? result(1, '', 'printenv: gone') : ok(argv)))

  const a = await drawOrEngine($)
  await drawOrEngine($)

  expect(a, 'no record has ever been written: the fault opens the row').toContain('HOME lookup')
  expect(a).toContain('printenv: gone')
  expect(w.logs.filter(l => l.includes('HOME lookup')).length, 'logged once across two renders').toBe(1)
  expect(w.logs.filter(l => l.includes('HOME lookup')).length, 'logged once across two renders').toBe(1)
})

test('printenv rejecting (spawn failure or timeout) is reported, not thrown through the render', async ($, on) => {
  const { w } = world(on, argv => (argv[0] === 'printenv' ? { deny: 'spawn printenv ENOENT' } : ok(argv)))

  expect(await drawOrEngine($)).toContain('HOME lookup')
  expect(w.logs.some(l => l.includes('HOME lookup') && l.includes('ENOENT'))).toBe(true)
})

/** Draws the band; when the plugin has nothing to show it calls next(e), and in these tests nothing sits beneath it (the engine would draw its own row). */
async function drawOrEngine($: any): Promise<string> {
  try {
    return textOf(await $.ui.render(BAND as never))
  } catch (err) {
    if (String(err).includes('no implementation for ui.render')) return 'ENGINE-DEFAULT-ROW'
    throw err
  }
}

test('an aborted printenv (superseded render) is retried on the next render, never drawn red or backed off', async ($, on) => {
  let n = 0
  const { w } = world(on, argv => (argv[0] === 'printenv' && ++n === 1 ? { deny: 'HooksError: $.process.run(printenv) aborted' } : ok(argv)))

  const a = await drawOrEngine($)
  const b = await drawOrEngine($)

  expect(a).not.toContain('HOME lookup')
  expect(b).not.toContain('HOME lookup')
  expect(a, 'a superseded first refresh draws the engine default, not a plugin-bug line').toContain('ENGINE-DEFAULT-ROW')
  expect(a).not.toContain('plugin bug')
  expect(b).not.toContain('plugin bug')
  expect(n, 'second render looked HOME up again, no 30 s wait').toBe(2)
  expect(w.logs.some(l => l.includes('HOME lookup'))).toBe(false)
})

test('printenv aborted on five renders in a row is reported, so a permanently cut-off render is not silent', async ($, on) => {
  const { w } = world(on, argv => (argv[0] === 'printenv' ? { deny: 'HooksError: $.process.run(printenv) aborted' } : ok(argv)))

  for (let i = 0; i < 5; i++) await drawOrEngine($)

  expect(w.logs.filter(l => l.includes('HOME lookup') && l.includes('5 renders in a row')).length).toBe(1)
})

test('renderer exit 1 shows the exit code and stderr and is logged', async ($, on) => {
  const { w } = world(on, argv => (argv[0] === 'printenv' ? ok(argv) : result(1, '', 'no such flag --json')))

  const a = textOf(await $.ui.render(BAND as never))

  expect(a).toContain('exit 1: no such flag --json')
  expect(w.logs.some(l => l.includes('renderer failed') && l.includes('no such flag'))).toBe(true)
})

test('renderer exit 0 with empty stdout is an error, not an empty band', async ($, on) => {
  const { w } = world(on, argv => (argv[0] === 'printenv' ? ok(argv) : result(0, '')))

  const a = textOf(await $.ui.render(BAND as never))

  expect(a).toContain('renderer printed nothing')
  expect(w.logs.some(l => l.includes('renderer printed nothing'))).toBe(true)
})

test('a renderer result of {"segments":[]} is an error, not "no segments"', async ($, on) => {
  const { w } = world(on, argv => (argv[0] === 'printenv' ? ok(argv) : result(0, '{"segments":[]}')))

  const a = textOf(await $.ui.render(BAND as never))

  expect(a).toContain('renderer returned 0 segments')
  expect(w.logs.some(l => l.includes('0 segments'))).toBe(true)
})

test('bad JSON names the stage, shows a short plain sample, and never lets an escape byte reach a Text', async ($, on) => {
  const { w } = world(on, argv => (argv[0] === 'printenv' ? ok(argv) : result(0, '\x1b[1mplain status line\x1b[0m')))

  const a = textOf(await $.ui.render(BAND as never))

  expect(a).toContain('renderer output is not JSON')
  expect(a).toContain('plain status line')
  expect(a.includes('\x1b')).toBe(false)
  expect(w.logs.some(l => l.includes('not JSON'))).toBe(true)
  expect(w.logs.some(l => l.includes('\x1b'))).toBe(false)
})

test('after a failed refresh the old figures stay but carry "stale Ns: reason"; a good refresh clears it', async ($, on) => {
  let healthy = true
  const { clock } = world(on, argv => {
    if (argv[0] === 'printenv') return ok(argv)
    return healthy ? result(0, GOOD) : result(1, '', 'renderer down')
  })

  const fresh = textOf(await $.ui.render(BAND as never))
  expect(fresh).toContain('myrepo main')
  expect(fresh).not.toContain('stale')

  healthy = false
  await clock.advance(5000)
  const stale = textOf(await $.ui.render(BAND as never))

  expect(stale, 'old figures still drawn').toContain('myrepo main')
  expect(stale).toContain('stale 5s: ')
  expect(stale).toContain('renderer down')

  healthy = true
  await clock.advance(6000)
  expect(textOf(await $.ui.render(BAND as never))).not.toContain('stale')
})

test('a renderer that keeps failing is spawned once per 5 s, even while a stale cache exists', async ($, on) => {
  let healthy = true
  let spawns = 0
  const { clock } = world(on, argv => {
    if (argv[0] === 'printenv') return ok(argv)
    if (!healthy) spawns++
    return healthy ? result(0, GOOD) : result(1, '', 'renderer down')
  })

  await $.ui.render(BAND as never)
  healthy = false
  await clock.advance(3000)
  await $.ui.render(BAND as never) // fails: one spawn
  await clock.advance(3000)
  await $.ui.render(BAND as never) // 3 s after the failure: backed off
  expect(spawns).toBe(1)
  await clock.advance(3000)
  await $.ui.render(BAND as never) // 6 s after: tries again
  expect(spawns).toBe(2)
})

test('the payload omits what the host did not give instead of inventing 200000, 0 and $0', async ($, on) => {
  const { w } = world(on, ok, { usage: { startedAt: 0, rateLimits: [] } })

  await $.ui.render(BAND as never)

  const payload = JSON.parse(w.stdins[0] ?? '{}')
  expect(payload.context_window).toBeUndefined()
  expect(payload.cost).toBeUndefined()
  expect(w.logs.some(l => l.includes('usage.context missing'))).toBe(true)
  expect(w.logs.some(l => l.includes('usage.cost missing'))).toBe(true)
})

test('no remote_control segment shows an amber "RC unknown" chip and logs, instead of guessing "off"', async ($, on) => {
  const { w } = world(on, argv => (argv[0] === 'printenv' ? ok(argv) : result(0, '{"segments":[{"id":"folder","text":"r"}]}')))

  const a = textOf(await $.ui.render(BAND as never))

  expect(a).toContain('RC unknown')
  expect(a).not.toContain('RC off')
  expect(w.logs.some(l => l.includes('remote control chip'))).toBe(true)
})

test('a popup whose spawn fails or exits non-zero is toasted and logged; a 60 s timeout is not an error', async ($, on) => {
  let mode: 'exit4' | 'reject' | 'timeout' = 'exit4'
  const { w } = world(on, argv => {
    if (argv[0] === 'printenv') return ok(argv)
    if (argv[0] === 'bash') {
      if (mode === 'exit4') return result(4, '', 'popup.sh: not inside tmux; popups need a tmux session')
      return { deny: mode === 'reject' ? 'spawn bash ENOENT' : 'process timed out after 60000ms' }
    }
    return result(0, GOOD)
  })

  const ui = await $.ui.mount({ plugin: 'nerdflair-band', ...BAND, props: BAND.props } as never)
  await ui.press({ key: 'rc-button' })
  await Promise.resolve()
  expect(w.toasts.some(t => t.includes('not inside tmux'))).toBe(true)
  expect(w.logs.some(l => l.includes('popup') && l.includes('not inside tmux'))).toBe(true)

  mode = 'reject'
  await ui.press({ key: 'rc-button' })
  await Promise.resolve()
  expect(w.toasts.some(t => t.includes('could not run') && t.includes('ENOENT'))).toBe(true)

  const before = w.toasts.length
  mode = 'timeout'
  await ui.press({ key: 'rc-button' })
  await Promise.resolve()
  expect(w.toasts.length, 'a popup left open is not a failure').toBe(before)
  await ui.unmount()
})

test('two renders that overlap the HOME lookup draw the band, not a false "no recorded reason" error', async ($, on) => {
  const { w } = world(on, ok)
  // Both renders start before the first printenv answers.
  const [a, b] = await Promise.all([$.ui.render(BAND as never), $.ui.render(BAND as never)])
  for (const tree of [a, b]) {
    const t = textOf(tree)
    expect(t).not.toContain('no recorded reason')
    expect(t).toContain('myrepo main')
  }
  expect(w.logs.some(l => l.includes('no recorded reason'))).toBe(false)
})

test('a slow failing renderer is backed off from when it FAILED, not from when it started', async ($, on) => {
  let healthy = true
  let spawns = 0
  const { clock } = world(on, argv => {
    if (argv[0] === 'printenv') return ok(argv)
    if (healthy) return result(0, GOOD)
    spawns++
    return clock.advance(5000).then(() => result(1, '', 'renderer down')) // a 5 s run that then fails
  })

  await $.ui.render(BAND as never)
  healthy = false
  await clock.advance(3000)
  await $.ui.render(BAND as never) // fails after 5 s: spawn 1
  await clock.advance(3000)
  await $.ui.render(BAND as never) // 3 s after it FAILED: backed off (stamped at its start it would re-run)
  expect(spawns).toBe(1)
})

test('a slow renderer that succeeds leaves a cache that is fresh when it returns', async ($, on) => {
  let spawns = 0
  const { clock } = world(on, argv => {
    if (argv[0] === 'printenv') return ok(argv)
    spawns++
    return clock.advance(3000).then(() => result(0, GOOD)) // slower than TTL_MS
  })

  await $.ui.render(BAND as never)
  await $.ui.render(BAND as never)
  expect(spawns).toBe(1)
})

const ABORTED = (cmd: string) => ({ deny: `HooksError: nerdflair-band: $.process.run(${cmd}) aborted` })

test('two renders sharing one aborted refresh are both treated as superseded: no back-off for either', async ($, on) => {
  let spawns = 0
  const { w } = world(on, argv => {
    if (argv[0] === 'printenv') return ok(argv)
    return ++spawns === 1 ? ABORTED('/h/nerdflair-statusline') : result(0, GOOD)
  })

  await Promise.all([drawOrEngine($), drawOrEngine($)]) // one inflight refresh, aborted, awaited by both
  const c = await drawOrEngine($) // same instant: a back-off stamped by either render would block this spawn

  expect(spawns, 'the third render retried at once').toBe(2)
  expect(c).toContain('myrepo main')
  expect(w.logs.some(l => l.includes('refresh failed'))).toBe(false)
})

test('a renderer timeout whose message contains "aborted" is a timeout: reported and backed off, not retried as superseded', async ($, on) => {
  let spawns = 0
  const { w } = world(on, argv => {
    if (argv[0] === 'printenv') return ok(argv)
    spawns++
    return { deny: 'HooksError: nerdflair-band: $.process.run(/h/nerdflair-statusline) aborted: still running after 5000ms' }
  })

  const a = await drawOrEngine($)
  await drawOrEngine($)

  expect(a).toContain('renderer timed out')
  expect(spawns, 'backed off for 5 s').toBe(1)
  expect(w.logs.filter(l => l.includes('renderer timed out')).length).toBe(1)
})

test('a message that says timed out and also ends in "aborted" is a timeout', async ($, on) => {
  let spawns = 0
  world(on, argv => {
    if (argv[0] === 'printenv') return ok(argv)
    spawns++
    return { deny: 'spawn timed out: $.process.run(x) aborted' }
  })
  expect(await drawOrEngine($)).toContain('renderer timed out')
  await drawOrEngine($)
  expect(spawns, 'backed off').toBe(1)
})

test('ENOENT is tested before abort, even when the path contains "abort"', async ($, on) => {
  world(on, argv => (argv[0] === 'printenv' ? ok(argv) : { deny: 'failed to start: ENOENT: $.process.run(/home/abort/x) aborted' }))
  expect(await drawOrEngine($)).toContain('renderer not found')
})

test('a printenv timeout that mentions "aborted" is a failure, reported at once', async ($, on) => {
  const { w } = world(on, argv => (argv[0] === 'printenv' ? { deny: 'HooksError: x: $.process.run(printenv) aborted: still running after 2000ms' } : ok(argv)))
  expect(await drawOrEngine($)).toContain('printenv HOME failed')
  expect(w.logs.some(l => l.includes('printenv HOME failed'))).toBe(true)
})

test('the abort report text is stable: logged once at the threshold across many renders, with a recovered note', async ($, on) => {
  let spawns = 0
  const { w } = world(on, argv => (argv[0] === 'printenv' ? ok(argv) : ++spawns <= 8 ? ABORTED('/h/r') : result(0, GOOD)))

  for (let i = 0; i < 8; i++) await drawOrEngine($)
  expect(w.logs.filter(l => l.includes('refresh aborted')).length, 'one line for 8 aborts').toBe(1)
  expect(w.logs.find(l => l.includes('refresh aborted'))).toContain('5 renders in a row')

  expect(await drawOrEngine($)).toContain('myrepo main')
  expect(w.logs.some(l => l.includes('recovered after 8 aborted renders'))).toBe(true)
})

test('a real failure between aborts resets the streak, so non-consecutive aborts are not reported as a run', async ($, on) => {
  const seq: unknown[] = []
  const { w, clock } = world(on, argv => (argv[0] === 'printenv' ? ok(argv) : seq.shift()))
  seq.push(...[1, 2, 3, 4].map(() => ABORTED('/h/r')), result(1, '', 'down'), ABORTED('/h/r'))

  for (let i = 0; i < 4; i++) await drawOrEngine($)
  await drawOrEngine($) // real failure (exit 1)
  await clock.advance(6000) // past the 5 s back-off
  await drawOrEngine($) // abort number 5 overall, but 1 since the failure

  expect(w.logs.some(l => l.includes('refresh aborted'))).toBe(false)
})

// ── Remote Control record for the main status line, and the band hidden by default ──

const BIN_PATH = '/home/t/.local/bin/nerdflair-statusline'

test('the band row is not drawn without the debug flag, but the renderer is asked to write the rc record', async ($, on) => {
  const { w } = world(on, ok, { debug: false })

  const a = await drawOrEngine($)

  expect(a, 'hidden: the engine draws its own row').toBe('ENGINE-DEFAULT-ROW')
  expect(w.syncs, 'one sync, the session id and an empty surface label').toEqual([[BIN_PATH, '--rc-sync', 'sid-1', '']])
  expect(w.stdins, 'no --json refresh is spent on a row nobody sees').toEqual([])
  expect(w.logs).toEqual([])
})

test('with the flag the band is drawn exactly as before, and the sync still ran', async ($, on) => {
  const { w } = world(on, ok, { debug: true })

  const a = await drawOrEngine($)

  expect(a).toContain('myrepo main')
  expect(a).toContain('RC off')
  expect(w.syncs.length).toBe(1)
})

test('the sync is throttled to one per 2 s across renders, and asks again after', async ($, on) => {
  const { w, clock } = world(on, ok, { debug: false })

  await drawOrEngine($)
  await drawOrEngine($)
  await drawOrEngine($)
  expect(w.syncs.length, 'three renders in the same instant: one spawn').toBe(1)

  await clock.advance(2500)
  await drawOrEngine($)
  expect(w.syncs.length).toBe(2)
})

test('the surface label is the remote surfaces joined, never the terminal', async ($, on) => {
  const { w } = world(on, ok, { debug: false, surfaces: ['terminal', 'web', 'mobile'] })

  await drawOrEngine($)

  expect(w.syncs[0]?.slice(2)).toEqual(['sid-1', 'web+mobile'])
})

test('turning the flag on takes effect at the next sync', async ($, on) => {
  let debug = 0
  const { clock } = world(on, ok, { sync: () => result(0, `debug=${debug}\n`) })

  expect(await drawOrEngine($)).toBe('ENGINE-DEFAULT-ROW')
  debug = 1
  await clock.advance(2500)
  expect(await drawOrEngine($)).toContain('myrepo main')
})

test('no session id: nothing is written, the fault opens the row (no record yet) and is logged once', async ($, on) => {
  const { w } = world(on, ok, { sid: '', debug: true })

  const a = await drawOrEngine($)
  await drawOrEngine($)

  expect(w.syncs, 'never a record under a guessed name').toEqual([])
  expect(a).toContain('session id unknown')
  expect(w.logs.filter(l => l.includes('session id unknown')).length).toBe(1)
})

test('a failing sync is reported with the binary\'s words and backed off for 5 s; with the flag already on it shows in the row', async ($, on) => {
  let fail = false
  const { w, clock } = world(on, ok, {
    sync: () => (fail ? result(4, '', 'rc-sync: cannot write /c/rc-sid_1: Permission denied') : result(0, 'debug=1\n')),
  })
  expect(await drawOrEngine($)).toContain('myrepo main')
  fail = true
  await clock.advance(2500)

  const a = await drawOrEngine($)
  await drawOrEngine($)

  expect(a).toContain('rc sync failed')
  expect(a).toContain('Permission denied')
  expect(w.syncs.length, 'one good, one failed, then backed off').toBe(2)
  expect(w.logs.filter(l => l.includes('rc sync failed')).length).toBe(1)

  await clock.advance(5500)
  await drawOrEngine($)
  expect(w.syncs.length).toBe(3)
})

test('an answer without a debug line (old binary) is a failure: logged, and with no record yet it opens the row', async ($, on) => {
  const { w } = world(on, ok, { sync: () => result(0, 'something else\n') })

  expect(await drawOrEngine($)).toContain('rc sync failed')
  expect(w.logs.some(l => l.includes('rc sync failed'))).toBe(true)
})

test('a superseded sync is retried after a short back-off, not reported, and not respawned by every render', async ($, on) => {
  let n = 0
  const { w, clock } = world(on, ok, { debug: false, sync: () => (++n <= 3 ? { deny: 'HooksError: $.process.run(x) aborted' } : result(0, 'debug=0\n')) })

  await drawOrEngine($)
  await drawOrEngine($)
  await drawOrEngine($)
  expect(n, 'three renders in the same instant: one spawn').toBe(1)

  await clock.advance(600)
  await drawOrEngine($)
  expect(n, 'asked again once the back-off passed').toBe(2)
  await clock.advance(600)
  await drawOrEngine($)
  await clock.advance(600)
  await drawOrEngine($)
  expect(n).toBe(4)
  expect(w.logs.filter(l => l.includes('rc sync'))).toEqual([])
})

test('NERDFLAIR_RC_TIMER=0 turns the session.start timer off (test-only switch), so ui.render alone can be observed', async ($, on) => {
  const { w, clock } = world(on, argv => (argv[0] === 'printenv' && argv[1] === 'NERDFLAIR_RC_TIMER' ? result(0, '0\n') : ok(argv)), { debug: false })
  await $.session.start({ cwd: '/work', surface: 'terminal' } as never).catch(() => undefined)

  await clock.advance(20000)
  expect(w.syncs, 'no timer, no render: nothing wrote the record').toEqual([])

  await drawOrEngine($)
  expect(w.syncs.length, 'ui.render still does').toBe(1)
})

test('the record is kept by a timer too, so it does not depend on ui.render firing for a hidden band', async ($, on) => {
  const { w, clock } = world(on, ok, { debug: false })
  // nothing sits beneath the plugin's session.start hook, so its next(e) rejects; the timer is set before that
  await $.session.start({ cwd: '/work', surface: 'terminal' } as never).catch(() => undefined)
  expect(w.syncs.length, 'nothing yet: no render has happened').toBe(0)
  await clock.advance(5100)

  expect(w.syncs.length).toBeGreaterThanOrEqual(1)
  expect(w.syncs[0]?.slice(1, 3)).toEqual(['--rc-sync', 'sid-1'])
})

// ── U4: ONE code switch (BAND_ROW_ENABLED) plus the runtime flag ─────────────

test('constant false and no flag: the row is hidden, and nothing in the band path ran', async ($, on) => {
  const { w } = world(on, ok, { debug: false })

  expect(await drawOrEngine($)).toBe('ENGINE-DEFAULT-ROW')
  expect(w.stdins, 'no --json refresh').toEqual([])
  expect(w.logs.filter(l => l.includes('plugin bug'))).toEqual([])
})

test('a first failing sync (flag unknown, no record) opens the row with the binary\'s words, logged once', async ($, on) => {
  const { w } = world(on, ok, { sync: () => result(4, '', 'rc-sync: cannot write /c/rc-sid_1: Permission denied') })

  expect(await drawOrEngine($)).toContain('Permission denied')
  await drawOrEngine($)
  expect(w.logs.filter(l => l.includes('rc sync failed') && l.includes('Permission denied')).length).toBe(1)
})

test('hidden: a failed renderer refresh and the stale-copy "no recorded reason (plugin bug)" line can never appear', async ($, on) => {
  const { w } = world(on, argv => (argv[0] === 'printenv' ? ok(argv) : result(1, '', 'boom')), { debug: false })

  for (let i = 0; i < 3; i++) expect(await drawOrEngine($)).toBe('ENGINE-DEFAULT-ROW')
  expect(w.logs.some(l => l.includes('plugin bug') || l.includes('renderer failed'))).toBe(false)
})

test('the session id goes to --rc-sync verbatim, so the file is the one `--rc-name <id>` names (the binary owns the rule)', async ($, on) => {
  const { w } = world(on, ok, { debug: false, sid: 'a/b c' })

  await drawOrEngine($)

  expect(w.syncs[0]?.[1]).toBe('--rc-sync')
  expect(w.syncs[0]?.[2], 'raw id, no sanitising of its own').toBe('a/b c')
})

test('once a sync has succeeded, a later fault is log-only: the row stays hidden (the main line goes amber via the 120 s rule)', async ($, on) => {
  let fail = false
  const { w, clock } = world(on, ok, { sync: () => (fail ? result(4, '', 'rc-sync: disk full') : result(0, 'debug=0\n')) })
  expect(await drawOrEngine($)).toBe('ENGINE-DEFAULT-ROW')
  fail = true
  await clock.advance(2500)

  expect(await drawOrEngine($)).toBe('ENGINE-DEFAULT-ROW')
  expect(w.logs.filter(l => l.includes('rc sync failed') && l.includes('disk full')).length).toBe(1)
})

test('a HOME fault that healed is not drawn later as a stale marker once the flag turns the row on', async ($, on) => {
  let home = 0
  let debug = 0
  const { clock } = world(on, argv => (argv[0] === 'printenv' ? (++home === 1 ? result(1, '', 'printenv: gone') : result(0, '/home/t\n')) : ok(argv)), {
    sync: () => result(0, `debug=${debug}\n`),
  })
  expect(await drawOrEngine($)).toContain('HOME lookup')
  await clock.advance(31000)
  expect(await drawOrEngine($)).toBe('ENGINE-DEFAULT-ROW')
  debug = 1
  await clock.advance(2500)

  const a = await drawOrEngine($)
  expect(a).toContain('myrepo main')
  expect(a).not.toContain('HOME lookup')
})

test('the committed default of the code switch is false, so a debugging edit cannot ship', () => {
  expect(bandRowDefaultForTests()).toBe(false)
})
