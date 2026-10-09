#!/usr/bin/env bash
# install.sh - make a bare `claude` start under the hover wrapper.
#
#   install.sh [install|uninstall|status]
#
# What install does, all of it reversible and none of it touching Claude Code:
#   1. ~/.nerdflair/hover   -> link to band/bridge (the wrapper code)
#   2. ~/.nerdflair/bin/    -> claude (the shim) and nf-tmux-heal, copied
#   3. a marked block at the END of ~/.bashrc and ~/.zshrc (if present) that
#      puts ~/.nerdflair/bin first on PATH and keeps tmux's socket out of /tmp
#
# Why this survives a Claude Code update: the shim finds the real claude on
# PATH at every start, and the updater only rewrites that real file.
# Why it cannot loop or lock you out: the shim execs plain claude whenever
# wrapping is impossible, and nothing here starts or restarts a service.
set -euo pipefail

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
case ":$PATH:" in *":$HOME/.nerdflair/bin:"*) PATH="${PATH//:$HOME\/.nerdflair\/bin:/:}" ;; esac
export PATH="$HOME/.nerdflair/bin:$PATH"
# tmux's socket lives in /tmp by default, and anything sweeping /tmp strands
# the server. A running server keeps its current socket; this applies to the
# next one, so it never splits an existing session off from its clients.
if [ -z "${TMUX_TMPDIR:-}" ] && [ ! -S "/tmp/tmux-$(id -u)/default" ] && [ -d "${XDG_RUNTIME_DIR:-}" ]; then
  export TMUX_TMPDIR="$XDG_RUNTIME_DIR"
fi
# <<< nerdflair hover <<<
EOF
}

rcfiles() { for f in "$HOME/.bashrc" "$HOME/.zshrc"; do [[ -f "$f" ]] && echo "$f"; done; }

# A file with a BEGIN marker and no END would lose everything after it, so the
# markers must pair up before anything is stripped.
paired() { # file
  local b e
  b=$(grep -cxF "$BEGIN" "$1" || true); e=$(grep -cxF "$END" "$1" || true)
  [[ "$b" == "$e" && "$b" -le 1 ]]
}

strip() { # file: print it without our block
  awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$1"
}

case "${1:-install}" in
  install)
    mkdir -p "$NF/bin"
    ln -sfn "$BRIDGE" "$NF/hover"
    install -m 755 "$HERE/claude-shim" "$NF/bin/claude"
    install -m 755 "$HERE/nf-tmux-heal" "$NF/bin/nf-tmux-heal"
    for f in $(rcfiles); do
      paired "$f" || { echo "install: $f has an unmatched nerdflair marker; fix it by hand, nothing changed there" >&2; continue; }
      tmp="$f.nf.$$"
      { strip "$f"; block; } > "$tmp"
      if ! cmp -s "$tmp" "$f"; then cp -p "$f" "$f.nf-backup"; cat "$tmp" > "$f"; fi
      rm -f "$tmp"
      echo "  rc block in $f"
    done
    echo "hover installed: new shells start claude under the wrapper (inside tmux)"
    ;;
  uninstall)
    for f in $(rcfiles); do
      paired "$f" || { echo "uninstall: $f has an unmatched nerdflair marker; fix it by hand" >&2; continue; }
      tmp="$f.nf.$$"; strip "$f" > "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"
    done
    rm -f "$NF/bin/claude" "$NF/bin/nf-tmux-heal" "$NF/hover"
    rmdir "$NF/bin" 2>/dev/null || true
    echo "hover removed"
    ;;
  status)
    for f in $(rcfiles); do
      if grep -qF "$BEGIN" "$f"; then echo "rc block: yes ($f)"; else echo "rc block: NO ($f)"; fi
    done
    [[ -x "$NF/bin/claude" ]] && echo "shim: yes" || echo "shim: NO"
    echo "claude resolves to: $(PATH="$NF/bin:$PATH" command -v claude)"
    ;;
  *) echo "usage: install.sh [install|uninstall|status]" >&2; exit 2 ;;
esac
