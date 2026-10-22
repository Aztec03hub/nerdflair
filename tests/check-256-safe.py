#!/usr/bin/env python3
"""check-256-safe.py - the 256-colour clamp guard (task N12).

Claude Code clamps its colours to 256 when $TMUX is set and
CLAUDE_CODE_TMUX_TRUECOLOR is empty, using ansi-styles rgbToAnsi256. Schemes
remap indices 16 and 17, so no colour the renderer emits in that mode may
quantize to either. With the opt-in set the output must be byte-identical to
the reference revision's (default main) bash renderer.

  tests/check-256-safe.py [--bash PATH] [--rust BIN] [--ref REV]

--bash defaults to this checkout's scripts/statusline.sh, --rust to
rust/target/release/nerdflair-statusline when it exists. Each render runs in
a fresh temp HOME / NERDFLAIR_CACHE_DIR with stub tmux/claude on PATH.
"""
import argparse, json, os, re, subprocess, sys, tarfile, io, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SGR = re.compile(r'[\[;]([34]8);2;(\d+);(\d+);(\d+)')


def rgb_to_ansi256(r, g, b):
    rnd = lambda x: int(x + 0.5)  # JS Math.round for x >= 0
    if r == g == b:
        if r < 8:
            return 16
        if r > 248:
            return 231
        return rnd(((r - 8) / 247) * 24) + 232
    return 16 + 36 * rnd(r / 255 * 5) + 6 * rnd(g / 255 * 5) + rnd(b / 255 * 5)


def payload(pct):
    return json.dumps({
        "session_id": "s256-check",
        "workspace": {"current_dir": "/nonexistent-s256", "project_dir": "/nonexistent-s256"},
        "model": {"display_name": "Opus 4.6", "id": "claude-opus-4-6-20250101"},
        "cost": {"total_cost_usd": 1.25, "total_duration_ms": 600000, "total_api_duration_ms": 60000},
        "context_window": {"used_percentage": pct, "total_input_tokens": pct * 2000,
                           "total_output_tokens": 1000, "context_window_size": 200000},
    })


CASES = [("logo splash 0%", 0), ("normal bar 37%", 37), ("full bar 100%", 100)]
STATE = {"mode": "full", "width": "auto", "flair": True, "color": "vibrant"}


def render(impl, pct, extra_env):
    with tempfile.TemporaryDirectory(prefix="s256-") as home:
        for d in (".claude/nerdflair", "bin", "tmp", "cache", "neutral"):
            os.makedirs(os.path.join(home, d))
        with open(os.path.join(home, ".claude/nerdflair/state.json"), "w") as f:
            json.dump(STATE, f)
        for stub in ("tmux", "claude"):
            p = os.path.join(home, "bin", stub)
            with open(p, "w") as f:
                f.write("#!/bin/sh\nexit 0\n")
            os.chmod(p, 0o755)
        env = {"HOME": home, "NERDFLAIR_CACHE_DIR": os.path.join(home, "cache"),
               "TMPDIR": os.path.join(home, "tmp"),
               "PATH": os.path.join(home, "bin") + ":/usr/local/bin:/usr/bin:/bin",
               "TERM": "xterm-256color", "LC_ALL": "C.UTF-8", "LANG": "C.UTF-8", "TZ": "UTC",
               "COLUMNS": "120", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
               "NERDFLAIR_MCP_HEALTH": "0", "NERDFLAIR_REPO_COST": "0"}
        env.update(extra_env)
        r = subprocess.run([impl], input=payload(pct).encode(), env=env, capture_output=True,
                           cwd=os.path.join(home, "neutral"), timeout=10)
        return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bash", default=os.path.join(ROOT, "scripts/statusline.sh"))
    ap.add_argument("--rust", default=os.path.join(ROOT, "rust/target/release/nerdflair-statusline"))
    ap.add_argument("--ref", default="main")
    a = ap.parse_args()
    impls = [("bash", a.bash)] + ([("rust", a.rust)] if os.path.exists(a.rust) else [])

    clamped = {"TMUX": "/tmp/tmux-fake,1,0", "TMUX_PANE": "%1"}
    optin = dict(clamped, CLAUDE_CODE_TMUX_TRUECOLOR="1")
    fails = 0
    with tempfile.TemporaryDirectory(prefix="s256-ref-") as refdir:
        tar = subprocess.run(["git", "-C", ROOT, "archive", a.ref, "scripts"],
                             capture_output=True, check=True).stdout
        tarfile.open(fileobj=io.BytesIO(tar)).extractall(refdir)
        ref = os.path.join(refdir, "scripts/statusline.sh")
        for name, pct in CASES:
            want = {lbl: render(ref, pct, env) for lbl, env in (("opt-in", optin), ("no-tmux", {}))}
            for tag, impl in impls:
                out = render(impl, pct, clamped)
                if tag == "bash":
                    bash_clamped = out
                elif out != bash_clamped:
                    fails += 1
                    print(f"FAIL rust {name}: clamped output differs from bash")
                cols = [(m.group(1), *map(int, m.groups()[1:])) for m in SGR.finditer(out.decode("utf-8", "replace"))]
                bad = sorted({c for c in cols if rgb_to_ansi256(*c[1:]) in (16, 17)})
                if not cols or bad:
                    fails += 1
                    print(f"FAIL {tag} {name}: {len(cols)} colours, {len(bad)} quantize to 16/17 {bad[:4]}")
                else:
                    print(f"ok   {tag} {name}: {len(cols)} colours, none on 16/17")
                for lbl, env in (("opt-in", optin), ("no-tmux", {})):
                    if render(impl, pct, env) != want[lbl]:
                        fails += 1
                        print(f"FAIL {tag} {name}: {lbl} output differs from {a.ref}")
                    else:
                        print(f"ok   {tag} {name}: {lbl} byte-identical to {a.ref}")
    print("check-256-safe:", "FAIL" if fails else "PASS", f"({fails} failures)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
