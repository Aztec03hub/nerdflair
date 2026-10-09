# Review: burn-rate and billing-block correctness (2026-10-08)

Scope: `ledger_tail`, `window_spend`, burn and block segments, transcript tail read, in rust/src/main.rs and scripts/statusline.sh. Read-only review; nothing was executed. Failing inputs are traces by reading, not observed runs.

Line refs: main.rs = rust/src/main.rs, sh = scripts/statusline.sh.

## Findings

### F1. High: block window not capped at resets_at
- Where: main.rs:1283-1294, sh:1600-1613.
- Both call window_spend(block_start, now) and gate only on now >= block_start. Nothing checks now < reset.
- Input: rate_limits.five_hour.resets_at = now-3600 (first render after waking from idle, before the payload refreshes). block_start = now-21600, so the sum covers 6h: a lapsed block plus 1h of the next. The segment shows that as the current block.
- Fix: if now >= reset, render idle (or treat the window as starting at reset). Generally use hi = min(now, reset). Change both files.

### F2. High: silent tail truncation
- Where: ledger_tail main.rs:2471-2496, sh:1494-1506.
- Nothing compares the oldest retained row's timestamp with `since`.
- Input: NERDFLAIR_LEDGER_TAIL_BYTES=65536. The block shows only the part of the 5h that fits, as if it were the whole block. Also happens at the 1 MB default once write volume rises.
- Fix: ledger_tail returns (text, truncated). If truncated AND the oldest in-tail timestamp > since, prefix the BLOCK figure with a plain-text lower bound (e.g. `>=$12.30`); do not render idle. Leave BURN unmarked (rate is span-normalised, so truncation shrinks spend and span together). A truncated tail that still reaches `since` is complete. Same in both files.
- Comment fix: coverage is cap / bytes-written-per-hour and depends on live session count. Do not hardcode "40 hours". Measured 40.8h (about 25 KB/h, roughly 340 rows/h) on 2026-10-08; about 16h with 14 fully active sessions. 40.8h is inside the 3-day full-resolution region, so compaction downsampling does not explain it.

### F3. Medium: burn span not anchored to now
- Where: main.rs:2553 and 1228-1230; sh:1532 and 1554-1555.
- Span = max(last_t) - min(first_t) over samples. After activity stops, the last hour's rows still give a rate.
- Input: all sessions active 10:00-10:30 at $20/h, idle after. At 10:55 it still shows $20/h.
- Fix: require now - hi <= ~180s for a live rate, else show nothing; or set hi = now so the rate decays.

### F4. Medium: mid-window counter reset loses spend
- Where: main.rs:2543, sh:1528 (endpoint compare only).
- Input: S rows 10.0, 11.0, then reset, then 1.0, 3.0: first 10.0, last 3.0, contributes 0, real spend about 3.0.
- Fix: per session in file order, sum positive increments; on a decrease rebase and add nothing. Status: ACCEPTED AND ALREADY FIXED by the lead, confirmed on the live ledger (11 sessions, 12 drops, 10.1% hourly understatement).

### F5. Low-Medium: transcript tail read
- Where: main.rs:662-665, sh:664-670.
- 5a. A last assistant line longer than the cap: the seek lands inside it, the first-line drop removes the rest, no "usage" line remains, context gauge shows 0%. Fix: if no match and the read started past byte 0, retry at 4x the cap up to a hard ceiling (16 MB), or scan backwards in chunks.
- 5b. The last line may be mid-append and unterminated; both fail JSON parse and show 0%. Fix: drop the final segment when the text does not end in `\n`, or keep the last line that parses.

### F6. Low: negative tail-byte env var reads whole file in Rust
- Where: main.rs:1206, 662. `env_int(...) as u64` turns -1 into u64::MAX, start = 0, whole file streamed (the unbounded read this change removes). Bash `tail -c -1` differs.
- Fix: clamp to 1..=64 MiB in both.

### F7. Low: newline-only ledger, Rust and bash disagree
- Where: main.rs:1283 vs sh:1600. Bash `$(...)` strips trailing newlines so segment skipped; Rust keeps "\n" and renders idle.
- Fix: test `!ledger.trim_end_matches('\n').is_empty()` in Rust.

### F8. Low: new session opening spend undercounted
- Where: main.rs:2522, sh:1521. First in-window row is the baseline; v <= 0 rows dropped.
- Fix (optional): if the tail provably reaches before `since`, treat a session with no earlier row as starting at 0. Otherwise document as a lower bound.

### F9. Low: BURN_MIN_SPAN <= 0, Rust and bash disagree
- Where: main.rs:1226-1229, sh:1555. Span 0 with spent > 0: Rust divides by 0.0 and prints garbage; bash awk errors and falls to lifetime average.
- Fix: require span > 0 in both.

### Nits
- Fractional epochs: Rust truncates before compare, awk compares as float. Ledger writes integers, so unreachable in practice. Fix: truncate in awk too (`int($1)`).
- Float summation order differs (HashMap vs awk for-in). Fix: sort by session id before summing in both.
- Tiny positive total prints $0.00 instead of idle (both agree). Fix: test the rounded value.

## Categories with no finding
- Repeated session id and equal timestamps: identical in both (strict `<` first, `>=` last).
- Empty window or single sample: no divide, no negative.
- Partial first line, empty file, file smaller than cap, file exactly cap, invalid UTF-8: correct and identical.
- Absent resets_at ("" read as 0): both guard it; float resets_at rejected in both.
- Transcript context division by zero or underflow: none (ctx_total_s stays 200000 on that branch).
- Compaction ordering (sh:1252-1273): old survivors then recent rows in append order, so the tail still holds the recent window.

## Verdict
ccusage can be removed once F1, F2 and F3 are fixed; F4 is already fixed. The core arithmetic and the bash/Rust agreement are sound, but until F1 to F3 are in, the block figure can silently overstate (stale resets_at) or understate (truncation), and burn can show a stale rate after activity stops. These are bounded fixes, not design problems.
