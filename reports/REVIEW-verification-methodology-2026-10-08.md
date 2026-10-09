# Review: verification methodology for the ccusage replacement (2026-10-08)

Scope: attack the instruments (`tests/validate-burn-block.sh` and the argument built on it), not the renderer. Read-only review. Evidence from the live ledger `~/.claude/nerdflair-usage.tsv` (32,007 rows, 2.5 MB at review time).

## Verdict

**The evidence merely looks sufficient. It is not sufficient to retire ccusage on its own.**

- The one live comparison (ours $240.99 vs ccusage $216.20, 12%) is a single sample at a 25% tolerance, uses a window that is not the shipped one, and checks block only (burn rate is unchecked).
- It also ran against an algorithm that a real defect (finding 2) made wrong: non-monotonic cost counters.
- ccusage and Claude Code's `total_cost_usd` read the same token counts, so they are not independent for token-level flaws.
- What would be sufficient: exact golden fixtures run through BOTH shipped renderers (bash and Rust), including reset, out-of-order, tail-cap and window-boundary cases, plus a stable-ratio check against the payload's server-side `rate_limits.five_hour.used_percentage`.
- Once those pass, ccusage can be retired. It was never the proof of correctness; it is a smoke test with an unvalidated price table.

## Findings

### 1. Critical - harness reimplements the algorithm instead of running the renderer
- Where: `tests/validate-burn-block.sh:90-98`. The shipped algorithm is `_window_spend` at `scripts/statusline.sh:1512-1535` (Rust has its own copy).
- Proves vs claimed: it proves that a private awk sum is near ccusage. It does not prove the shipped bash or Rust code is right.
- The two disagree on definition: the harness uses `max - min` per session, the renderer uses last-minus-first by timestamp (`statusline.sh:1521-1528`).
- Fix: drive the real renderer (payload with `rate_limits.five_hour.resets_at`, `NERDFLAIR_REPO_COST_FILE` pointing at a copy of the ledger) for bash and Rust, and parse the printed segment. No algorithm code in the harness.
- **Status 2026-10-09: FIXED.** The harness holds no algorithm code. It builds a payload whose `resets_at` reproduces ccusage's elapsed block, runs the shipped renderer (Rust by default, the bash reference with `NERDFLAIR_VALIDATE_IMPL=scripts/statusline.sh`), and reads the block and burn figures off the output by their icons. Run both ways on the live ledger at a 2.9 h block age: Rust $147.00, bash $146.77 (the two agree), ccusage $108.17, so ours is 35.9% above it and the 25% tolerance FAILS. That is a real result, not a harness fault, and it is tracked as its own open item: finding 4 (ccusage floors its block start to the hour, so its window can start up to 59 minutes earlier) is the leading suspect, though it would make ccusage the larger figure, not smaller, so it does not explain this by itself, and the review asked for several block ages before anything is concluded. Two harness bugs found on the way: burn and block only render when the session cost is above zero, and which row they land on is the renderer's business.

### 2. Critical - cost counters are non-monotonic in the real ledger, and no instrument covered it
- Evidence: 11 sessions have a cumulative cost that goes down. 10 of the drops fall inside the last 5 h. Examples: `3c667d56` 677.6 -> 435.5 (after a 13.6 h gap), `a13dd10d` 517.2 -> 0.94, `873fd3f9` 2215 -> 2051. Zero within-session time inversions.
- Proves vs claimed: any (last - first) or (max - min) rule is wrong across a drop. The 12% agreement was obtained with a rule that is wrong on this data and said nothing about it.
- Fix: sum positive increments between consecutive time-ordered samples per session. Use it in bash, Rust and any harness, and pin it with a golden case that includes a drop followed by regrowth. (Team lead reports this is done, with a golden case; keep a regression for the drop-then-regrow shape.)
- **Status 2026-10-09: FIXED.** Both renderers sum positive increments per session (a drop rebases and adds nothing). Pinned by `tests/burn-block-golden.sh` cases 1, 5 and 8 (falling counter, mid-window reset with regrowth, backwards row) and the `monotonic` mutation in `tests/golden-mutation.sh`, which the goldens kill.

### 3. High - harness checks block only; burn rate is unvalidated
- Where: `:103` compares one number. Burn is `statusline.sh:1550-1557`.
- Proves vs claimed: the name and header promise both burn and block.
- Fix: replay a fixed ledger through the renderer and assert exact burn (`spent / span`), including the `NERDFLAIR_BURN_MIN_SPAN` threshold, the sub-minimum fallback to the session average, and the zero-spend suppression.
- **Status 2026-10-09: FIXED.** Cases 1, 2 and 4 assert exact burn (`36.00 / 0.75h = $48.00/h`), the minimum-span suppression and the empty-ledger case; the `min_span` mutation is killed. The harness now also reads and prints burn, reported rather than judged because the windows differ.

### 4. High - window is ccusage's, not the shipped one
- Where: `:83` and `:90` derive the window as `5h - remaining`. The shipped window is `rl_5h_reset - 18000` (`statusline.sh:1600-1604`).
- ccusage floors its block start to the hour, so the windows can differ by up to about 59 min, which is up to about 20% of a block's spend.
- Proves vs claimed: it validates a window nobody ships.
- Fix: anchor on the payload's `resets_at`, and use ccusage only to report the delta between the two windows as a diagnostic.
- **Status 2026-10-09: PARTLY FIXED.** The shipped renderer anchors on `resets_at` and the harness reproduces ccusage's elapsed block through `resets_at`. It still does not print the delta between ccusage's hour-floored start and ours as a diagnostic. OPEN, small.

### 5. High - independence claim is overstated
- Both methods read API-reported token counts; only the price table and aggregation differ. Shared flaws are invisible (cache tier pricing, long-context or fast-mode premiums, subagent usage).
- Proves vs claimed: it catches aggregation and window bugs, not pricing or accounting errors, and it never tests that the ledger faithfully records Claude Code's figure.
- Fix: state the limitation in the harness header. Test ledger arithmetic with fixtures. Add a transcript-level recount against Anthropic's published opus-5 prices (cache tiers included).
- **Status 2026-10-09: FIXED for the claim, OPEN for the recount.** The harness header now says the methods differ only in aggregation and pricing and that upstream flaws are invisible to it. The transcript-level recount at published prices is not done; see finding 6 and task B5.

### 6. High - "ccusage --no-offline is right" is unproven and circular
- Evidence: only offline was shown wrong (86 -> 213); 213 is vouched for by the 12% agreement, which is vouched for by 213.
- Fix: recompute one 5 h transcript window by hand from published prices, then compare with both numbers.
- **Status 2026-10-09: FIXED (recounted, and ccusage is the one that is wrong).** Two sessions that ran entirely on `claude-sonnet-5-5` were priced by hand from the published rates ($2 in, $10 out, $0.20 cache read, $4 for a 1 h cache write per MTok) and compared with the ledger and with `ccusage session --no-offline`:

  | session | tokens (out / cache write / cache read) | by hand | ledger | ccusage |
  |---|---|---|---|---|
  | `24f3b1b2` | 58,447 / 204,331 / 12,474,761 | $3.90 | $3.90 | $2.65 |
  | `29f0dce2` | 103,439 / 328,606 / 27,545,531 | $7.86 | $7.86 | $5.10 |

  The ledger, which is Claude Code's own `total_cost_usd`, matches the published price to the cent. ccusage reproduces its own figure only with cache reads at $0.10 per MTok, half the published $0.20, so it undercounts every cache-heavy session on the newest models. That is the whole 35% gap in the live comparison (sessions that began inside the window come out 1.5 to 1.8 times ccusage's figure), not a ledger or window defect. ccusage stays a smoke test for window and aggregation bugs and cannot be the price authority.

### 7. High - tolerance and sample size cannot detect meaningful defects
- Where: `:31` (`TOLERANCE_PCT=25`), single run.
- These wrong implementations still pass at 25%: a 4 h or 6 h window, 20% of sessions missing (headless, `claude -p`, never rendering the statusline), a wrong repo filter, ignoring resets, counting only the largest sessions.
- 17 of 22 in-window sessions already had more than $0.50 at their first in-window sample, so a lot of spend predates the first sample and truncation can be large.
- Fix: exact golden fixtures for correctness; ccusage as advisory at about 10% after window alignment, and repeated at several block ages (about 1 h, 3 h, 4.8 h) because a real defect drifts with age.
- **Status 2026-10-09: PARTLY FIXED.** Exact goldens now carry correctness and ccusage is the smoke test. Still open: running the comparison at several block ages (about 1 h, 3 h, 4.8 h) and tightening the tolerance to about 10% once the gap in B5 is explained.

### 8. Medium - direction-of-bias claim is a rationalisation
- Where: `:112-115`. The text says ours should be HIGH and in the same sentence says truncation "cuts the other way".
- All structural biases found push ours low (first-sample truncation, missing headless sessions, 60 s lag, `now` captured before a ccusage run that can take 180 s).
- Proves vs claimed: a high result would be excused rather than explained.
- Fix: delete the paragraph. Break the delta down per session and per model and explain the largest contributors.
- **Status 2026-10-09: FIXED.** The paragraph that excused a high result is deleted. The per-session and per-model breakdown of the delta is still to do, in B5.

### 9. Medium - harness reads the whole ledger; the renderer reads the last 1 MiB
- Where: `:98` vs `statusline.sh:1494-1505`.
- Proves vs claimed: the tail-truncation edge (a session whose first in-window rows precede the tail start) is never exercised. The ledger is already 2.5 MB.
- Fix: golden case with a ledger larger than `NERDFLAIR_LEDGER_TAIL_BYTES` whose window start falls before the tail boundary. Test through the renderer.
- **Status 2026-10-09: FIXED.** Golden case 7 uses a tail cap shorter than the block window and asserts the suppression; the harness gives the cap room on purpose and says why.

### 10. Medium - parse and clock soft spots, so a wrong parse can fabricate a PASS
- Where: `:74-83`, `:50`.
- Seconds-only "59s left" parses to 0 remaining, so `elapsed` silently becomes 18000 (full 5 h). `$1,216.20` is read as 216.20. `now` is taken before the up-to-180 s ccusage run, but remaining time is measured after it.
- Fix: capture `now` after ccusage returns, parse `[0-9,]+`, strip commas, bound `elapsed` to 0..18000, and exit 2 when the "left" clause does not match at all.
- **Status 2026-10-09: FIXED.** `now` is taken after ccusage returns, costs parse `[0-9,]+` with commas stripped, "59s left" is parsed, `elapsed` is bounded to 0..18000, and a missing "left" clause exits 77.

### 11. Medium - SKIP (exit 2) can be read as pass; stub check can reject a legitimate shim
- Where: `:25`, `:38-48`. Nothing currently calls the script, so no live misuse, but `|| true` or `[ $? -ne 1 ]` would turn SKIP into PASS.
- The `<100000` byte check also rejects a real node shim from `command -v ccusage`, giving a permanent SKIP.
- Fix: a distinct SKIP code (77), print the reason on stdout, and require explicit exit 0 in any release gate. Replace the size heuristic with `ccusage --version` output.
- **Status 2026-10-09: FIXED.** Every could-not-run path exits 77, with the reason on stdout, and the stub check runs `ccusage --version` instead of testing a file size. A release gate must still require exactly 0.

### 12. Medium - per-session file order is assumed to be time order
- Evidence: 0 inversions in the live ledger, but nothing enforces it. Each render takes `$EPOCHSECONDS` before the flock (`statusline.sh:1206-1208`); the stamp file is touched only after the append. Two renders of one session near the 60 s boundary can both be "due" and append out of order.
- Effect: bounded (cents), because up-down-up counts the up leg twice.
- Fix: in the positive-increment pass, skip any row whose epoch is lower than the previous accepted row of that session, or sort per session by epoch. Add a golden case with a swapped pair.
- **Status 2026-10-09: FIXED.** A row whose epoch is lower than the previous accepted row of its session is skipped, in both renderers. Golden case 8 holds a swapped pair and the `ordering` mutation is killed.

### 13. Low - ccusage input environment is unrecorded
- Different transcript roots, `CLAUDE_CONFIG_DIR` or `TZ` change what ccusage scans.
- Fix: print the transcript roots, file count and TZ it used.
- **Status 2026-10-09: FIXED.** The harness prints the transcript root, the file count and TZ it scanned.

### 14. Low - degenerate outputs
- `b <= 0` prints "nan FAIL" (`:104`); an empty ledger window gives -100%. Both fail safely but read oddly.
- Fix: print "no ccusage spend in block" and "no ledger rows in window" explicitly.
- **Status 2026-10-09: FIXED.** Zero ccusage spend exits 77 with a plain message; an empty ledger window is a failure to measure and exits 1.

## Tests that cannot fail / missing positive controls

- **The harness itself cannot fail on the defects that matter.** Dropping a fifth of the sessions, or using a 4 h window, still passes at 25% (finding 7). It has no positive control: no run with a deliberately broken implementation that must FAIL.
- **Arm missing:** a mutation arm. Deliberately break the algorithm (revert to last-minus-first, drop the repo filter, shorten the window) and require the golden suite to fail. Without it there is no evidence the suite can detect those regressions.
- **Arm missing:** a negative control for the ccusage comparison, such as the offline figure. It should FAIL; if it passes, the tolerance is too wide to mean anything.

## What would be sufficient

1. Golden fixtures through both the bash and Rust renderers, asserting exact cents: monotone session, mid-window drop then regrowth, session starting before and inside the window, interleaved sessions, swapped pair, ledger larger than the tail cap, empty ledger, window just rolled over, garbage row. Parity of bash and Rust already comes from the byte-identity difftest.
2. A mutation run showing each golden case fails when its rule is broken.
3. A stable-ratio check of ledger dollars against the payload's `used_percentage` over several intervals (independent, server-side).
4. A transcript-level recount against published opus-5 prices for one window, to settle which price table is right.
5. ccusage kept as an advisory comparison only, at a tightened tolerance, repeated at several block ages.

On this machine no fully independent check of dollars exists. Honest position to record: dollar correctness rests on Claude Code's own `total_cost_usd`; the implementation's correctness rests on the golden and mutation tests, with the `used_percentage` ratio as the only independent sanity signal.
