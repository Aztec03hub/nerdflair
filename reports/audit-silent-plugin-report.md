# Silent-failure audit: nerdflair band plugin

Scope: band/hooks/register.tsx (553 lines), band/popup.sh, band/hooks/hooks.json, band/.claude-plugin/plugin.json, band/tsconfig.json, BIN()/HOME/printenv lookup. Read-only; nothing was run.

Standard: every absorbed, downgraded or worked-around failure must be logged once, with the reason, somewhere durable or visible. Degrade AND surface.

Facts from the typings (band/.claude-plugin/types/claude-code/index.d.ts) that shape the fixes:
- `$.ui.log(text, { to: 'debug' })` (line 2440) writes to the debug log alone; default `to` is the transcript as a dim system row. Either is a durable surface. No file API is needed.
- `$.process.run` with `timeoutMs` kills the child and REJECTS (line 8113). A child ended by a signal reads as exitCode 1 (line 8127). `ProcessRunResult` also has `isStdoutTruncated` (line 8148).

## Ranked findings

### S1 (HIGH). printenv / HOME failure: `return next(e)` with no reason (lines 294-298)
```
const h = await $.process.run(['printenv','HOME'], {timeoutMs:2000})
HOME = h.exitCode === 0 ? h.stdout.trim() : ''
if (!HOME) return next(e)
```
- Absorbs: printenv missing, non-zero exit, empty HOME. Band silently replaced by the engine's own UI. `lastError` is never set, so even the red error path cannot fire.
- Surfaced today: no. Not even debug.
- Severity: user silently loses the band, every render, forever (HOME stays '' so it retries and fails quietly each render).
- Also: the `run` call is outside any try. A timeout or spawn failure REJECTS the render hook. Whether the engine catches and reports that is unverified.
- Fix: wrap in try; on failure or empty, set `lastError = 'HOME lookup failed: ' + reason` and fall through to the red-band branch (return the error Box, not `next(e)`). Log once via a `reportOnce(reason)` helper (see end).

### S2 (HIGH). `return next(e)` when no cache and no lastError (line 394)
```
if (!cache || cache.segs.length === 0) { if (!lastError) return next(e) ... }
```
- Absorbs: renderer returned exit 0 with `segments: []` (line 365 `?? []`), or `segments` missing from the JSON. Both yield an empty list with `lastError === ''`, so the engine's fallback is drawn and nothing says why. Also covers the stale-cache expiry case where lastError is empty.
- Surfaced: no.
- Severity: silent loss of the band. `?? []` turns a malformed-but-parseable payload (e.g. `{}` or `{"error":...}`) into "no segments".
- Fix: at line 365 validate: `if (!Array.isArray(j.segments)) throw new Error('renderer JSON has no segments array')`; treat an empty array as an error `'renderer returned 0 segments'`. Then this `next(e)` is reachable only before the first render, when it is legitimate. Even there, mark it.

### S3 (HIGH). lastError is sticky, never cleared, and logged nowhere (lines 139, 362, 371, 377, 393-399)
- `lastError` is set on failure and never reset on success. Once set, any later empty-segs state shows a stale reason, and a later success followed by a different silent path shows the old message. It is also not rate-limited or logged, so a transient failure is only visible while the band is empty, and after the 30 s STALE_MS drop it shows only if the cache is also empty.
- Surfaced: red band text only, and only when `cache` is null. If a good cache exists and the renderer starts failing, the user sees OLD numbers for up to 30 s with no error (see S5).
- Fix: clear `lastError = ''` on success (line 377). Add a durable log: call `$.ui.log` to debug once per distinct reason (dedupe on string).

### S4 (HIGH). `JSON.parse` of renderer stdout (line 365) goes to the generic catch with truncated, non-specific text
- Absorbs: parse errors. Handled by the catch at 366-373, which does set lastError (CORRECT in spirit) but: `String(err).slice(0,200)` loses which step failed (usage? cwd? run? parse?), and the failing stdout is not shown. The comment at 173-176 documents that Node's parse message embeds raw input, which is why `plain()` exists (correct).
- Severity: surfaced as red band text only while cache is empty; otherwise hidden (S5). Not logged.
- Fix: tag the stage (`'parse: ' + msg`), include `r.stdout.slice(0,80)` through `plain()`, log once.

### S5 (HIGH, wrong numbers). Failed refresh keeps old figures for 30 s with no indication (lines 377-380)
```
if (segs) cache = {at: now, segs}
else if (cache && now - cache.at > STALE_MS) cache = null
```
- Absorbs: any refresh failure for the first 30 s after the last good one (and TTL is 2 s, so the renderer is retried every render). During that window the band shows stale cost, rate limits, burn, branch, RC state, labelled as live, with no error.
- Surfaced: no, until 30 s pass. After that the band goes red (correct), but `lastError` is the only trace.
- Severity: wrong numbers for up to 30 s. The RC chip reads `cache.segs.find('remote_control')` (line 415), so the pill can show a stale on/off state.
- Fix: when a refresh fails and a cache exists, keep drawing it but append a dim-red marker such as `stale 12s: <reason>` as an extra Text, and log once. Alternatively shrink STALE_MS. The honest version is the marker.

### S6 (HIGH). Default values invent plausible numbers (lines 314-337)
- `u.rateLimits?.find(...)` (314-315): if `rateLimits` is missing or the entry is absent, `five`/`seven` are undefined and `rate_limits: {}` is sent. The limits segment silently disappears. A missing window and "API did not give it" are indistinguishable.
- `u.context?.window ?? 200000` (328): a missing context object becomes a 200k window. The renderer then computes compaction ETA and context percent against a made-up size. Wrong numbers, silently.
- `u.context?.tokens ?? 0`, `u.context?.percent ?? 0` (329, 331): shows 0% context used when unknown.
- `u.cost?.usd ?? 0` (334): shows $0 when unknown. Feeds burn, block and repo total. Note the renderer appends this to the shared `~/.claude/nerdflair-usage.tsv` keyed by session id (comment lines 306-311), so a bogus 0 can be WRITTEN into the cross-session ledger, not just displayed.
- `total_duration_ms: 1, total_api_duration_ms: 1` (335-336): hard-coded. Throughput and API-time segments therefore render nonsense or are suppressed with no note. `transcript_path: '/nonexistent/band.jsonl'` (322): deliberate, but any renderer segment that needs the transcript silently degrades.
- `epoch(t)` (318-319): an unparseable `resetsAt` gives `NaN`, which `JSON.stringify` turns into `null`. The renderer then sees a null reset with no warning.
- Surfaced: no.
- Fix: build the payload with explicit presence checks. For each missing field, omit it (not default it) and record a one-time note `'usage.context missing, context segments unreliable'`. Do not write `0`/`200000`. If omitting a field makes the renderer choke, that failure then flows through S2/S4 and is reported. Validate `Number.isFinite` in `epoch`.

### S7 (MED). Renderer exit code and stderr: surfaced, but truncated and not logged (lines 357-364)
- This is the documented "OTHER silent path" fix and it is mostly CORRECT: non-zero exit and empty stdout set lastError with exit code and 160 chars of stderr.
- Gaps: (a) stderr is not passed through `plain()` at set time (it is at display time, line 397, so OK). (b) A zero exit with non-empty stderr (renderer warnings) is ignored. (c) `isStdoutTruncated` is never checked, so a >4 MiB stdout would reach JSON.parse as a cut string; it would at least fail loudly through S4. (d) Signal kills read as exit 1 with a possibly empty stderr, giving `exit 1: (no stderr)`. (e) A missing binary gives a spawn error, which is a rejection and goes to the catch (surfaced via red band, fine).
- Fix: log once to debug; include `isStdoutTruncated`; on exit 0 with stderr, log stderr to debug.

### S8 (MED). Timeouts and the in-flight guard (lines 269-271, 302-376)
- 5 s renderer timeout (355): rejects, caught, surfaced via lastError as the generic `Error: ...` string. Reason is present but not labelled as a timeout. Acceptable; label it.
- `$.process.run(...)` for printenv has 2 s timeout outside any catch (S1).
- `inflight ??= ... .finally(() => inflight = null)` (302-376): correct single-flight pattern. Because the inner async catches everything it can, `inflight` never rejects, so `await inflight` cannot throw. Verified by reading: the only throwing calls are inside the try. CORRECT.
- Subtle: all concurrent renders await the same refresh, but only the first one assigns `cache` (line 377 runs for each awaiter with its own `now`); harmless.
- `await $.clock.now()` (293), `await $.session.surfaces()` (385), `$.ui.resolve(e)` (392) are outside any try. A rejection from any of them rejects the whole render hook. What the engine does with a rejected hook is NOT verified; best case it logs and draws its own UI silently, worst case it breaks the UI. Fix: wrap the entire handler body in one try/catch that logs once and falls back to `next(e)` (degrade AND surface), keeping the plugin from ever breaking the UI.

### S9 (MED). Popup spawn is fire-and-forget (lines 486-490)
```
void $.process.run(['bash', POPUP(), String(x), title, bodyText], {timeoutMs: 60000})
```
- Absorbs: the returned promise is voided. A rejection (timeout at 60 s, spawn failure, bash missing, popup.sh missing because sync-local-plugin.sh was not re-run) becomes an unhandled rejection with no message, and a non-zero exit is never read. The click does nothing and nothing says why.
- Surfaced: no.
- Severity: user clicks a readout and nothing happens, with no clue. Also, if `HOME` is wrong the path is wrong, same silence.
- Fix: `.then(r => { if (r.exitCode !== 0) report('popup exit ' + r.exitCode + ': ' + r.stderr) }, err => report('popup: ' + err))`. Show it via `$.ui.toast` or log. Also note the 60 s timeout is the popup's lifetime: if the user leaves the popup open it is killed with a rejection that must not be reported as an error.

### S10 (MED). popup.sh silent exits (band/popup.sh lines 27-28, 31, 43-46)
- Line 27: `command -v tmux ... || exit 0`. Line 28: `[[ -n "${TMUX:-}" ]] || exit 0` with the comment "no popup, and no error either". Exit 0 hides the reason from S9's exit-code check. Outside tmux the click does nothing and the user is not told that popups need tmux.
- Line 31: `tmux display-message ... 2>/dev/null || echo 120`: a failed tmux query falls back to 120 columns with the error discarded.
- Line 43-46: `tmux display-popup ... 2>/dev/null`: ALL tmux errors (popup unsupported on tmux < 3.2, no client, bad geometry) discarded; script exits with tmux's status, but stderr is gone and S9 does not look at it anyway.
- Line 25: `BODY=${*:-}` joins args; harmless.
- Quoting is correct (`printf %q`), CORRECT.
- Fix: exit 3 with a stderr message for "no tmux" / "not in tmux", exit 4 with the real tmux stderr for display-popup failure (drop `2>/dev/null`, or capture and print). Pair with S9 so the plugin turns those into a visible toast. A fallback to 120 columns is acceptable only if it is stated once on stderr.

### S11 (MED). session.attach / session.detach hooks (lines 276-290)
- `await next(e)` then `$.session.surfaces()` after: if `next` or `surfaces` rejects, the plugin's bookkeeping is skipped and the rejection propagates (not swallowed, so not silent from the plugin; engine behavior unverified).
- `rcSince === 0` guard: if `$.clock.now()` returns 0 (it will not) the state is wrong. Not a real concern.
- Hot-reload loss of `rcSince`/`rcLeftAt` is disclosed in a comment (lines 149-153) and described as "honest enough": a documented downgrade that is not surfaced. Minor: the card text `seen attached for: Ns` is then wrong after reload. Suggest labelling it `since reload`.

### S12 (MED). RC state source fallback (lines 415-416)
```
const rcSeg = cache.segs.find(s => s.id === 'remote_control')
const rcOn = rcSeg ? rcSeg.text === 'rc on' : rcSeen.length > 0
```
- If the renderer omits the `remote_control` segment (older binary, version mismatch), the chip silently switches its source of truth from the bridge env var to `surfaces()`. The code's own comment (407-413) says surfaces() was measured to be WRONG (said terminal-only while remote control was attached), so this fallback can show "RC off" while attached, with no hint that it fell back.
- Also `rcSeg.text === 'rc on'` treats any other text (including a renamed or error value like `rc ?`) as OFF.
- Fix: if `rcSeg` is missing, show the chip as unknown (`? RC unknown`, amber) and log once; treat any text other than exactly `rc on`/`rc off` as unknown.

### S13 (LOW-MED). BIN() hard-codes `~/.local/bin/nerdflair-statusline` (line 23); POPUP() hard-codes the marketplace path (line 26)
- Missing binary: spawn failure, goes to the catch, surfaced in red (CORRECT), but the message is a raw error string and the user is not told the expected path or how to fix it.
- Stale binary: documented history at 166-172 (renderer returned ANSI text, parse failed). Now surfaced via red band. CORRECT, but there is no version check, so a renderer that is merely OLD (missing `remote_control` or `--json`) is not detected; see S12.
- Fix: on spawn/ENOENT or exit 127 say `renderer not found at <BIN()>; run the installer`.

### S14 (LOW). `budget()` clipping (lines 239-260)
- `if (cur === undefined || len(cur) <= SEG_MIN) break // at the floor`: if every segment is at the floor and the row still exceeds BAND_MAX, the loop stops and the band WRAPS (the exact failure the function exists to prevent) with no notice. Unlikely (needs ~20 segments).
- `?? ''` on `out[j]` / `texts[i]`: indexes are in range; harmless.
- Clipping itself is a visible, disclosed, intentional downgrade (the `…` and the full value in the popup). CORRECT.

### S15 (LOW). `colOf[i] ?? 0` (line 538)
- Index always in range; the default only matters on a bug. It would place the popup at the wrong column silently. Cosmetic.

### S16 (LOW). `card?.color ?? DIM`, `card?.title ?? s.id`, `: full` (lines 523-530)
- An unknown segment id (renderer newer than the CARDS table) is drawn grey with no card, no explanation. This is a graceful, visible downgrade (the text is still shown) and arguably fine; a one-time debug log `unknown segment id X` would make renderer/plugin drift detectable.

### S17 (LOW). Config files
- band/hooks/hooks.json: `{ "modules": ["./register.tsx"] }`. No failure handling to audit. If the module throws on load or fails typechecking, that is the engine's concern; what it does is unverified (and "Path escapes plugin directory" is a known failure documented in sync-local-plugin.sh).
- band/.claude-plugin/plugin.json: name, version, description only. Nothing absorbing.
- band/tsconfig.json: extends the vendored types; `include` covers `hooks`. No `strict` visible here (it is inherited from the extended file; not read). Unverified whether `noUncheckedIndexedAccess` is on, which affects the `?? ''` sites above.

## CORRECT sites (keep)
1. `plain()` (173-176): strips ANSI and control chars so a raw ESC cannot make the engine refuse the whole render; applied to lastError at display (397), surface names (385), segment text (460, 525). Correct, and the comment records the incident.
2. Catch at 366-373 sets `lastError` rather than swallowing, and the band shows it in red (the owner's stated mechanism).
3. Non-zero exit / empty stdout path (357-364) sets lastError with exit code and stderr (modulo S7 gaps).
4. STALE_MS drop (380) eventually prefers an error over frozen figures.
5. `inflight` single-flight with `.finally` reset (302-376).
6. `session.attach` / `detach` use `surfaces()` as state, timestamps only (documented).
7. `budget()` charges the RC chip as a fixed cost so it cannot be clipped to "RC ...".
8. popup.sh: `printf %q` quoting, `set -uo pipefail`, popup closes on any key, width clamp, "tmux times it out" design.
9. `rcSeen` re-read every render, not cached.

## Not verified
- What the engine does when a hook rejects or throws (the S1/S8 sites outside try). Typings say `process.run` timeouts reject; the engine's handling is unread.
- Whether `$.ui.log` is callable from inside `ui.render` without re-triggering a render loop, and whether it is rate-limited by the engine. The audit recommends deduped logging to keep it to once per distinct reason.
- `nerdflair-statusline --json` behavior (renderer source was out of scope): whether it writes to stderr on warnings, what it does with a missing field, and whether it writes `nerdflair-usage.tsv` rows from a defaulted payload (S6).
- Inherited tsconfig strictness (band/.claude-plugin/types/tsconfig.json not read).
- `$.session.usage()` actual return shape in each failure mode (the typings at 11420 and 12038 list `rateLimits: SessionRateLimit[]` as non-optional, which would make `?.` at 314/315 a no-op guard; whether `context`/`cost` are optional was not read). Line references to typings are from index.d.ts in band/.claude-plugin/types/claude-code.
- Actual behavior; nothing was executed.

## Suggested minimal implementation (one helper)
```ts
const seen = new Set<string>()
function report($: any, where: string, why: unknown) {
  const msg = `nerdflair-band: ${where}: ${plain(String(why)).slice(0, 300)}`
  lastError = msg
  if (!seen.has(msg)) { seen.add(msg); $.ui.log(msg, { to: 'debug' }) }
}
```
Use it at every site above; replace `return next(e)` at 297 and 394 with the red-band return so the engine's UI is only used before the first successful render; wrap the whole render body in one try/catch calling `report` then `next(e)`; clear `lastError` on a good refresh; add a visible stale marker (S5); stop defaulting numeric payload fields (S6).
