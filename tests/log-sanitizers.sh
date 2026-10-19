#!/usr/bin/env bash
# log-sanitizers.sh - the five copies of the "no terminal control in a log" filter must agree.
#
# One table (tests/data/log-sanitizer-cases.tsv: name, hex of the raw bytes) is fed to
#   Rust      errlog::sanitize_reason (through the unit test sanitizer_table)
#   bash      scripts/lib.sh         _nf_log_line     (also cuts to 400 bytes)
#   bash      band/hover/nf-log.sh   nf_log
#   python    band/bridge/nflog.py   clean
#   python    band/hover/nf-tmux-watch _clean
# and the outputs are compared byte for byte (the nf-log.sh and Python copies do not truncate, so
# the over-400-byte cases are compared for lib.sh only; the Python copies take text, so cases that
# are not valid UTF-8 are not fed to them). Then tests/data/sete-check.sh proves both bash loggers
# survive `set -eu`. Needs cargo for the Rust column; exit 77 when it is missing.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v cargo >/dev/null || { echo "log-sanitizers: cargo not found; the Rust column cannot run (SKIPPED)" >&2; exit 77; }

W=$(mktemp -d "${TMPDIR:-/tmp}/nf-sanit-XXXXXX") || exit 1
[[ -d "$W" ]] || exit 1
trap 'python3 -I -c "import shutil,sys; d=sys.argv[1]; assert d.startswith(\"/\") and \"nf-sanit-\" in d; shutil.rmtree(d, ignore_errors=True)" "$W"' EXIT
# cargo/rustup find their toolchain through HOME: pin it before HOME becomes the temp dir
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export HOME="$W/home" NF_STATE_DIR="$W/state" NF_LOG_NOSTAMP=1 NERDFLAIR_ERR_STAMP_DIR="$W/stamps"
mkdir -p "$HOME/.claude" "$NF_STATE_DIR" "$NERDFLAIR_ERR_STAMP_DIR"
fail=0
check() { if [[ "$2" == "$3" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi; }

TSV="$REPO/tests/data/log-sanitizer-cases.tsv"
cut -f1 "$TSV" > "$W/names"
cut -f2 "$TSV" > "$W/in.hex"

# Rust
NF_SAN_IN="$W/in.hex" NF_SAN_OUT="$W/out.rust" cargo test --release --manifest-path "$REPO/rust/Cargo.toml" sanitizer_table >"$W/cargo.out" 2>&1 \
  || { tail -n 8 "$W/cargo.out" >&2; echo "log-sanitizers: the Rust column failed to run"; exit 1; }

# bash loggers: each case in a fresh subshell and fresh log, the reason read back from the line
unhex() { local h=$1 out="" i; for ((i = 0; i < ${#h}; i += 2)); do out+="\\x${h:i:2}"; done; printf '%b' "$out"; }
LIBLOG="$HOME/.claude/nerdflair-errors.log"
readback() { # file regex -> hex of the reason (group 1), or NOLINE
  LC_ALL=C python3 -I - "$1" "$2" <<'PY'
import re, sys
try:
    b = open(sys.argv[1], 'rb').read().rstrip(b'\n')
except OSError:
    print('NOLINE'); sys.exit()
m = re.match(sys.argv[2].encode(), b, re.S)
print(m.group(1).hex() if m else 'NOLINE')
PY
}
: > "$W/out.lib"; : > "$W/out.nflog"
while read -r h; do
  r=$(unhex "$h"; printf x); r=${r%x}
  rm -f "$LIBLOG"; ( . "$REPO/scripts/lib.sh"; _nf_log_line key "$r" ) 2>/dev/null
  readback "$LIBLOG" '\S+ \d+ key: (.*)$' >> "$W/out.lib"
  rm -f "$NF_STATE_DIR/launcher.log"; ( . "$REPO/band/hover/nf-log.sh"; nf_log comp "$r" ) 2>/dev/null
  readback "$NF_STATE_DIR/launcher.log" '\S+ comp: (.*)$' >> "$W/out.nflog"
done < "$W/in.hex"

# python copies + the comparison
python3 -I - "$REPO" "$W" <<'PY'
import importlib.machinery, importlib.util, os, sys
repo, w = sys.argv[1], sys.argv[2]
os.environ["NF_TMUX_WATCH_LOG"] = os.path.join(w, "watch.log")
sys.path.insert(0, os.path.join(repo, "band", "bridge"))
import nflog
loader = importlib.machinery.SourceFileLoader("nfw", os.path.join(repo, "band", "hover", "nf-tmux-watch"))
spec = importlib.util.spec_from_loader("nfw", loader)
watch = importlib.util.module_from_spec(spec); loader.exec_module(watch)
names = open(os.path.join(w, "names")).read().split("\n")[:-1]
ins = open(os.path.join(w, "in.hex")).read().split("\n")[:-1]
col = {k: open(os.path.join(w, "out." + k)).read().split("\n")[:-1] for k in ("rust", "lib", "nflog")}
bad = 0
for i, n in enumerate(names):
    raw = bytes.fromhex(ins[i])
    want = col["rust"][i]
    diffs = []
    if col["lib"][i] != want:
        diffs.append("lib.sh")
    if len(raw) < 400:   # the others do not truncate
        if col["nflog"][i] != want:
            diffs.append("nf-log.sh")
        try:
            t = raw.decode("utf-8")
        except UnicodeDecodeError:
            t = None
        if t is not None:
            if nflog.clean(t).encode().hex() != want:
                diffs.append("nflog.py")
            if watch._clean(t).encode().hex() != want:
                diffs.append("nf-tmux-watch")
    if diffs:
        bad += 1
        print(f"  FAIL  sanitizer case {n}: differs from Rust in {diffs}")
        print(f"        rust   {want[:100]}")
        for k in ("lib", "nflog"):
            print(f"        {k:6} {col[k][i][:100]}")
    else:
        print(f"  PASS  sanitizer case {n}")
sys.exit(1 if bad else 0)
PY
(( $? == 0 )) || fail=1

# Both bash loggers must survive set -eu (a file, not bash -c)
mkdir -p "$W/sete"
out=$(bash "$REPO/tests/data/sete-check.sh" "$REPO" "$W/sete" 2>&1)
check "set -eu: both bash loggers survive a raw 0x9b and a valid CJK string" SURVIVED "$(printf '%s' "$out" | tail -n 1)"
check "set -eu: lib.sh wrote its two lines" 2 "$(wc -l < "$W/sete/home/.claude/nerdflair-errors.log" 2>/dev/null | tr -d ' ')"
check "set -eu: nf-log.sh wrote its two lines" 2 "$(wc -l < "$W/sete/state/launcher.log" 2>/dev/null | tr -d ' ')"
check "set -eu: no raw 0x9b or 0x92 survives in either log" yes \
  "$(cat "$W/sete/home/.claude/nerdflair-errors.log" "$W/sete/state/launcher.log" | LC_ALL=C python3 -I -c 'import sys; b=sys.stdin.buffer.read(); print("no" if (b"\x9b" in b or b"\x92" in b) else "yes")')"
check "set -eu: the valid CJK string is kept whole in both" 2 "$(cat "$W/sete/home/.claude/nerdflair-errors.log" "$W/sete/state/launcher.log" | LC_ALL=C python3 -I -c 'import sys; print(sys.stdin.buffer.read().count("日本".encode()))')"

echo
(( fail )) && { echo "log-sanitizers: FAIL"; exit 1; }
echo "log-sanitizers: PASS"
