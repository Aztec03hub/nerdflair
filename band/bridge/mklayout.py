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
import unicodedata

import nflog

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
    ("branch", "\U000f062c|^[A-Za-z][\\w.-]*:[\\w/.-]+$", "Branch", (125, 211, 252), [
        "branch from `git rev-parse --abbrev-ref HEAD`, cached 5s",
        "a worktree branch in the payload wins over git",
    ]),
    ("dirty", "|" + r"\[\+\d","Working tree and divergence", (251, 191, 36), [
        "changed files, then +added/-removed lines",
        "from `git status --porcelain` and `git diff --numstat`",
        "the arrow is commits ahead of the tracking branch",
    ]),
    ("limits", r"\b(5h|7d)\s+\d", "Plan rate limits", (74, 222, 128), [
        "5h and 7d windows from the payload's rate_limits",
        "percentage used, then time until the window resets",
        "Anthropic's own server-side metering, not an estimate",
        "dim = last known (limits-last, from any session) or a derived 0%",
    ]),
    ("block", "\uf094", "Billing block", (192, 132, 252), [
        "spend inside the CURRENT 5-hour rate-limit window",
        "window is rate_limits.five_hour.resets_at (or the last-known record) less 5h",
        "says idle rather than guess when that window has lapsed",
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
    ("tmux", "", "tmux session", (56, 189, 248), [
        "the tmux session this pane lives in, from $TMUX",
    ]),
    ("throughput", "\U000f04c5", "Token throughput", (96, 165, 250), [
        "output tokens per second over the current turn",
        "from the transcript's usage and timing, not an estimate",
    ]),
    ("api_time", "", "Time in the API", (163, 163, 163), [
        "total_api_duration_ms: time spent waiting on the model",
        "less than wall-clock time, which also counts your own thinking",
    ]),
    ("repo_cost", "", "Repo spend", (74, 222, 128), [
        "everything spent in this repo across sessions",
        "summed from the usage ledger, positive increments only",
    ]),
    ("session_cost", "", "Session spend", (134, 239, 172), [
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


def cells(s):
    """Screen cells a string occupies: East Asian wide and fullwidth characters
    take two, combining marks none. A cwd or branch with CJK in it used to
    shift every later column by one per wide character, so hover hit the
    wrong card. Nerd Font glyphs are ambiguous-width and count one, as the
    terminal this is built for draws them."""
    n = 0
    for ch in s:
        if unicodedata.combining(ch) or unicodedata.category(ch) in ("Mn", "Me", "Cf"):
            continue
        n += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return n


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
            if cells(t) >= MIN_W:
                lead = len(part) - len(part.lstrip())
                out.append((cells(line[:start + off + lead]) + 1, cells(t), t))
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


def _ts_object(s, i, strs):
    """Parse the `{...}` starting at s[i] without a TypeScript parser: (its depth-1 text with nested
    objects collapsed to `{}` and each string replaced by \\x00N\\x00, indexing `strs`;
    [(key, nested depth-1 text)]; index after the closing brace). Comments are dropped and strings
    are opaque, so braces or `color:` inside either are not seen."""
    flat, kids, j = [], [], i + 1
    while j < len(s):
        c = s[j]
        if c in "'\"`":
            e = j + 1
            while e < len(s) and s[e] != c:
                e += 2 if s[e] == "\\" else 1
            strs.append(s[j + 1:e])
            flat.append("\x00%d\x00" % (len(strs) - 1))
            j = e + 1
        elif s.startswith("//", j) and s[j - 1:j] != ":":
            j = s.find("\n", j) if "\n" in s[j:] else len(s)
        elif s.startswith("/*", j):
            j = s.find("*/", j) + 2
            assert j > 1, "drift guard: unterminated comment in register.tsx"
        elif c == "{":
            sub, subkids, j = _ts_object(s, j, strs)
            k = re.search(r"(?:\x00(\d+)\x00|([\w-]+))\s*:\s*$", "".join(flat)[-80:])
            kids.append((None if not k else strs[int(k.group(1))] if k.group(1) else k.group(2), sub))
            flat.append("{}")
        elif c == "}":
            return "".join(flat), kids, j + 1
        else:
            flat.append(c)
            j += 1
    raise AssertionError("drift guard: unbalanced braces in register.tsx")


def band_drift(tsx):
    """Ids on both sides (this table and the band's CARDS in register.tsx) whose colours differ.
    The highlight and the card border use this table, the band uses its own: they must agree.
    Fails LOUD (AssertionError starting "drift guard") if the table cannot be read in full, or
    shares too little with CARDS to be the same table."""
    m = re.search(r"\bconst CARDS\b[^=]*=\s*\{", tsx)
    assert m, "drift guard: no `const CARDS ... = {` table found in register.tsx"
    strs = []
    _flat, kids, _end = _ts_object(tsx, m.end() - 1, strs)
    assert kids, "drift guard: the CARDS table in register.tsx has no entries"
    band = {}
    for key, body in kids:
        assert key, "drift guard: a CARDS entry in register.tsx has no readable key"
        c = re.search(r"\bcolor\s*:\s*\x00(\d+)\x00", body)
        c = c and re.fullmatch(r"#[0-9a-fA-F]{6}", strs[int(c.group(1))])
        assert c, f"drift guard: could not read the colour of CARDS entry {key!r} in register.tsx"
        band[key] = c.group(0).lower()
    ours = {c[0]: "#%02x%02x%02x" % tuple(c[3]) for c in CARDS}
    both = set(band) & set(ours)
    assert len(both) >= max(1, len(band) // 2), \
        f"drift guard: only {len(both)} of {len(band)} register.tsx ids exist in mklayout.CARDS; the table was renamed or reshaped"
    return sorted(f"{i}: band {band[i]} vs ours {ours[i]}" for i in sorted(both) if band[i] != ours[i])


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

    # Wide characters take two cells: the column of what FOLLOWS them is the
    # cell count, not the character count (control: len() gets it wrong).
    wide = "\u6f22\u5b57 dir \u00b7 branch-x"
    (c1, w1, t1), (c2, w2, t2) = pieces(wide)
    assert (c1, w1, t1) == (1, 8, "\u6f22\u5b57 dir") and t2 == "branch-x", pieces(wide)
    assert c2 == cells("\u6f22\u5b57 dir \u00b7 ") + 1 == 12 and wide.index("branch-x") + 1 == 10, (c2,)
    assert cells("e\u0301") == 1 and cells("\U000f024b") == 1 and cells("ab") == 2

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
    # The band draws its own hover fill from its own table: the two must not drift apart.
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "..", "hooks", "register.tsx"), encoding="utf-8") as f:
        tsx = f.read()
    text_drift(os.path.join(here, "..", ".."))     # the card TEXTS of limits and block match register.tsx (colours: band_drift)
    assert band_drift(tsx) == [], band_drift(tsx)
    assert band_drift(tsx.replace("color: '#60a5fa'", "color: '#60a5fb'")) != [], "drift guard must see a changed colour"
    assert classify("\uf094 $1.20")[0] == "block", "the billing block has a card"
    # The guard itself: it reads either quote style and key order, and fails loud on a short parse.
    ours_folder = "#%02x%02x%02x" % tuple(next(c[3] for c in CARDS if c[0] == "folder"))
    mini = lambda body: "const CARDS = {\n" + body + "\n}\n"  # noqa: E731
    assert band_drift(mini(f'  folder: {{\n    color: "{ours_folder}",\n    title: "F",\n  }},')) == [], "double quotes, color first"
    assert band_drift(mini("  folder: { title: 'F', color: '#000000' },")) == [f"folder: band #000000 vs ours {ours_folder}"]
    assert band_drift(mini(f"  // color: '#111111'\n  folder: {{ title: 'F', /* color: '#222222' */ color: '{ours_folder}' }},")) == [], "comments are ignored"
    assert band_drift(mini(f"  folder: {{ title: 'F', style: {{ color: '#333333' }}, color: '{ours_folder}' }},")) == [], "the entry's OWN colour, not a nested one"
    assert band_drift(mini(f"  'folder': {{ title: 'F', color: '{ours_folder}' }},")) == [], "quoted keys"
    assert band_drift(mini(f"  folder: {{ title: 'a {{ color: \"#444444\" }}', color: '{ours_folder}' }},")) == [], "braces and colours inside strings"
    for bad, why in ((mini("  zzz: { title: 'Z', color: '#000000' },"), "no id shared with CARDS"), (mini(""), "no entries"), ("nothing here", "no table"),
                     (mini("  folder: { title: 'F', color: '#000000' },\n  model: { title: 'M', color: someVar },"), "unreadable colour")):
        try:
            band_drift(bad)
        except AssertionError as e:
            assert "drift guard" in str(e), e
        else:
            raise AssertionError(f"band_drift must fail loud on: {why}")
    print("mklayout ok")


CONTEXT_ROW = re.compile(CARDS[[c[0] for c in CARDS].index("context")][1])


def build(target, skip=(), shadow=None):
    """Every readout on the status line of `target`, or [] if there is none.
    See build_ex; this is the list alone."""
    return build_ex(target, skip, shadow)[0] or []


def build_ex(target, skip=(), shadow=None):
    """(segments, truth): every readout on the status line, and whether they
    were read from the engine's own screen (`shadow`), in which case no row is
    ever covered by a card and `skip` is not applied.

    segments is None (not []) when the screen could not be READ at all (tmux
    missing, hung or answering an error): "unreadable" is not "no readouts",
    and the caller must not treat it as a dialog covering the status line.

    Every readout on the status line of `target`, or [] if there is none.

    Imported by the bridge, which calls it directly rather than reading a
    file: the columns move whenever a figure changes width (a token count
    gaining a digit shifts everything after it), so a layout published once
    is wrong within seconds. Calling this is one `capture-pane`.

    `skip` is the screen rows a floating panel is covering. Those rows show
    the panel, not the status line, so they are not read; the caller keeps
    what it knew about them.
    """
    r = shadow.capture() if shadow is not None else None
    truth = r is not None
    if not truth:
        try:
            r = subprocess.run(["tmux", "capture-pane", "-p", "-t", target],
                               capture_output=True, encoding="utf-8", errors="replace", timeout=0.5)
        except (OSError, subprocess.SubprocessError) as e:
            nflog.note_rate("layout-tmux", f"layout: tmux capture-pane failed ({type(e).__name__}: {e}); "
                                           "hover keeps its last layout until tmux answers")
            return None, False
        if r.returncode != 0:
            nflog.note_rate("layout-rc", f"layout: tmux capture-pane exit {r.returncode}: "
                                         f"{r.stderr.strip() or 'no output'}; hover keeps its last layout")
            return None, False
    if truth:
        skip = ()               # the shadow never has a card on it
    raw = r.stdout.split("\n")

    segs = []
    # The status line lives at the bottom, but a multi-line input box pushes
    # it up, so look at the bottom 30 rows. A transcript line with a bullet in
    # it is still not a readout: the glyph-and-separator test below decides.
    for i in range(max(0, len(raw) - 30), len(raw)):
        clean = ANSI.sub("", raw[i])
        row = i + 1                       # capture-pane rows are 0-based
        if row in skip:
            continue
        m = CONTEXT_ROW.search(clean)
        if m and SEP not in clean:
            # The gauge row has no separators and no glyph, so the row test
            # below would pass over it; it is one readout, found by its shape.
            sid, title, rgb, body = classify(m.group(0))
            segs.append({"id": sid, "row": row, "x": cells(clean[:m.start()]) + 1,
                         "w": cells(m.group(0)), "title": title,
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

    return segs, truth


def text_drift(root):
    """The limits and block cards exist twice, here and in band/hooks/register.tsx. Their texts
    must match, or the hover card in the plugin says something else than the bridge card."""
    with open(os.path.join(root, "band", "hooks", "register.tsx"), encoding="utf-8") as fh:
        tsx = fh.read()
    for cid in ("limits", "block"):
        m = re.search(r"^  %s: \{(.*?)^  \},?$" % cid, tsx, re.S | re.M)
        assert m, f"register.tsx has no CARDS entry for {cid}"
        body = m.group(1)
        title = re.search(r"title: ('|\")(.*?)\1", body).group(2)
        lines = [x[1] for x in re.findall(r"""^\s+('|")(.*)\1,?$""", body.split("lines:", 1)[1], re.M)]
        mk = next(c for c in CARDS if c[0] == cid)
        assert title == mk[2], f"card {cid}: title drifted: register.tsx {title!r} vs mklayout.py {mk[2]!r}"
        assert lines == mk[4], f"card {cid}: lines drifted between register.tsx and mklayout.py:\n  tsx: {lines}\n  py:  {mk[4]}"


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
    text_drift(root)
    # The tmux readout comes from a per-pane cache, else from a live tmux; seed
    # the cache for a pane of our own so this never depends on what ran before.
    pane = "%nfcards"
    # A private (0700) cache dir of our own, handed to the renderer: never the user's real one.
    import shutil
    import tempfile
    cdir = tempfile.mkdtemp(prefix="nf-cards-cache-")
    tcache = os.path.join(cdir, f"nerdflair-tmux-{os.getuid()}-{re.sub('[^a-zA-Z0-9]', '_', pane)}")
    try:
        with open(tcache, "w") as fh:
            fh.write("cards")
        # Seed a FRESH mcp health cache too (it used to be the user's live /tmp one), so the
        # readout is drawn and no real `claude mcp list` probe is spawned.
        with open(os.path.join(cdir, f"nerdflair-mcphealth-{os.getuid()}"), "w") as fh:
            fh.write("3\x1f1\x1f0\x1fa\x1eb")
        _cards_check_body(root, binary, pane, cdir)
    finally:
        shutil.rmtree(cdir, ignore_errors=True)


def _cards_check_body(root, binary, pane, cdir):
    import glob
    import shutil
    import tempfile
    # A temp HOME: the renderer reads ~/.claude/nerdflair/state.json (chime settings draw an
    # extra "random" readout that has no card) and writes its error log and ledger there.
    home = os.path.join(cdir, "home")
    os.makedirs(os.path.join(home, ".claude", "nerdflair"), exist_ok=True)
    # TODO N13: the "random" chime readout still needs a hover card (then run this twice, once with it).
    # Pinned chime settings: a style of "random" draws a volume-icon readout (before any cost)
    # that has no card yet, so the result would depend on whoever's state.json this ran against.
    with open(os.path.join(home, ".claude", "nerdflair", "state.json"), "w") as fh:
        fh.write('{"mode":"full","width":"auto","flair":true,"terminal_bell":"on","chime_sound":"Glass",'
                 '"chime_volume":"1","chime_style":"Vibraphone","chime_events":"Notification,PermissionRequest,Stop",'
                 '"color":"vibrant","last_session":"","chime_recent_styles":[]}')
    env = dict(os.environ, HOME=home, COLUMNS="250", TMUX="x,1,0", TMUX_PANE=pane, NERDFLAIR_CACHE_DIR=cdir,
               NERDFLAIR_MCP_HEALTH="1", NERDFLAIR_MCP_HEALTH_TTL="999999999", NERDFLAIR_MCP_CACHE="")
    base = tempfile.mkdtemp(prefix="nf-cards-")
    try:
        fixtures = _cards_fixtures(base)
        seen, misses, rows = _cards_run(root, binary, env, fixtures, glob)
    finally:
        shutil.rmtree(base, ignore_errors=True)
    assert rows, "the renderer printed no status rows; is it built?"
    assert not misses, f"readouts with no card: {misses}"
    want = {c[0] for c in CARDS} - {"remote_control", "ahead"}
    # remote_control is drawn by the band, and ahead shares a piece with dirty.
    assert want <= seen, f"cards no real readout reaches: {sorted(want - seen)}"
    print(f"cards ok: {rows} rows, {len(seen)} readouts, all with cards")


def _cards_fixtures(base):
    """The corpus names fixture repos (@@REPO:x@@). Build the shapes the readouts
    need (dirty, wrapper of several repos, linked worktree, detached HEAD, no
    origin); any other name gets the dirty one. GIT_* is stripped and signing is
    off, so a hook's or the user's environment cannot break the setup."""
    genv = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    genv.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)

    def git(repo, *args):
        cmd = ["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t",
               "-c", "commit.gpgsign=false", *args]
        r = subprocess.run(cmd, env=genv, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"cards-check: fixture setup failed: {' '.join(args)} in {repo}: "
                     f"{(r.stderr or r.stdout).strip()[:200]}")

    def mkrepo(path, branch="main", dirty=False):
        os.makedirs(path, exist_ok=True)
        git(path, "init", "-q", "-b", branch)
        with open(os.path.join(path, "a.txt"), "w") as fh:
            fh.write("a\n")
        git(path, "add", ".")
        git(path, "commit", "-q", "-m", "init")
        if dirty:
            with open(os.path.join(path, "a.txt"), "w") as fh:
                fh.write("a\nb\n")
        return path

    dirty = mkrepo(os.path.join(base, "dirty"), dirty=True)
    git(dirty, "remote", "add", "origin", "https://example.com/x/dirty.git")
    wrap = os.path.join(base, "wrap")
    mkrepo(os.path.join(wrap, "alpha"), "feature/alpha")
    mkrepo(os.path.join(wrap, "bravo"), "bugfix/bravo")
    main = mkrepo(os.path.join(base, "wtmain"))
    git(main, "worktree", "add", "-q", "-b", "wt/linked", os.path.join(base, "wt"))
    det = mkrepo(os.path.join(base, "det"))
    git(det, "checkout", "-q", "--detach")
    return {"dirty": dirty, "wrap-many": wrap, "wt-linked": os.path.join(base, "wt"),
            "detached": det, "noremote": mkrepo(os.path.join(base, "noremote"), dirty=True)}


def _cards_run(root, binary, env, fixtures, glob):
    seen, misses, rows = set(), {}, 0
    for f in sorted(glob.glob(os.path.join(root, "tests", "payloads", "*.json"))):
        with open(f) as fh:
            # Same token shape as tests/difftest.sh (resolve_repo): [a-z0-9-]+
            payload = re.sub(r"@@REPO:([a-z0-9-]+)@@",
                             lambda m: fixtures.get(m.group(1), fixtures["dirty"]), fh.read())
        out = subprocess.run([binary], input=payload, capture_output=True,
                             encoding="utf-8", errors="replace", env=env).stdout
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
    return seen, misses, rows


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
