#!/usr/bin/env bash
# doctor.sh - check the whole nerdflair install and say exactly what is wrong and how to fix it.
#
#   nerdflair doctor [--json]
#
# Pure read: never writes a file, never starts or restarts anything. Exit 0 when nothing
# is BROKEN, 1 otherwise. Every path comes from HOME (or the env overrides the scripts it
# mirrors already honour: NERDFLAIR_CACHE_DIR, XDG_CACHE_HOME, NERDFLAIR_PLUGIN_DEST,
# NERDFLAIR_INSTALLED_PLUGINS), so tests run it against a fake HOME.
set -uo pipefail
export LC_ALL=C   # byte-order globbing: the source hash must list files exactly as build.rs does

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
json=0; [[ "${1:-}" == "--json" ]] && json=1
(( json )) || echo "checkout: $REPO"
command -v jq >/dev/null || { echo "doctor: BROKEN: jq is not installed (nerdflair needs it); fix: sudo apt install jq" >&2; exit 1; }
BIN="$HOME/.local/bin/nerdflair-statusline"
SETTINGS="$HOME/.claude/settings.json"
NF="$HOME/.nerdflair"
STATE="${NF_STATE_DIR:-$HOME/.local/state/nerdflair}"
PTYLOG="${NFPTY_ERRLOG:-$STATE/nfpty-error.log}"
rows=()   # status<TAB>check<TAB>detail<TAB>fix
row() { rows+=("$1"$'\t'"$2"$'\t'"${3//$'\t'/ }"$'\t'"${4:-}"); }

# 1. the installed renderer is this checkout's build
# same order as rust/build.rs (keep both byte-sorted; LC_ALL=C is exported above): every src/**/*.rs by sorted relative path, then Cargo.toml, Cargo.lock
src_hash() { (cd "$REPO/rust" && { find src -type f -name '*.rs' | sort | xargs cat; cat Cargo.toml Cargo.lock; } | sha256sum | cut -c1-8); }
want="$(src_hash)"
if [[ ! -x "$BIN" ]]; then
  row BROKEN renderer "$BIN is missing" "bash $REPO/scripts/build-rust.sh"
# A build from before --version would read stdin and render (and write its caches), so it
# is never run: the stamp is one literal in the file (main.rs concat!), absent = old build.
elif ! command grep -qaE 'nerdflair-statusline [0-9][^ ]* src:[0-9a-f]{8}' "$BIN"; then
  row BROKEN renderer "installed binary has no --version (built before it existed): stale" "bash $REPO/scripts/build-rust.sh"
else
  ver="$(timeout 2 "$BIN" --version </dev/null 2>/dev/null)"
  have="${ver##*src:}"
  if [[ ! "$ver" =~ ^nerdflair-statusline\ [^\ ]+\ src:[0-9a-f]{8}$ ]]; then
    row BROKEN renderer "--version printed no stamp: stale or broken build" "bash $REPO/scripts/build-rust.sh"
  elif [[ "$have" != "$want" ]]; then
    row BROKEN renderer "installed src:$have, this checkout is src:$want" "bash $REPO/scripts/build-rust.sh"
  else
    row ok renderer "$ver"
  fi
fi

# 2. settings.json statusLine points at that binary (ONLY .statusLine is read: the file may hold secrets)
fixsl="tmp=\$(mktemp) && jq --arg c '$BIN' '.statusLine={type:\"command\",command:\$c}' '$SETTINGS' > \"\$tmp\" && mv \"\$tmp\" '$SETTINGS'"
if [[ ! -f "$SETTINGS" ]]; then
  row BROKEN statusline "$SETTINGS is missing" "/nerdflair install   # inside Claude Code; it creates settings.json with the statusLine"
elif ! cmd="$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)"; then
  row BROKEN statusline "$SETTINGS is not valid JSON" "jq . '$SETTINGS' >/dev/null  # shows where it breaks; fix by hand"
else
  c="${cmd/#\~/$HOME}"; c="${c//\$HOME/$HOME}"; c="${c//\$\{HOME\}/$HOME}"
  if [[ -z "$cmd" ]]; then row BROKEN statusline "no statusLine command" "$fixsl"
  elif [[ "$c" == *"$BIN"* ]]; then row ok statusline "runs $BIN"
  elif [[ "$c" == *statusline.sh* ]]; then row warn statusline "runs the bash renderer, not $BIN" "$fixsl"
  else row BROKEN statusline "statusLine runs something else: ${cmd%% *}" "$fixsl"
  fi
fi

# 3. band plugin: published copy and the one Claude Code loads
if out="$(bash "$REPO/band/sync-local-plugin.sh" --check 2>&1)"; then
  row ok plugin "${out#nerdflair-band: }"
elif [[ "$out" == *"has 'none'"*"has 'none'"* ]]; then
  # never installed: a warn, like hover. deploy refreshes, it never opts you in.
  row warn plugin "band plugin not installed (no published copy, not in installed_plugins.json)" "bash $REPO/band/sync-local-plugin.sh   # opt-in; it runs claude plugin install"
else
  row BROKEN plugin "$(printf '%s' "$out" | sed -n 's/^nerdflair-band: //; s/ Run band.*//; p' | paste -sd '|' - | sed 's/|/; /g')" \
    "bash $REPO/band/sync-local-plugin.sh   # then /reload-plugins in every session"
fi

# 4. hover shim: the copies in ~/.nerdflair match band/ (mapping from band/hover/install.sh)
if [[ ! -e "$NF" ]]; then
  row warn hover "not installed ($NF absent)" "bash $REPO/band/hover/install.sh"
else
  bad=()
  for pair in claude-shim:claude nf-tmux-heal:nf-tmux-heal nf-tmux-watch:nf-tmux-watch nf-log.sh:nf-log.sh; do
    f="$NF/bin/${pair#*:}"
    if [[ ! -f "$f" ]]; then bad+=("${pair#*:} missing")
    elif ! cmp -s "$REPO/band/hover/${pair%%:*}" "$f"; then bad+=("${pair#*:} stale"); fi
  done
  if [[ "$(readlink -f "$NF/hover" 2>/dev/null)" != "$(readlink -f "$REPO/band/bridge")" ]]; then
    bad+=("hover link -> $(readlink "$NF/hover" 2>/dev/null || echo missing)")
  fi
  # the user unit install.sh copies (only when a systemd user manager exists); a changed unit is reinstalled by deploy
  if systemctl --user show-environment >/dev/null 2>&1; then
    u="$HOME/.config/systemd/user/nf-tmux-watch.service"
    if [[ ! -f "$u" ]]; then bad+=("nf-tmux-watch.service missing")
    elif ! cmp -s "$REPO/band/hover/nf-tmux-watch.service" "$u"; then bad+=("nf-tmux-watch.service stale"); fi
  fi
  if (( ${#bad[@]} )); then
    row BROKEN hover "$(IFS=';'; echo "${bad[*]}")" "bash $REPO/band/hover/install.sh"
  else
    row ok hover "shim, heal, watch, nf-log.sh and the bridge link match band/"
  fi
  # ~/.nerdflair/bin must come before any other claude on PATH
  pos=""
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    [[ -z "$d" ]] && continue
    d="${d%/}"
    if [[ "$d" == "$NF/bin" ]]; then pos=first; break; fi
    if [[ -x "$d/claude" ]]; then pos="$d/claude"; break; fi
  done
  case "$pos" in
    first) row ok hover-path "$NF/bin is first for claude on PATH" ;;
    "") row warn hover-path "$NF/bin is not on PATH" "open a new shell (the rc block from band/hover/install.sh puts it first)" ;;
    *) row warn hover-path "$pos comes before $NF/bin on PATH" "open a new shell, or: bash $REPO/band/hover/install.sh" ;;
  esac
fi

# 5. tmux
if ! info="$(tmux display-message -p '#{pid} #{socket_path}' 2>/dev/null)" || [[ -z "$info" ]]; then
  row warn tmux "no tmux server reachable (hover panels need one)" "tmux new-session -d"
else
  pid="${info%% *}"; sock="${info#* }"
  if [[ -S "$sock" ]]; then row ok tmux "server pid $pid, socket $sock"
  else row BROKEN tmux "server pid $pid has lost its socket $sock" "bash $REPO/band/hover/nf-tmux-heal"; fi
  tc="$(tmux show-environment -g CLAUDE_CODE_TMUX_TRUECOLOR 2>/dev/null)"
  if [[ "$tc" == CLAUDE_CODE_TMUX_TRUECOLOR=?* ]]; then row ok tmux-truecolor "CLAUDE_CODE_TMUX_TRUECOLOR set"
  else row warn tmux-truecolor "CLAUDE_CODE_TMUX_TRUECOLOR not in tmux's global env" "tmux set-environment -g CLAUDE_CODE_TMUX_TRUECOLOR 1"; fi
  be="$(tmux show-environment -g BASH_ENV 2>/dev/null)"; be="${be#BASH_ENV=}"
  if [[ -z "$be" || "$be" == -BASH_ENV ]]; then
    row warn tmux-bash-env "BASH_ENV not in tmux's global env" "tmux set-environment -g BASH_ENV <a file holding: umask 022>"
  elif [[ ! -f "$be" ]]; then
    row warn tmux-bash-env "BASH_ENV=$be does not exist" "printf 'umask 022\\n' > '$be'"
  elif ! grep -q 'umask 022' "$be"; then
    row warn tmux-bash-env "BASH_ENV=$be has no 'umask 022'" "printf 'umask 022\\n' >> '$be'"
  else row ok tmux-bash-env "BASH_ENV=$be sets umask 022"; fi
  um="$(awk '/^Umask:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
  if [[ "$um" == 0022 ]]; then row ok tmux-umask "0022"
  else row warn tmux-umask "tmux server umask is ${um:-unknown} (new ~/.claude dirs come out unreadable)" "restart tmux from a shell with umask 022: tmux kill-server, then tmux"; fi
fi

# 6. private cache dir: same rule as the renderer (util.rs cache_dir)
if [[ -n "${NERDFLAIR_CACHE_DIR:-}" ]]; then cache="$NERDFLAIR_CACHE_DIR"
elif [[ "${XDG_CACHE_HOME:-}" == /* ]]; then cache="$XDG_CACHE_HOME/nerdflair"
else cache="$HOME/.cache/nerdflair"; fi
if [[ "$cache" != /* ]]; then row BROKEN cache "NERDFLAIR_CACHE_DIR=$cache is not absolute: caches are skipped" "export NERDFLAIR_CACHE_DIR=\$HOME/.cache/nerdflair"
elif [[ -L "$cache" ]]; then row BROKEN cache "$cache is a symlink: the renderer refuses it" "mv -- '$cache' '$cache.unsafe'"
elif [[ ! -e "$cache" ]]; then row ok cache "$cache not created yet (the renderer makes it)"
elif [[ ! -d "$cache" ]]; then row BROKEN cache "$cache is not a directory" "mv -- '$cache' '$cache.unsafe'"
else
  read -r own mode < <(stat -c '%u %a' "$cache")
  if [[ "$own" != "$(id -u)" ]]; then row BROKEN cache "$cache is owned by uid $own" "mv -- '$cache' '$cache.unsafe'"
  elif (( 0$mode & 077 )); then   # group/other bits only, as util.rs: 0500 is fine, 0755 is open
    if [[ -n "${NERDFLAIR_CACHE_DIR:-}" ]]; then row BROKEN cache "$cache has mode $mode: an explicit NERDFLAIR_CACHE_DIR is refused while group/other can reach it" "chmod 700 '$cache'"
    else row warn cache "$cache has mode $mode: the renderer tightens it on the next render" "chmod 700 '$cache'"; fi
  else row ok cache "$cache (0700, yours)"; fi
fi

# 7. user units (warn only)
if ! systemctl --user show-environment >/dev/null 2>&1; then
  row info units "no systemd user manager: skipped"
else
  # claude-tmp-fix.timer is not installed or documented by this repo (added with no reason in 1ac67d0): not checked
  for u in nf-tmux-watch.service; do
    st="$(systemctl --user is-active "$u" 2>/dev/null)"
    if [[ "$st" == active ]]; then row ok "$u" active
    else row warn "$u" "${st:-unknown}" "systemctl --user enable --now $u"; fi
  done
fi

# 8. logs, last 24 h: key/reason name, count, newest time; never whole lines. One python, tail reads.
# (a failing scan is a row of its own, never an empty "nothing to report")
logs="$(python3 - "$HOME/.claude/nerdflair-errors.log" \
  "$PTYLOG" "$STATE/launcher.log" "$STATE/tmux-watch.log" 2>&1 <<'PY'
import sys, os, re, time, datetime as dt
now = time.time()
for path in sys.argv[1:]:
    name = os.path.basename(path)
    try:
        with open(path, "rb") as f:
            f.seek(0, 2); n = f.tell(); f.seek(max(0, n - 262144))   # tail read, hard byte cap
            lines = f.read().decode("utf-8", "replace").splitlines()
    except FileNotFoundError:
        print(f"ok\t{name}\tabsent"); continue
    except OSError as e:
        print(f"warn\t{name}\tunreadable ({e.strerror})"); continue
    keys, panic = {}, False
    for ln in lines:
        m = re.match(r"(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d:\d\d)(Z|[+-]\d{4})?\s+(.*)", ln)
        if not m: continue
        d, t, z, rest = m.groups()
        try:
            ts = dt.datetime.fromisoformat(f"{d}T{t}")
            if z == "Z": ts = ts.replace(tzinfo=dt.timezone.utc)
            elif z: ts = ts.replace(tzinfo=dt.datetime.strptime(z, "%z").tzinfo)
            ts = ts.timestamp()
        except ValueError:
            continue
        if now - ts > 86400: continue
        rest = re.sub(r"^\d+ ", "", rest)             # errors.log: pid
        rest = re.sub(r"^(nfpty|watch): ", "", rest)  # the component every line of that log shares
        k = re.match(r"[\w.:~/-]{1,40}?(?=:\s|\s|$)", rest)
        k = k.group(0) if k else "?"
        if "panic" in ln: panic = True
        c, newest = keys.get(k, (0, 0)); keys[k] = (c + 1, max(newest, ts))
    if not keys:
        print(f"ok\t{name}\tnothing in 24 h"); continue
    top = sorted(keys.items(), key=lambda kv: -kv[1][0])[:4]
    newest = time.strftime("%H:%M", time.localtime(max(v[1] for v in keys.values())))
    desc = ", ".join(f"{k} x{v[0]}" for k, v in top) + (f" (+{len(keys) - 4} more)" if len(keys) > 4 else "") + f"; newest {newest}"
    print(f"{'BROKEN' if panic else 'warn'}\t{name}\t{'PANIC; ' if panic else ''}{desc}\tless {path}  # read the reasons, fix what they name")
PY
)" || { row BROKEN logs "the log scan failed: ${logs//$'\n'/ }" "python3 --version  # needs python3"; logs=""; }
while IFS=$'\t' read -r st name detail fix; do [[ -n "$st" ]] && row "$st" "$name" "$detail" "$fix"; done <<<"$logs"

# 9. info only
[[ -n "${NFPTY:-}" ]] && row info wrapper "this shell is under the hover wrapper (NFPTY)" || row info wrapper "this shell is not under the hover wrapper"
recs=()
if [[ -d "$cache" && ! -L "$cache" ]]; then
  while IFS= read -r -d '' f; do
    read -r _ s _ < "$f" 2>/dev/null || s="?"
    b="${f##*/}"; recs+=("${b:0:24}=${s:0:8}")
  done < <(find "$cache" -maxdepth 1 -name 'rc-*' -type f -mmin -5 ! -newermt now -print0 2>/dev/null)
fi
row info rc-records "${#recs[@]} newer than 5 min${recs:+: $(IFS=' '; echo "${recs[*]}")}"

# output
broken=0; warns=0
for r in "${rows[@]}"; do case "${r%%$'\t'*}" in BROKEN) broken=$((broken + 1)) ;; warn) warns=$((warns + 1)) ;; esac; done
if (( broken )); then verdict="BROKEN: $broken check(s) broken, $warns warning(s); run the fix lines above"
elif (( warns )); then verdict="ok with $warns warning(s)"
else verdict="all ok"; fi
if (( json )); then
  printf '%s\n' "${rows[@]}" | jq -R -s --arg v "$verdict" --argjson b "$broken" --argjson w "$warns" \
    '{checks: [split("\n")[] | select(length > 0) | split("\t") | {status: .[0], check: .[1], detail: .[2], fix: (.[3] // "")}],
      broken: $b, warnings: $w, verdict: $v}'
else
  for r in "${rows[@]}"; do
    IFS=$'\t' read -r st name detail fix <<<"$r"
    printf '%-6s  %-22s  %s\n' "$st" "$name" "$detail"
    [[ "$st" != ok && "$st" != info && -n "$fix" ]] && printf '%-6s  %-22s  fix: %s\n' "" "" "$fix"
  done
  echo "doctor: $verdict"
fi
(( broken == 0 ))
