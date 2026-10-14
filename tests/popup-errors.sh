#!/usr/bin/env bash
# popup.sh must refuse LOUDLY: a non-zero exit and one line on stderr saying
# why, for each way it cannot draw. No tmux server is touched: the cases run
# with TMUX unset, with a PATH that has no tmux, and with a fake tmux script
# that fails the way tmux < 3.2 or a client-less server does.
# Usage: tests/popup-errors.sh [path/to/popup.sh]   (default band/popup.sh)
set -uo pipefail
umask 022 # a restrictive caller umask would make the temp dirs unusable

POPUP=$(realpath "${1:-$(dirname "$0")/../band/popup.sh}")
tmp=$(mktemp -d) || exit 1
trap 'rm -r "$tmp"' EXIT
fail=0

# Runs popup.sh with the given env prefix; sets $code and $err.
run() { err=$(env "$@" bash "$POPUP" 0 Title Body 2>&1 >/dev/null); code=$?; }
check() { # name, want-nonzero-code, stderr regex
  if (( code != 0 )) && [[ "$err" =~ $3 ]] && { [[ -z "$2" ]] || (( code == $2 )); }; then
    echo "PASS $1 (exit $code: $err)"
  else
    echo "FAIL $1 (exit $code, stderr: '${err}')"; fail=1
  fi
}

# bash and the coreutils popup.sh needs, but no tmux.
mkdir "$tmp/bin-notmux"
for c in bash env printf; do ln -s "$(command -v "$c")" "$tmp/bin-notmux/$c"; done
run -u TMUX PATH="$tmp/bin-notmux"
check "no tmux on PATH" 3 'tmux is not installed'

# A tmux exists but the shell is not inside one.
mkdir "$tmp/bin-fake"
cat > "$tmp/bin-fake/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  display-message) echo 100 ;;
  display-popup) echo "no current client" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin-fake/tmux"
run -u TMUX PATH="$tmp/bin-fake:$PATH"
check "not inside tmux" 3 'not inside tmux'

# Inside tmux (as far as the script can tell) but display-popup fails: its own
# stderr must reach ours instead of /dev/null.
run TMUX=fake,1,0 PATH="$tmp/bin-fake:$PATH"
check "display-popup fails" 4 'display-popup failed.*no current client'

exit $fail
