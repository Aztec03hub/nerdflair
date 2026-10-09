#!/usr/bin/env python3
"""mklayout.py - publish where each status-line readout sits, for the bridge.

WHY NOT ASK THE RENDERER. It is the only thing that truly knows, and its
`--json` already emits every segment with a stable id. But that branch returns
before the rows are assembled, so it knows the segment TEXTS and not their
positions; threading a column tracker through the row assembly means touching
code held byte-identical to the bash reference by a differential test, to
recover something derivable from the rendered row in a few lines.

So the columns come from the rendered row, split the way the renderer built
it: runs of three or more spaces are the justification gaps between the left
and right halves, and " · " is the separator it puts between segments. That is
exact, where the previous version searched for hardcoded substrings and found
two readouts out of fifteen.

This runs on a layout change, not per hover. Reading the screen for EVENTS is
what was ruled out, and this does not do that.
"""
import json
import os
import re
import subprocess
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
GAP = re.compile(r"\s{3,}")
SEP = " · "

# Which bottom rows are ours. A bullet separator alone is not enough: Claude
# Code's own hint line ("auto mode on (shift+tab to cycle) · 2 agents") has
# one too, and it was being carved into readouts. Every row the nerdflair
# renderer draws carries at least one Nerd Font glyph, and those live in the
# private use areas; the engine's chrome uses ordinary symbols (U+23F5, U+2190)
# and so is excluded by construction rather than by naming its wording.
NERD = re.compile(r"[-\U000f0000-\U000ffffd]")

# How to recognise a readout from the text it drew, and what its card says.
# Ordered: the first pattern that matches wins, so put the specific ones
# first. Mirrors the CARDS table in band/hooks/register.tsx, which is keyed by
# the same ids the renderer emits.
#
# Patterns are NOT anchored at the start. Nearly every readout is drawn with a
# leading Nerd Font glyph, so `^\d` and friends match nothing in practice;
# anchoring was why four of these fell through to the generic card. Where a
# glyph is the most reliable marker it is matched directly, by codepoint.
CARDS = [
    ("folder", "\U000f024b|\uf1bb", "Folder", (125, 211, 252), [
        "workspace.project_dir, else current_dir",
    ]),
    ("branch", "\U000f062c", "Branch", (125, 211, 252), [
        "branch from `git rev-parse --abbrev-ref HEAD`, cached 5s",
        "a worktree branch in the payload wins over git",
    ]),
    ("dirty", "|" + r"\[\+\d","Working tree and divergence", (251, 191, 36), [
        "changed files, then +added/-removed lines",
        "from `git status --porcelain` and `git diff --numstat`",
        "the arrow is commits ahead of the tracking branch",
    ]),
    ("limits", r"\b(5h|7d)\s+\d", "Plan rate limits", (122, 222, 150), [
        "5h and 7d windows from the payload's rate_limits",
        "percentage used, then time until the window resets",
        "Anthropic's own server-side metering, not an estimate",
    ]),
    ("mcp_health", r"\d+/\d+", "MCP health", (74, 222, 128), [
        "connected / total, then failed and needing auth",
        "same probe as the server names",
    ]),
    ("burn", r"/h$", "Burn rate", (251, 146, 60), [
        "dollars per hour across EVERY session, last 60 minutes",
        "sums positive increments, so a reset cannot erase it",
        "suppressed when the newest sample is over 3 minutes old",
    ]),
    ("ahead", r"[↑↓]\d", "Divergence from upstream", (251, 191, 36), [
        "commits ahead of and behind the tracking branch",
    ]),
    ("model", "|(Opus|Sonnet|Haiku)", "Model", (196, 181, 253), [
        "model.display_name, else model.id",
    ]),
    ("remote_control", r"^\W*rc\b", "Remote Control", (74, 222, 128), [
        "whether another surface is attached to this session",
        "green while attached, amber just after it left, grey when off",
    ]),
    ("tmux", "", "tmux session", (163, 163, 163), [
        "the tmux session this pane lives in, from $TMUX",
    ]),
    ("throughput", "\U000f04c5", "Token throughput", (125, 211, 252), [
        "output tokens per second over the current turn",
        "from the transcript's usage and timing, not an estimate",
    ]),
    ("api_time", "", "Time in the API", (145, 130, 155), [
        "total_api_duration_ms: time spent waiting on the model",
        "less than wall-clock time, which also counts your own thinking",
    ]),
    ("repo_cost", "", "Repo spend", (110, 155, 95), [
        "everything spent in this repo across sessions",
        "summed from the usage ledger, positive increments only",
    ]),
    ("session_cost", "", "Session spend", (90, 120, 82), [
        "cost.total_cost_usd for THIS session, from Claude Code",
    ]),
    ("context", r"\d[kM]?/\d+(\.\d+)?[kM]\s+\d+%", "Context window", (125, 211, 252), [
        "tokens in context over the window size, then percent used",
        "read from the payload, else the newest usage line in the transcript",
        "compaction triggers near the top; the ETA reads off the same series",
    ]),
    ("effort", r"\b(minimal|low|medium|high|xhigh|max)\b", "Effort",
     (196, 181, 253), [
        "effort.level, after any silent downgrade",
    ]),
    ("mcp", "|,.*,", "MCP servers", (192, 132, 252), [
        "names from the `claude mcp list` probe when its cache is warm",
        "else the config files: what is CONFIGURED, not what connected",
        "cached 300s, refreshed by one locked background job",
    ]),
    ("compact_eta", r"^\W*~[<>]?\d", "Compaction ETA", (163, 163, 163), [
        "when the context window is projected to fill",
        "Theil-Sen slope over a 16-sample ring, idle gaps excluded",
        "measured ~68% median error, so it is rounded and always ~",
    ]),
]

GENERIC = ("Readout", (156, 163, 175),
           ["this readout has no card of its own yet",
            "its value is shown above"])

# Pieces this short are punctuation or an icon, not a readout worth a card.
MIN_W = 2


def classify(text):
    for _id, pat, title, rgb, body in CARDS:
        if re.search(pat, text):
            return _id, title, rgb, body
    title, rgb, body = GENERIC
    return None, title, rgb, body


def pieces(line):
    """Every readout in a rendered row, as (column, width, text).

    Columns are 1-based screen columns. Splitting is done on the ORIGINAL
    string with offsets carried through, because measuring a stripped copy and
    applying it to the real row is how off-by-several errors happen.
    """
    out = []
    for start, text in _split_keep(line, GAP):
        off = 0
        for part in text.split(SEP):
            t = part.strip()
            if len(t) >= MIN_W:
                lead = len(part) - len(part.lstrip())
                out.append((start + off + lead + 1, len(t), t))
            off += len(part) + len(SEP)
    return out


def _split_keep(s, pat):
    """Split on a pattern, keeping each piece's offset in the original."""
    out = []
    at = 0
    for m in pat.finditer(s):
        if m.start() > at:
            out.append((at, s[at:m.start()]))
        at = m.end()
    if at < len(s):
        out.append((at, s[at:]))
    return out


def selfcheck():
    """The column arithmetic, against a row whose answer is countable by hand.

    Columns are the whole job here and an off-by-one is invisible until a
    panel opens over the wrong readout, so the positions are asserted against
    `line.index`, computed independently of the splitting code.
    """
    line = "  \U000f024b nerdflair · \U000f062c main   5h 2%/4h30m 7d 45%/5d"
    got = pieces(line)
    assert [t for _c, _w, t in got] == [
        "\U000f024b nerdflair", "\U000f062c main", "5h 2%/4h30m 7d 45%/5d",
    ], got
    for col, w, text in got:
        assert col == line.index(text) + 1, (text, col, line.index(text) + 1)
        assert w == len(text), (text, w)

    # The justification gap must SPLIT, and a lone separator must not produce
    # an empty readout.
    assert len(pieces("aa · bb" + " " * 9 + "cc")) == 3
    assert pieces("   ·   ") == []
    # Single characters are icons and separators, not readouts.
    assert pieces("a · b") == []

    # Ours, versus Claude Code's own hint line, which also has bullets.
    assert NERD.search(line)
    assert not NERD.search("⏵⏵ auto mode on (shift+tab) · 2 agents")

    ids = [classify(t)[0] for _c, _w, t in got]
    assert ids == ["folder", "branch", "limits"], ids
    # Something with no card still gets one, rather than being unhoverable.
    sid, title, _rgb, body = classify("wat")
    assert sid is None and title == "Readout" and body
    print("mklayout ok")


CONTEXT_ROW = re.compile(CARDS[[c[0] for c in CARDS].index("context")][1])


def build(target, skip=()):
    """Every readout on the status line of `target`, or [] if there is none.

    Imported by the bridge, which calls it directly rather than reading a
    file: the columns move whenever a figure changes width (a token count
    gaining a digit shifts everything after it), so a layout published once
    is wrong within seconds. Calling this is one `capture-pane`.

    `skip` is the screen rows a floating panel is covering. Those rows show
    the panel, not the status line, so they are not read; the caller keeps
    what it knew about them.
    """
    try:
        r = subprocess.run(["tmux", "capture-pane", "-p", "-t", target],
                           capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.SubprocessError):
        return []
    raw = r.stdout.split("\n")

    segs = []
    # Only the last handful of rows: the status line lives at the bottom, and
    # a transcript line with a bullet in it is not a readout.
    for i in range(max(0, len(raw) - 8), len(raw)):
        clean = ANSI.sub("", raw[i])
        row = i + 1                       # capture-pane rows are 0-based
        if row in skip:
            continue
        m = CONTEXT_ROW.search(clean)
        if m and SEP not in clean:
            # The gauge row has no separators and no glyph, so the row test
            # below would pass over it; it is one readout, found by its shape.
            sid, title, rgb, body = classify(m.group(0))
            segs.append({"id": sid, "row": row, "x": m.start() + 1,
                         "w": len(m.group(0)), "title": title,
                         "body": body, "rgb": list(rgb)})
            continue
        if SEP not in clean or not NERD.search(clean):
            continue
        for col, w, text in pieces(clean):
            sid, title, rgb, body = classify(text)
            segs.append({
                "id": sid or f"row{row}-col{col}",
                "row": row,
                "x": col,
                "w": w,
                "title": title,
                # The live value leads, so a clipped readout is still readable
                # in its own card.
                "body": [text] + body if sid is None else body,
                "rgb": list(rgb),
            })

    return segs


def cards_check():
    """Every readout the REAL renderer draws must land on a card of its own.

    A hand-written row proves only that the patterns match what was typed.
    This runs the shipped binary over the whole payload corpus and classifies
    what it actually prints, so a new readout (or a changed glyph) that has
    no card fails here instead of showing "no card of its own yet" on hover.
    Also asserts every id the renderer can emit is reachable, so a card
    cannot rot unreachable.
    """
    import glob
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    binary = os.path.join(root, "rust", "target", "release", "nerdflair-statusline")
    env = dict(os.environ, NERDFLAIR_CCUSAGE="0", COLUMNS="250", TMUX="x,1,0")
    seen, misses, rows = set(), {}, 0
    for f in sorted(glob.glob(os.path.join(root, "tests", "payloads", "*.json"))):
        with open(f) as fh:
            out = subprocess.run([binary], stdin=fh, capture_output=True,
                                 text=True, env=env).stdout
        for line in ANSI.sub("", out).split("\n"):
            if CONTEXT_ROW.search(line):
                seen.add("context")
            if SEP not in line or not NERD.search(line):
                continue
            rows += 1
            for _c, _w, text in pieces(line):
                sid = classify(text)[0]
                seen.add(sid)
                if sid is None:
                    misses[text] = misses.get(text, 0) + 1
    assert rows, "the renderer printed no status rows; is it built?"
    assert not misses, f"readouts with no card: {misses}"
    want = {c[0] for c in CARDS} - {"remote_control", "ahead"}
    # remote_control is drawn by the band, and ahead shares a piece with dirty.
    assert want <= seen, f"cards no real readout reaches: {sorted(want - seen)}"
    print(f"cards ok: {rows} rows, {len(seen)} readouts, all with cards")


def main():
    """The CLI, which exists to SEE what the bridge computes."""
    if sys.argv[1:2] == ["--selfcheck"]:
        selfcheck()
        return
    if sys.argv[1:2] == ["--cards-check"]:
        cards_check()
        return
    segs = build(sys.argv[1])
    if not segs:
        print("no status-line rows found", file=sys.stderr)
        sys.exit(1)
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w") as f:
            json.dump({"segs": segs}, f, indent=1)
    rows = sorted({s["row"] for s in segs})
    print(f"{len(segs)} readouts on rows {rows}")
    for s in segs:
        print(f"  row {s['row']} col {s['x']:>4}..{s['x']+s['w']-1:<4} "
              f"{s['title']}")


if __name__ == "__main__":
    main()
