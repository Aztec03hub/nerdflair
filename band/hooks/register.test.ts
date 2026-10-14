import { expect, mock, test } from 'claude-code/testing'

import { register, resetStateForTests } from './register'

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
function world(on: any, renderer: Run, opts: { usage?: object; now?: number } = {}) {
  resetStateForTests()
  const w = { logs: [] as string[], toasts: [] as string[], stdins: [] as string[], popups: [] as string[][] }
  const clock = mock.clock(on, { now: opts.now ?? 1_000_000 })
  register(on, {} as never)
  on('session.usage', async () => ({
    value: opts.usage ?? { startedAt: 0, context: { window: 200000, tokens: 1000, percent: 1 }, rateLimits: [], cost: { usd: 1 } },
  }))
  on('session.cwd', async () => ({ value: '/work' }))
  on('session.id', async () => ({ value: 'sid-1' }))
  on('session.model', async () => ({ value: 'opus' }))
  on('session.surfaces', async () => ({ value: ['terminal'] }))
  on('ui.log', async (_$: any, e: any) => {
    w.logs.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', async (_$: any, e: any) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('process.run', async (_$: any, e: any) => {
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

  const a = textOf(await $.ui.render(BAND as never))
  await $.ui.render(BAND as never)

  expect(a).toContain('nerdflair-band: HOME lookup')
  expect(a).toContain('printenv: gone')
  expect(w.logs.filter(l => l.includes('HOME lookup')).length, 'logged once across two renders').toBe(1)
})

test('printenv rejecting (spawn failure or timeout) is reported, not thrown through the render', async ($, on) => {
  const { w } = world(on, argv => (argv[0] === 'printenv' ? { deny: 'spawn printenv ENOENT' } : ok(argv)))

  const a = textOf(await $.ui.render(BAND as never))

  expect(a).toContain('HOME lookup')
  expect(w.logs.some(l => l.includes('HOME lookup') && l.includes('ENOENT'))).toBe(true)
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
  await clock.advance(3000)
  expect(textOf(await $.ui.render(BAND as never))).not.toContain('stale')
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
