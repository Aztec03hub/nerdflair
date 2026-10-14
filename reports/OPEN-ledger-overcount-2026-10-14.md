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

## Hypotheses to test (none verified)

1. The host's `cost.total_cost_usd` for a session includes subagent spend that the
   transcripts count once, so a subagent-heavy session is priced above its transcripts
   in some way (cache-write TTL: subagents write 5-minute cache at 1.25x, the recount
   prices per call from `cache_creation`, the host may price them differently).
2. Sonnet 5.5 cache reads: the recount uses the same $0.20/MTok as the host (matched the
   ledger within 1% in aggregate on 2026-10-14), but TokenLens documents $0.10 for
   Sonnet 5.5 and Opus 5.5. A Sonnet-only, read-heavy session would be where a 2x on
   reads shows most.
3. A session id reused or resumed, so its cumulative cost counter restarted and a
   positive increment was counted twice.

## Next step

Compare 1cefdce1 call by call: sum the host's own per-call cost if the transcript has it,
against the recount, split by cache-read / cache-write / output, and check the ledger
rows around the 12:18 jump. Decide whether the ledger or the recount is right, then
either fix the renderer or the recount. Until then `validate-ledger.sh` stays strict and
fails; that failure is the point.
