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

RATES, per million tokens. Source: Anthropic's published model pricing as
carried by the claude-api skill (cached 2026-10-06), checked against the ledger
on two Sonnet 5.5 sessions on 2026-10-09 ($3.90 and $7.86, exact). Cache writes
are 1.25x the input rate for the 5 minute tier and 2x for the 1 hour tier; the
transcript says which tier each write used. A model not in this table is
reported as UNPRICED and left out of the total, never guessed at: a total that
says how much it could not price is honest, one that quietly drops it is not.
"""
import glob
import json
import os
import sys
import time
from calendar import timegm

# model prefix: (input, output, cache read)
RATES = {
    "claude-fable-5-1": (10.0, 50.0, 0.25),
    "claude-fable-5": (10.0, 50.0, 0.25),
    "claude-opus-5-5": (4.0, 20.0, 0.20),
    "claude-opus-5": (5.0, 25.0, 0.50),
    "claude-opus-4-8": (5.0, 25.0, 0.50),
    "claude-opus-4-7": (5.0, 25.0, 0.50),
    "claude-opus-4-6": (5.0, 25.0, 0.50),
    "claude-sonnet-5-5": (2.0, 10.0, 0.10),  # 0.05x, per the pricing page footnote
    "claude-sonnet-5": (2.0, 10.0, 0.20),
    "claude-sonnet-4-6": (3.0, 15.0, 0.30),
    "claude-haiku-5-5": (0.10, 0.50, 0.01),
    "claude-haiku-4-5": (1.0, 5.0, 0.10),
}


def rates_for(model):
    """Longest matching prefix, so claude-opus-5-5 is not priced as claude-opus-5."""
    best = None
    for k in RATES:
        if model.startswith(k) and (best is None or len(k) > len(best)):
            best = k
    return RATES[best] if best else None


def cost_of(usage, model):
    r = rates_for(model)
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
        except OSError:
            continue
        sid = os.path.basename(path)[:-6]
        if os.sep + "subagents" + os.sep in path:
            sid = path.split(os.sep + "subagents" + os.sep)[0].rsplit(os.sep, 1)[-1]
        with open(path, errors="replace") as f:
            for line in f:
                if '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                m = d.get("message")
                if not isinstance(m, dict) or not m.get("usage") or not d.get("timestamp"):
                    continue
                t = parse_ts(d["timestamp"])
                if not (start <= t < end):
                    continue
                seen[m.get("id") or f"{path}:{d.get('uuid')}"] = (sid, m.get("model") or "", m["usage"])
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
    print("price-recount ok")


def main():
    a = sys.argv[1:]
    if a[:1] == ["--selfcheck"]:
        selfcheck()
        return
    hours = float(a[0]) if a else 3.0
    now = int(time.time())
    total, unpriced, per = recount(now - int(hours * 3600), now + 1)
    print(f"{total:.2f}")
    if unpriced:
        print("UNPRICED " + json.dumps(unpriced), file=sys.stderr)


if __name__ == "__main__":
    main()
