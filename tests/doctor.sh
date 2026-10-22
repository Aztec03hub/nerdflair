#!/usr/bin/env bash
# doctor.sh - `nerdflair doctor` against a fully fake HOME: one all-ok case, then one case per
# BROKEN/warn check, then deploy.sh --dry-run. Stub tmux and systemctl on PATH; the real HOME,
# the real tmux server and the installed copies are never touched.
#   needs: rust/target/release/nerdflair-statusline built from this checkout
set -euo pipefail
umask 022
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT="$REPO/rust/target/release/nerdflair-statusline"
[[ -x "$BUILT" ]] || { echo "build first: cd rust && cargo build --release" >&2; exit 2; }
T="$(mktemp -d)"
bgpid=""
cleanup() { [[ -n "$bgpid" ]] && kill "$bgpid" 2>/dev/null; rm -rf -- "$T"; }
trap cleanup EXIT
fail=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

fresh() { # a clean all-ok fake install, in a new dir each time (only $T itself is ever removed)
  H="$(mktemp -d -p "$T")"; S="$H/stubs"; mkdir -p "$H/.local/bin" "$H/.claude" "$H/.nerdflair/bin" "$H/cache" "$H/plug/.claude-plugin" "$S"
  chmod 700 "$H/cache"
  cp "$BUILT" "$H/.local/bin/nerdflair-statusline"
  printf '{"apiKeyHelper":"SECRET-DO-NOT-PRINT","statusLine":{"type":"command","command":"~/.local/bin/nerdflair-statusline"}}\n' > "$H/.claude/settings.json"
  v="$(bash "$REPO/band/sync-local-plugin.sh" --stamp)"
  printf '{"version":"%s"}\n' "$v" > "$H/plug/.claude-plugin/plugin.json"
  printf '{"plugins":{"nerdflair-band@local":[{"version":"%s"}]}}\n' "$v" > "$H/installed.json"
  cp "$REPO/band/hover/claude-shim" "$H/.nerdflair/bin/claude"
  cp "$REPO/band/hover/nf-tmux-heal" "$REPO/band/hover/nf-tmux-watch" "$REPO/band/hover/nf-log.sh" "$H/.nerdflair/bin/"
  ln -s "$REPO/band/bridge" "$H/.nerdflair/hover"
  printf 'umask 022\n' > "$H/bashenv"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$H/tmux.sock"
  # stub tmux: the server pid is the test's own process (umask 022) unless TMUX_PID says otherwise
  cat > "$S/tmux" <<EOF
#!/bin/bash
[[ -f "$S/tmux.down" ]] && exit 1
case "\$1" in
  display-message) echo "\${TMUX_PID:-$$} $H/tmux.sock" ;;
  show-environment) v=\$(cat "$S/env.\$3" 2>/dev/null) || { echo "unknown variable: \$3" >&2; exit 1; }; echo "\$3=\$v" ;;
esac
EOF
  printf '1' > "$S/env.CLAUDE_CODE_TMUX_TRUECOLOR"; printf '%s' "$H/bashenv" > "$S/env.BASH_ENV"
  cat > "$S/systemctl" <<EOF
#!/bin/bash
[[ -f "$S/systemd.down" ]] && exit 1
case "\$2" in show-environment) exit 0 ;; is-active) cat "$S/unit.\$3" 2>/dev/null || echo active ;; esac
EOF
  chmod +x "$S/tmux" "$S/systemctl"
}
doc() { # run doctor in the fake HOME; sets out and rc
  rc=0
  out="$(env -i HOME="$H" PATH="$H/.nerdflair/bin:$S:/usr/bin:/bin" NERDFLAIR_CACHE_DIR="$H/cache" \
    NERDFLAIR_PLUGIN_DEST="$H/plug" NERDFLAIR_INSTALLED_PLUGINS="$H/installed.json" ${TMUX_PID:+TMUX_PID=$TMUX_PID} \
    bash "$REPO/scripts/nerdflair.sh" doctor "$@" 2>&1)" || rc=$?
}
expect() { # name rc regex: doctor exited rc and printed a line matching regex
  if [[ "$rc" == "$2" ]] && printf '%s\n' "$out" | command grep -qE -- "$3"; then ok "$1"
  else bad "$1 (rc=$rc, wanted $2 and /$3/)"; printf '%s\n' "$out" | sed 's/^/        /'; fi
}

echo "doctor:"
fresh; t0=$(date +%s%N); doc; t1=$(date +%s%N)
expect "all ok: exit 0, verdict all ok" 0 '^doctor: all ok$'
(( (t1 - t0) / 1000000 < 2000 )) && ok "runs under 2 s ($(( (t1 - t0) / 1000000 )) ms)" || bad "took $(( (t1 - t0) / 1000000 )) ms"
printf '%s' "$out" | command grep -q SECRET && bad "printed something else from settings.json" || ok "nothing else from settings.json is printed"
before="$(cd "$H" && find . -printf '%p %s %T@\n' | sort | sha256sum)"
doc --json
[[ "$(jq -r '.verdict' <<<"$out")" == "all ok" && "$(jq '.checks | length' <<<"$out")" -gt 10 ]] && ok "--json gives the same as JSON" || bad "--json: $out"
[[ "$(cd "$H" && find . -printf '%p %s %T@\n' | sort | sha256sum)" == "$before" ]] && ok "doctor wrote nothing in HOME" || bad "doctor changed the fake HOME"

# a build from before --version: a renderer with no stamp. NERDFLAIR_OLD_BIN=<main's build> uses a real one.
fresh; if [[ -n "${NERDFLAIR_OLD_BIN:-}" ]]; then cp "$NERDFLAIR_OLD_BIN" "$H/.local/bin/nerdflair-statusline"
else printf '#!/bin/sh\ncat >/dev/null\necho rendered\n' > "$H/.local/bin/nerdflair-statusline"; fi
doc; expect "binary without --version: BROKEN" 1 '^BROKEN  renderer .*no --version'
expect "  ...fix is build-rust.sh" 1 'fix: bash .*/scripts/build-rust.sh'
fresh; printf '#!/bin/sh\necho "nerdflair-statusline 0.1.0 src:00000000"\n' > "$H/.local/bin/nerdflair-statusline"
doc; expect "binary from other sources: BROKEN" 1 '^BROKEN  renderer .*installed src:00000000, this checkout is src:'
fresh; mv "$H/.local/bin/nerdflair-statusline" "$H/.local/bin/nerdflair-statusline".gone; doc; expect "binary missing: BROKEN" 1 '^BROKEN  renderer .*missing'

fresh; printf '{"statusLine":{"type":"command","command":"/opt/other"}}\n' > "$H/.claude/settings.json"
doc; expect "statusLine elsewhere: BROKEN" 1 '^BROKEN  statusline .*something else'
fresh; printf '{"statusLine":{"type":"command","command":"bash /x/scripts/statusline.sh"}}\n' > "$H/.claude/settings.json"
doc; expect "statusLine on the bash renderer: warn" 0 '^warn    statusline '
fresh; mv "$H/.claude/settings.json" "$H/.claude/settings.json".gone; doc; expect "settings.json missing: BROKEN" 1 '^BROKEN  statusline .*missing'

fresh; printf '{"version":"0.1.0"}\n' > "$H/plug/.claude-plugin/plugin.json"
doc; expect "published plugin stale: BROKEN" 1 '^BROKEN  plugin .*published copy is STALE'
fresh; printf '{"plugins":{"nerdflair-band@local":[{"version":"0.1.0-deadbeef"}]}}\n' > "$H/installed.json"
doc; expect "installed plugin stale (the 2026-10-21 bug): BROKEN" 1 '^BROKEN  plugin .*INSTALLED plugin is STALE'

fresh; echo '# edited' >> "$H/.nerdflair/bin/nf-tmux-heal"; doc; expect "hover file stale: BROKEN" 1 '^BROKEN  hover .*nf-tmux-heal stale'
fresh; mv "$H/.nerdflair/hover" "$H/.nerdflair/hover".gone; doc; expect "hover bridge link missing: BROKEN" 1 '^BROKEN  hover .*hover link'
fresh; mkdir "$S/early"; printf '#!/bin/sh\n' > "$S/early/claude"; chmod +x "$S/early/claude"
out="$(env -i HOME="$H" PATH="$S/early:$H/.nerdflair/bin:$S:/usr/bin:/bin" NERDFLAIR_CACHE_DIR="$H/cache" NERDFLAIR_PLUGIN_DEST="$H/plug" \
  NERDFLAIR_INSTALLED_PLUGINS="$H/installed.json" bash "$REPO/scripts/doctor.sh" 2>&1)" && rc=0 || rc=$?
expect "real claude before the shim on PATH: warn" 0 '^warn    hover-path .*comes before'

fresh; touch "$S/tmux.down"; doc; expect "no tmux server: warn" 0 '^warn    tmux .*no tmux server'
fresh; mv "$H/tmux.sock" "$H/tmux.sock".gone; doc; expect "tmux socket gone: BROKEN" 1 '^BROKEN  tmux .*lost its socket'
fresh; mv "$S/env.CLAUDE_CODE_TMUX_TRUECOLOR" "$S/env.CLAUDE_CODE_TMUX_TRUECOLOR".gone; doc; expect "no truecolor in tmux env: warn" 0 '^warn    tmux-truecolor'
fresh; mv "$S/env.BASH_ENV" "$S/env.BASH_ENV".gone; doc; expect "no BASH_ENV in tmux env: warn" 0 '^warn    tmux-bash-env .*not in'
fresh; printf 'true\n' > "$H/bashenv"; doc; expect "BASH_ENV without umask 022: warn" 0 "^warn    tmux-bash-env .*no 'umask 022'"
fresh; (umask 077; exec sleep 300) & bgpid=$!
TMUX_PID=$bgpid; doc; TMUX_PID=""; kill "$bgpid"; wait "$bgpid" 2>/dev/null || true; bgpid=""
expect "tmux server umask 0077: warn, restart named" 0 '^warn    tmux-umask .*0077'
expect "  ...fix names a tmux restart" 0 'fix: restart tmux'

fresh; chmod 755 "$H/cache"; doc; expect "cache dir 0755: BROKEN" 1 '^BROKEN  cache .*mode 755'
fresh; mv "$H/cache" "$H/cache.gone"; mkdir -m 700 "$H/realcache"; ln -s "$H/realcache" "$H/cache"; doc; expect "cache dir a symlink: BROKEN" 1 '^BROKEN  cache .*symlink'

fresh; echo failed > "$S/unit.claude-tmp-fix.timer"; doc; expect "unit inactive: warn" 0 '^warn    claude-tmp-fix.timer +failed'
fresh; touch "$S/systemd.down"; doc; expect "no systemd user manager: skipped cleanly" 0 '^info    units .*skipped'

fresh; mkdir -p "$H/.local/state/nerdflair"
now="$(date +%Y-%m-%dT%H:%M:%S%z)"
printf '%s shim: tmux heal failed: SECRETLINE\n%s shim: tmux heal failed: again\n2020-01-01T00:00:00+0000 old: ancient\n' "$now" "$now" > "$H/.local/state/nerdflair/launcher.log"
doc; expect "launcher.log errors in 24 h: warn with key and count" 0 '^warn    launcher.log +shim x2; newest'
printf '%s' "$out" | command grep -qE 'SECRETLINE|old' && bad "log lines were printed whole or an old line counted" || ok "only key, count and time are printed; a 2020 line is ignored"
printf '%s 123 panic: thread main panicked at x\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$H/.claude/nerdflair-errors.log"
doc; expect "panic in the error log: BROKEN" 1 '^BROKEN  nerdflair-errors.log +PANIC; panic x1'

fresh; NFPTY=1; doc; unset NFPTY
printf 'v1 on 1700000000 cli\n' > "$H/cache/rc-abc"; doc
expect "rc record newer than 5 min is listed with its state" 0 '^info    rc-records +1 newer than 5 min: rc-abc=on'

echo "deploy.sh --dry-run:"
fresh; printf '#!/bin/sh\necho "nerdflair-statusline 0.1.0 src:00000000"\n' > "$H/.local/bin/nerdflair-statusline"
printf '{"version":"0.1.0"}\n' > "$H/plug/.claude-plugin/plugin.json"
before="$(cd "$H" && find . -printf '%p %s %T@\n' | sort | sha256sum)"
rc=0; out="$(env -i HOME="$H" PATH="$H/.nerdflair/bin:$S:/usr/bin:/bin" NERDFLAIR_CACHE_DIR="$H/cache" NERDFLAIR_PLUGIN_DEST="$H/plug" \
  NERDFLAIR_INSTALLED_PLUGINS="$H/installed.json" bash "$REPO/scripts/deploy.sh" --dry-run 2>&1)" || rc=$?
expect "plans build-rust.sh for a stale renderer" 0 'scripts/build-rust.sh$'
expect "plans sync-local-plugin.sh for a stale plugin" 0 'band/sync-local-plugin.sh$'
printf '%s' "$out" | command grep -q 'hover/install.sh' && bad "planned hover install with current hover files" || ok "skips the hover install when its files match"
expect "names /reload-plugins as a follow-up" 0 '/reload-plugins'
[[ "$(cd "$H" && find . -printf '%p %s %T@\n' | sort | sha256sum)" == "$before" ]] && ok "--dry-run changed nothing" || bad "--dry-run changed the fake HOME"
fresh; rc=0; out="$(env -i HOME="$H" PATH="$H/.nerdflair/bin:$S:/usr/bin:/bin" NERDFLAIR_CACHE_DIR="$H/cache" NERDFLAIR_PLUGIN_DEST="$H/plug" \
  NERDFLAIR_INSTALLED_PLUGINS="$H/installed.json" bash "$REPO/scripts/deploy.sh" --dry-run 2>&1)" || rc=$?
expect "nothing to do when everything matches" 0 'nothing to do'

(( fail == 0 )) && echo "doctor: all passed" || { echo "doctor: FAILURES"; exit 1; }
