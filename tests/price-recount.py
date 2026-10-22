#!/usr/bin/env python3
"""price-recount.py - what a window of transcripts cost, priced by hand from
the published rates, with no ccusage and no ledger.

This is the independent check the verification review asked for. Both the
ledger (Claude Code's own cost_usd) and ccusage start from the token counts the
API reports, and they disagreed by 35 percent on 2026-10-09. The disagreement
was settled by pricing two sessions from published rates, which matched the
ledger to the cent and showed ccusage's table charging half the published price
for cache reads on the newest models. This file turns that one-off into a
repeatable tool.

RATES, per million tokens. Source: https://platform.claude.com/docs/en/about-claude/pricing
fetched 2026-10-22 (Opus 5.5 $4/$20, read $0.20 = 0.05x; Sonnet 5.5 $2/$10, read
$0.10 = 0.05x; Opus 4.5 $5/$25, read $0.50; Sonnet 4.5 $3/$15, read $0.30; Haiku 5.5
$0.10/$0.50, read $0.01 up to 100k prompt tokens and $0.50/$2.50, read $0.05 over
100k, where prompt = input + cache read + cache write). Cache writes are 1.25x the
input rate for the 5 minute tier and 2x for the 1 hour tier; the transcript says
which tier each write used. A model not in this table is reported as UNPRICED and
left out of the total, never guessed at: a total that says how much it could not
price is honest, one that quietly drops it is not.
"""
import glob
import json
import os
import re
import sys
import time
from calendar import timegm

# exact model id (date suffix stripped): (input, output, cache read)
# ponytail: exact match only, so a future claude-sonnet-5-6 is UNPRICED, not Sonnet 5.
RATES = {
    "claude-fable-5-1": (10.0, 50.0, 0.25),
    "claude-fable-5": (10.0, 50.0, 0.25),
    "claude-opus-5-5": (4.0, 20.0, 0.20),
    "claude-opus-5": (5.0, 25.0, 0.50),
    "claude-opus-4-8": (5.0, 25.0, 0.50),
    "claude-opus-4-7": (5.0, 25.0, 0.50),
    "claude-opus-4-6": (5.0, 25.0, 0.50),
    "claude-opus-4-5": (5.0, 25.0, 0.50),
    "claude-sonnet-5-5": (2.0, 10.0, 0.10),  # 0.05x, per the pricing page footnote
    "claude-sonnet-5": (2.0, 10.0, 0.20),
    "claude-sonnet-4-6": (3.0, 15.0, 0.30),
    "claude-sonnet-4-5": (3.0, 15.0, 0.30),
    "claude-haiku-5-5": (0.10, 0.50, 0.01),
    "claude-haiku-5-5@long": (0.50, 2.50, 0.05),
    "claude-haiku-4-5": (1.0, 5.0, 0.10),
}


def rates_for(model, prompt_tokens=0):
    """Exact id after dropping a -YYYYMMDD date suffix and a [1m] tag."""
    m = re.sub(r"\[.*\]$", "", model)
    m = re.sub(r"-\d{8}$", "", m)
    if m == "claude-haiku-5-5" and prompt_tokens > 100_000:
        m += "@long"
    return RATES.get(m)


def cost_of(usage, model):
    prompt = ((usage.get("input_tokens") or 0) + (usage.get("cache_read_input_tokens") or 0)
              + (usage.get("cache_creation_input_tokens") or 0))
    r = rates_for(model, prompt)
    if r is None:
        return None
    pin, pout, pcr = r
    cc = usage.get("cache_creation") or {}
    w1h = cc.get("ephemeral_1h_input_tokens")
    w5m = cc.get("ephemeral_5m_input_tokens")
    total_w = usage.get("cache_creation_input_tokens") or 0
    if w1h is None and w5m is None:           # an older record without the split
        w5m, w1h = total_w, 0
    w1h, w5m = w1h or 0, w5m or 0
    return (
        (usage.get("input_tokens") or 0) * pin
        + (usage.get("output_tokens") or 0) * pout
        + (usage.get("cache_read_input_tokens") or 0) * pcr
        + w5m * pin * 1.25
        + w1h * pin * 2.0
    ) / 1e6


def parse_ts(s):
    # 2026-10-09T17:30:26.731Z
    return timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))


def recount(start, end, root=None):
    """Total priced cost of every assistant message with start <= t < end.

    Returns (total, unpriced_models, per_session). Messages are de-duplicated
    on message id, keeping the last record: a streamed message is written
    several times with the same id as its usage grows.
    """
    root = root or os.path.expanduser("~/.claude/projects")
    seen = {}
    # A transcript last written before the window cannot hold a message inside it.
    for path in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
        try:
            if os.path.getmtime(path) < start:
                continue
        except OSError as e:
            print(f"price-recount: SKIPPED unreadable transcript {path}: {e} (the recount is LOWER than reality)", file=sys.stderr)
            continue
        sid = os.path.basename(path)[:-6]
        if os.sep + "subagents" + os.sep in path:
            sid = path.split(os.sep + "subagents" + os.sep)[0].rsplit(os.sep, 1)[-1]
        try:
            f = open(path, errors="replace")
        except OSError as e:
            print(f"price-recount: SKIPPED unreadable transcript {path}: {e} (the recount is LOWER than reality)", file=sys.stderr)
            continue
        bad = 0
        with f:
            for line in f:
                if '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    bad += 1
                    continue
                m = d.get("message")
                if not isinstance(m, dict) or not m.get("usage") or not d.get("timestamp"):
                    continue
                t = parse_ts(d["timestamp"])
                if not (start <= t < end):
                    continue
                seen[m.get("id") or f"{path}:{d.get('uuid')}"] = (sid, m.get("model") or "", m["usage"])
        if bad:
            print(f"price-recount: SKIPPED {bad} malformed line(s) in {path} (the recount is LOWER than reality)", file=sys.stderr)
    total, unpriced, per = 0.0, {}, {}
    for sid, model, usage in seen.values():
        c = cost_of(usage, model)
        if c is None:
            if model and model != "<synthetic>":
                unpriced[model] = unpriced.get(model, 0) + 1
            continue
        total += c
        per[sid] = per.get(sid, 0.0) + c
    return total, unpriced, per


def selfcheck():
    # Two sessions' usage, re-priced at the published Sonnet 5.5 read rate (0.10).
    # Claude Code 2.1.295 and earlier priced these reads at 0.20 in total_cost_usd
    # (3.90 and 7.86), so their ledger totals overstate Sonnet 5.5 reads 2x.
    u = {"input_tokens": 152, "output_tokens": 58447, "cache_read_input_tokens": 12474761,
         "cache_creation_input_tokens": 204331,
         "cache_creation": {"ephemeral_1h_input_tokens": 204331, "ephemeral_5m_input_tokens": 0}}
    assert abs(cost_of(u, "claude-sonnet-5-5") - 2.65) < 0.005, cost_of(u, "claude-sonnet-5-5")
    u = {"input_tokens": 268, "output_tokens": 103439, "cache_read_input_tokens": 27545531,
         "cache_creation_input_tokens": 328606,
         "cache_creation": {"ephemeral_1h_input_tokens": 328606, "ephemeral_5m_input_tokens": 0}}
    assert abs(cost_of(u, "claude-sonnet-5-5") - 5.10) < 0.005, cost_of(u, "claude-sonnet-5-5")
    assert cost_of({"output_tokens": 1}, "claude-nonesuch-9") is None
    # Longest prefix wins: 5-5 must not be priced as 5.
    assert rates_for("claude-opus-5-5")[0] == 4.0 and rates_for("claude-opus-5")[0] == 5.0
    assert rates_for("claude-sonnet-5-5-20261001")[0] == 2.0 and rates_for("claude-opus-4-5")[0] == 5.0
    # Version safety: an unknown future id is UNPRICED, never priced as its prefix.
    assert rates_for("claude-sonnet-5-6") is None and rates_for("claude-opus-5-6") is None
    assert rates_for("claude-sonnet-4-5")[2] == 0.30
    # Haiku 5.5 long tier: 150k prompt tokens (read counts) uses the over-100k row.
    lo = {"input_tokens": 1000, "output_tokens": 1000, "cache_read_input_tokens": 1000}
    hi = {"input_tokens": 1000, "output_tokens": 1000, "cache_read_input_tokens": 150000}
    assert abs(cost_of(lo, "claude-haiku-5-5") - (1000*.10 + 1000*.50 + 1000*.01) / 1e6) < 1e-12
    assert abs(cost_of(hi, "claude-haiku-5-5") - (1000*.50 + 1000*2.5 + 150000*.05) / 1e6) < 1e-12
    # Dedupe regression: one message.id on 3 streamed lines counts once, at the last line.
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "s.jsonl"), "w") as f:
            for i, out in enumerate((20, 363, 1138)):
                f.write(json.dumps({"uuid": f"u{i}", "timestamp": "2026-10-22T10:00:00.000Z", "message": {
                    "id": "m1", "model": "claude-sonnet-5-5",
                    "usage": {"input_tokens": 1, "output_tokens": out, "cache_read_input_tokens": 5000}}}) + "\n")
        total, _, _ = recount(0, 2**40, root=tmp)
        want = cost_of({"input_tokens": 1, "output_tokens": 1138, "cache_read_input_tokens": 5000}, "claude-sonnet-5-5")
        assert abs(total - want) < 1e-12, f"dedupe broke: {total} vs {want}"
    print("price-recount ok")


def main():
    a = sys.argv[1:]
    if a[:1] == ["--selfcheck"]:
        selfcheck()
        return
    ledger = None
    if "--ledger" in a:                      # restrict to sessions that rendered at least once
        i = a.index("--ledger")
        ledger = a[i + 1]
        del a[i:i + 2]
    hours = float(a[0]) if a else 3.0
    now = int(time.time())
    total, unpriced, per = recount(now - int(hours * 3600), now + 1)
    if ledger:
        # A session that never rendered the status line (a headless `claude -p`,
        # a hook's run, a subagent-only session) can never reach the ledger, so
        # its spend is a COVERAGE gap, not an error in how the ledger is computed.
        # The gate compares like with like; the gap is reported, never hidden.
        with open(ledger, errors="replace") as lf:
            seen_ids = {p[1] for p in (ln.split("\t") for ln in lf) if len(p) >= 4}
        out = {s: c for s, c in per.items() if s not in seen_ids}
        print(f"price-recount: NOT-IN-LEDGER ${sum(out.values()):.2f} across {len(out)} session(s) that never rendered "
              "a status line (excluded from the figure above)", file=sys.stderr)
        total = sum(c for s, c in per.items() if s in seen_ids)
    print(f"{total:.2f}")
    if unpriced:
        print("UNPRICED " + json.dumps(unpriced), file=sys.stderr)


if __name__ == "__main__":
    main()
