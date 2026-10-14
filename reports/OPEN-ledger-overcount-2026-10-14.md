# OPEN: the ledger overcounts one session against a hand recount (2026-10-14)

Found while verifying the shell-logging branch. Not caused by it: `price-recount.py`
gives the same figures before and after that branch.

## What `tests/validate-ledger.sh` showed

Compared on all sessions, 1 h read -23% (the ledger LOWER than the recount). Cause
found and fixed in the test: sessions that never render a status line (headless
`claude -p`, hook runs, subagent-only sessions) cannot reach the ledger, so their spend
is a coverage gap, not an error. The recount can now be limited to sessions that are in
the ledger (`price-recount.py --ledger FILE`); the gap is printed as a separate coverage
line ("NOT-IN-LEDGER $5.14 across 8 sessions" at 1 h). Like for like, 1 h is +0.6%.

At 3 h and 4.8 h the like-for-like figure is ABOVE the recount, +7.8% and +9.7%, past
the +2% bound for the dangerous direction (an overcount reads as money spent). Earlier
today the unrestricted comparison hid this, because the unrendered sessions' spend
cancelled it.

## Where it comes from

One session. Per-session increments over the last 3 h (first in-window sample as the
baseline, as the renderer does):

    session 1cefdce1  ledger 17.62  recount 14.81 (13.68 by a second count)  +2.82
    every other rendered session: within $0.12 of the recount

1cefdce1 is a Sonnet 5.5-only session with 54 transcripts (53 subagent files). Largest
single ledger jumps: 2.13, 2.05, 1.77, 1.65, 1.56.

## What the investigation found (2026-10-14, same day)

Method: for the session, regress the ledger's cumulative cost on the transcripts'
cumulative token counts over the 3 h window (176 samples, no intercept, baseline
subtracted); the fit is tight (rmse $0.02-0.04), so the host's effective per-token
rates can be read off. Window tokens: 83.9 M cache read, 1.52 M cache write,
0.17 M output (0.13 M of it in subagent transcripts); ledger delta $17.62.

Effective rates the host charged, against published Sonnet 5.5:

    cache read   $0.11-0.12 /MTok   published $0.10   (+10-22%)
    cache write  $3.7-4.0  /MTok    published $2.5 (5m) / $4.0 (1h), about $3.1 blended here
    output (sub) $15-16    /MTok    published $10     (+50%)
    output (main) not determined (only 0.04 MTok in the window; the fit is noise)

Ruled out:
- Hypothesis 2 as stated (the recount's cache-read rate): the host's effective read rate
  is about the published $0.10, not 2x it. The recount at $0.10 gives $14.81 for the
  window; at $0.20 it gives $23.19; the host charged $17.62, in between.
- A US-geography (x1.1) or fast-mode multiplier: every call in the three sessions
  checked reports inference_geo global/not_available and speed standard/null.
- Compaction calls with zero top-level usage: calls carrying usage.iterations have a
  single iteration that duplicates the top-level usage, none has zero top-level usage.
- A session id reused or resumed (hypothesis 3), for THIS window: the ledger samples
  for 1cefdce1 hold exactly one counter reset ($35.64 -> $0.0003, a resume 3.5 days before
  the window), so none falls inside the 3 h and 4.8 h windows. (An earlier draft of this
  line said "no reset appears" without having checked; it was checked afterwards.)

Still open, in order of likelihood:
1. The transcripts under-record tokens for subagent calls. In subagent transcripts the
   same message id appears on several lines with output_tokens growing as it streams
   (examples 20 -> 363, 3 -> 1138, 7 -> 2050: sum over first lines 90,808, over last
   lines 556,600). The recount keeps the last line. If even the last line is short of the
   final count, every subagent-heavy session reads low in the recount and the ledger (the
   host's own figure) is right. This fits the +50% on subagent output; it does not by
   itself explain the +10-22% on reads and writes.
2. Calls the host bills to the session that never reach a transcript (titles, hook
   or memory calls made through the host).
3. A cache-write TTL mix: subagents write 5 m (x1.25), the main thread 1 h (x2).

## Next step

Find ground truth that is not either estimate: the host's own per-call cost if any
transcript line or debug log carries it, or an API usage export for the same hour.
Until then do not change the renderer on this evidence: the ledger is the host's own
number, and the recount is the less certain side for subagent sessions. The like-for-like
gate stays strict and failing so the gap stays visible.
