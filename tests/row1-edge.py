#!/usr/bin/env python3
"""row1-edge.py [--rust BIN] [--bash-a SCRIPT] [RUN_DIR]
Row 1 must end where the bar row ends whenever the right readout (dirty / ahead / behind)
exists, in both renderers. With no RUN_DIR it runs tests/difftest.sh --keep on the corpus
cases whose description starts with "row1 " and checks every A.out (bash) and B.out (rust).
--rust / --bash-a point difftest at another build (to show the check fails on an old one).
Exit 1 on any miss, or if no case had a right readout (a vacuous pass)."""
import os, re, shutil, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]; extra = []; run = None
while args:
    a = args.pop(0)
    if a in ("--rust", "--bash-a"): extra += [a, args.pop(0)]
    else: run = a
cleanup = False
if run is None:
    ids = sorted(f[:-4] for f in os.listdir(os.path.join(here, "payloads"))
                 if f.endswith(".txt") and open(os.path.join(here, "payloads", f)).read().startswith("row1 "))
    r = subprocess.run(["bash", os.path.join(here, "difftest.sh"), "-j", "4", "--keep", "--only", ",".join(ids)] + extra,
                       capture_output=True, text=True)
    m = re.search(r"run dir kept: (\S+)", re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr))
    if not m:
        print(r.stdout[-2000:], r.stderr[-2000:]); sys.exit(2)
    run = m.group(1); cleanup = True
ansi = re.compile(r"\x1b\[[0-9;:]*m")
bad = seen = 0
for case in sorted(os.listdir(run)):
    for side in ("A", "B"):
        f = os.path.join(run, case, side + ".out")
        if not os.path.isfile(f): continue
        lines = ansi.sub("", open(f, encoding="utf-8", errors="replace").read()).split("\n")
        if len(lines) < 2: continue
        # the dirty glyph (a count-only readout has no brackets) or an ahead/behind arrow
        has_right = "" in lines[0] or bool(re.search(r"[↑↓]\d+\s*$", lines[0]))
        dfile = os.path.join(here, "payloads", case + ".txt")
        if "right edge" in (open(dfile).read() if os.path.isfile(dfile) else "") and not has_right:
            print(f"{case} {side} right readout MISSING (fixture is dirty)"); bad += 1   # never dropped
        desc = open(dfile).read() if os.path.isfile(dfile) else ""
        mm = re.match(r"row1 multi: (\S+) at COLUMNS=(\d+)", desc)
        if mm:   # the model keeps its effort beside the branches; the peek reads cleanly
            repo, cols = mm.group(1), int(mm.group(2))
            checks = []
            if repo == "wrap-many" and cols >= 60: checks.append((" high" in lines[0], "effort word dropped"))
            if repo == "wrap-short" and cols >= 100: checks.append(("\u00b7 c:d " in lines[0] + " ", "short second entry not whole and clean"))
            if repo == "wrap-longfirst" and cols >= 100: checks.append(("zeta\u2026" in lines[0] and "zeta:" not in lines[0], "peek ends on the colon"))
            for good, why in checks:
                if not good: print(f"{case} {side} {why}: {lines[0]!r}"); bad += 1
        if desc.startswith("row1 right edge: longdiv"):   # a truncated model keeps the 2-column gap, not 3
            g = re.search(r"Mythos[^\u2026]*\u2026( +)\S", lines[0])
            if g and len(g.group(1)) != 2: print(f"{case} {side} gap after the truncated model is {len(g.group(1))}, not 2: {lines[0]!r}"); bad += 1
        w1, w2 = len(lines[0]), len(lines[1])
        ok = (not has_right) or w1 == w2
        seen += has_right; bad += not ok
        if has_right: print(f"{case} {side} row1={w1} bar={w2} {'ok' if ok else 'MISS'}")
if cleanup: shutil.rmtree(run, ignore_errors=True)
print(f"row1-edge: {seen} outputs with a right readout, {bad} misses")
sys.exit(1 if bad or seen == 0 else 0)
