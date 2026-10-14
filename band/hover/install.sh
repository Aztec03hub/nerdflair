#!/usr/bin/env bash
# install.sh - make a bare `claude` start under the hover wrapper.
#
#   install.sh [install|uninstall|status]
#
# What install does, all of it reversible and none of it touching Claude Code:
#   1. ~/.nerdflair/hover   -> link to band/bridge (the wrapper code)
#   2. ~/.nerdflair/bin/    -> claude (the shim) and nf-tmux-heal, copied
#   3. a marked block at the END of ~/.bashrc, ~/.zshrc and the one login file bash
#      reads (~/.bash_profile, ~/.bash_login or ~/.profile; ~/.profile is created if none) that
#      puts ~/.nerdflair/bin first on PATH and keeps tmux's socket out of /tmp
#
# Why this survives a Claude Code update: the shim finds the real claude on
# PATH at every start, and the updater only rewrites that real file.
# Why it cannot loop or lock you out: the shim execs plain claude whenever
# wrapping is impossible, and nothing here starts or restarts a service.
set -euo pipefail
# mapfile and empty-array expansion under set -u need bash 4.4+ (not macOS /bin/bash 3.2).
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo "install.sh needs bash 4.4 or newer" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$(cd "$HERE/../bridge" && pwd)"
NF="$HOME/.nerdflair"
BEGIN="# >>> nerdflair hover >>>"
END="# <<< nerdflair hover <<<"

block() {
  cat <<'EOF'
# >>> nerdflair hover >>>
# Managed by nerdflair (band/hover/install.sh). Remove with: install.sh uninstall
# Put the shim first so a bare `claude` gets hover panels, whatever else
# has edited PATH since.
if [ -n "${BASH_VERSION:-}${ZSH_VERSION:-}" ]; then   # the substitution below is not POSIX sh
case ":$PATH:" in *":$HOME/.nerdflair/bin:"*)
  _nf=":$PATH:"; _nf="${_nf//:$HOME\/.nerdflair\/bin:/:}"; _nf="${_nf#:}"; PATH="${_nf%:}"; unset _nf ;;
esac
fi
export PATH="$HOME/.nerdflair/bin${PATH:+:$PATH}"
# A login shell reads .profile AFTER .bashrc, and .profile prepends ~/.local/bin
# and friends, burying the shim. A function wins over any PATH order.
unalias claude 2>/dev/null || true      # an alias would break the definition below and beat it
claude() {
  if [ -x "$HOME/.nerdflair/bin/claude" ]; then "$HOME/.nerdflair/bin/claude" "$@"; else command claude "$@"; fi
}
# tmux's socket lives in /tmp by default, and anything sweeping /tmp strands
# the server. A running server keeps its current socket; this applies to the
# next one, so it never splits an existing session off from its clients.
if [ -z "${TMUX_TMPDIR:-}" ] && [ ! -S "/tmp/tmux-$(id -u)/default" ] && [ -d "${XDG_RUNTIME_DIR:-}" ]; then
  export TMUX_TMPDIR="$XDG_RUNTIME_DIR"
fi
# <<< nerdflair hover <<<
EOF
}

# .profile too: a bash login shell (tmux windows, WSL terminals) runs it AFTER
# .bashrc and it prepends ~/.local/bin, so the block must end it as well. A
# ~/.bash_profile or ~/.bash_login makes bash skip .profile, so they are covered.
# (zsh reads .zprofile BEFORE .zshrc; .zshrc already ends last, so no .zprofile.)
# The ONE login file bash reads: the first of these that exists. The block goes
# in that one only; if none exists, ~/.profile is created, because without any
# of them a login shell (a tmux window) reads no startup file at all.
loginfile() {
  local f
  for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do [[ -f "$f" ]] && { echo "$f"; return; }; done
  echo "$HOME/.profile"
}
# Where the block belongs: .bashrc and .zshrc if present, and the login file.
rcfiles() {
  local f
  for f in "$HOME/.bashrc" "$HOME/.zshrc"; do [[ -f "$f" ]] && echo "$f"; done
  echo "$(loginfile)"
}
# Files that may hold a block this version would not write (an earlier version's
# .zprofile, a login file bash does not read): stripped on install, never added.
legacy() {
  local f chosen; chosen=$(loginfile)
  for f in "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    [[ -f "$f" && "$f" != "$chosen" ]] && echo "$f"
  done
  return 0
}

# A file with a BEGIN marker and no END would lose everything after it, so the
# markers must pair up before anything is stripped.
paired() { # file
  local b e
  # CRLF markers would count as zero and make every install append another block.
  if grep -qE "^(${BEGIN}|${END})[[:space:]]*"$'\r' "$1"; then
    echo "install: $1 has CRLF line endings on a nerdflair marker; convert it first" >&2; return 2
  fi
  b=$(grep -cxF "$BEGIN" "$1" || true); e=$(grep -cxF "$END" "$1" || true)
  [[ "$b" == "$e" && "$b" -le 1 ]] || return 1
  # and in the right order: an END above its BEGIN pairs by count but makes
  # strip delete everything after the BEGIN
  [[ "$b" == 0 ]] || [[ $(grep -nxF "$BEGIN" "$1" | cut -d: -f1) -lt $(grep -nxF "$END" "$1" | cut -d: -f1) ]]
}

strip() { # file: print it without our block
  awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$1"
}

# Take our block out of one file. A file we created empty (the backup made at
# install is empty too) is removed rather than left behind as a 0-byte file; a
# backup is removed only if it is exactly what the file is now.
remove_block() { # file [uninstall]
  local f=$1 rc=0 tmp
  grep -qxF "$BEGIN" "$f" 2>/dev/null || return 0
  paired "$f" || rc=$?
  if (( rc == 1 )); then echo "${2:-install}: $f has an unmatched nerdflair marker; fix it by hand" >&2; fi
  (( rc == 0 )) || return 0
  tmp="$f.nf.$$"; strip "$f" > "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"
  cleanup_backup "$f"
}
cleanup_backup() { # file
  local f=$1
  if [[ -f "$f.nf-backup" ]]; then
    if cmp -s "$f.nf-backup" "$f"; then
      rm -f "$f.nf-backup"
      # A file we created (recorded at install) and that is still empty goes
      # back to absent; a file that existed, empty or not, is left alone.
      if [[ ! -s "$f" ]] && grep -qxF "$f" "$NF/created" 2>/dev/null; then rm -f "$f"; fi
    else
      echo "uninstall: kept $f.nf-backup (it differs from $f); remove it when you no longer need it"
    fi
  fi
}

case "${1:-install}" in
  install)
    mkdir -p "$NF/bin"
    ln -sfn "$BRIDGE" "$NF/hover"
    install -m 755 "$HERE/claude-shim" "$NF/bin/claude"
    install -m 755 "$HERE/nf-tmux-heal" "$NF/bin/nf-tmux-heal"
    install -m 755 "$HERE/nf-tmux-watch" "$NF/bin/nf-tmux-watch"
    # A user service that notices a deleted tmux socket the moment it happens,
    # logs what was running, and repairs it. Skipped quietly where there is no
    # systemd user manager; everything else works without it.
    if systemctl --user show-environment >/dev/null 2>&1; then
      mkdir -p "$HOME/.config/systemd/user"
      install -m 644 "$HERE/nf-tmux-watch.service" "$HOME/.config/systemd/user/nf-tmux-watch.service"
      systemctl --user daemon-reload
      systemctl --user enable --now nf-tmux-watch.service >/dev/null 2>&1 && echo "  tmux socket watcher running"
    fi
    done=0; skipped=0
    # The file lists are read into arrays, never word-split: $HOME may hold a space.
    mapfile -t old < <(legacy)
    for f in "${old[@]}"; do   # a block an earlier version wrote there: remove it, add nothing
      remove_block "$f"
    done
    if [[ ! -f "$(loginfile)" ]]; then      # see loginfile
      : > "$(loginfile)"
      # Remembered, so uninstall removes only a file WE created: an empty file
      # the user kept is theirs and stays.
      printf '%s\n' "$(loginfile)" >> "$NF/created"
    fi
    mapfile -t targets < <(rcfiles)
    for f in "${targets[@]}"; do
      # The block's `unalias claude` would drop a user's own alias (and its flags).
      if grep -qE '^[[:space:]]*alias[[:space:]]+claude=' "$f" 2>/dev/null; then
        echo "install: WARNING $f defines alias claude; the block replaces it. Move its flags into settings or the shim." >&2
      fi
      rc=0; paired "$f" || rc=$?
      if (( rc == 1 )); then echo "install: $f has an unmatched nerdflair marker; fix it by hand, nothing changed there" >&2; fi
      (( rc == 0 )) || { skipped=$((skipped + 1)); continue; }
      done=$((done + 1))
      tmp="$f.nf.$$"
      { strip "$f"; block; } > "$tmp"
      if ! cmp -s "$tmp" "$f"; then
        # The backup is the file as the user left it: made once, never replaced
        # by a later install (that would overwrite it with a version holding our old block).
        [[ -e "$f.nf-backup" ]] || cp -p "$f" "$f.nf-backup"
        cat "$tmp" > "$f"
      fi
      rm -f "$tmp"
      echo "  rc block in $f"
    done
    echo "hover installed: new shells start claude under the wrapper (inside tmux); $done rc file(s) updated, $skipped skipped"
    ;;
  uninstall)
    mapfile -t every < <(rcfiles; legacy)
    for f in "${every[@]}"; do   # every file a block could be in
      [[ -f "$f" ]] || continue
      remove_block "$f" uninstall
    done
    if systemctl --user show-environment >/dev/null 2>&1; then
      systemctl --user disable --now nf-tmux-watch.service >/dev/null 2>&1 || true
      rm -f "$HOME/.config/systemd/user/nf-tmux-watch.service"
      systemctl --user daemon-reload
    fi
    rm -f "$NF/bin/claude" "$NF/bin/nf-tmux-heal" "$NF/bin/nf-tmux-watch" "$NF/hover" "$NF/created"
    rmdir "$NF/bin" "$NF" 2>/dev/null || true
    echo "hover removed"
    ;;
  status)
    mapfile -t targets < <(rcfiles)
    for f in "${targets[@]}"; do
      if grep -qF "$BEGIN" "$f" 2>/dev/null; then echo "rc block: yes ($f)"; else echo "rc block: NO ($f); run install.sh again"; fi
    done
    # A login file created after install (a new ~/.bash_profile hides ~/.profile
    # from bash) has no block until install runs again; this is how it is noticed.
    echo "login file bash reads: $(loginfile)"
    [[ -x "$NF/bin/claude" ]] && echo "shim: yes" || echo "shim: NO"
    # Copied, not linked, so a repo update does not reach them by itself.
    for pair in "claude-shim:claude" "nf-tmux-heal:nf-tmux-heal" "nf-tmux-watch:nf-tmux-watch"; do
      if [[ -f "$NF/bin/${pair#*:}" ]] && ! cmp -s "$HERE/${pair%%:*}" "$NF/bin/${pair#*:}"; then
        echo "STALE: $NF/bin/${pair#*:} differs from the repo copy; run install.sh again"
      fi
    done
    echo "claude resolves to: $(PATH="$NF/bin:$PATH" command -v claude)"
    ;;
  *) echo "usage: install.sh [install|uninstall|status]" >&2; exit 2 ;;
esac
