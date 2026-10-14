#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# popup.sh — draw one nerdflair readout's detail as a floating tmux popup.
#
# WHY TMUX AND NOT THE ENGINE. A Claude Code plugin draws inside a region and
# is cut off at its edge. Three overlay designs were tried and each died on a
# rule read out of the 2.1.295 binary: a card above the band is CLAMPED onto
# row 0, a card below it is painted over by the prompt, and an in-flow card
# shoves the screen. tmux has no such limit, because tmux owns the screen,
# which is exactly why its own menus float.
#
# WHY A CLICK AND NOT A HOVER. No hover event crosses to a plugin: the engine
# puts the terminal in mouse mode 1003 and consumes motion itself, so neither
# we nor tmux ever learn the pointer moved. `ui.press` IS delivered, so the
# band makes each readout a Button and calls this on press.
#
# Usage: popup.sh <x-column> <title> <body...>
# The popup closes on any key, and tmux times it out on its own if the client
# goes away, so it can never strand the terminal in a modal state.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

X=${1:-0}; shift || true
TITLE=${1:-nerdflair}; shift || true
BODY=${*:-}

# Every refusal exits non-zero with ONE line on stderr, so the plugin can show
# the reason instead of a click that silently does nothing.
#   3 = cannot popup here (no tmux, or not inside tmux)   4 = tmux failed
die() { printf 'popup.sh: %s\n' "$2" >&2; exit "$1"; }
command -v tmux >/dev/null 2>&1 || die 3 "tmux is not installed; popups need tmux"
[[ -n "${TMUX:-}" ]] || die 3 "not inside tmux; popups need a tmux session"

# Width from the content, clamped so it never exceeds the client.
if ! cols=$(tmux display-message -p '#{client_width}' 2>&1) || [[ ! "$cols" =~ ^[0-9]+$ ]]; then
  printf 'popup.sh: could not read the client width (%s); assuming 120 columns\n' "$cols" >&2
  cols=120
fi
w=$(( ${#BODY} + 4 ))
(( w < ${#TITLE} + 4 )) && w=$(( ${#TITLE} + 4 ))
(( w > cols - 4 )) && w=$(( cols - 4 ))
(( w < 24 )) && w=24

# Keep the popup on screen when the readout sits near the right edge.
(( X + w > cols )) && X=$(( cols - w ))
(( X < 0 )) && X=0

# -E closes the popup when the command exits, so `read -n1` means "any key
# dismisses". Without that the popup would persist and hold the keyboard.
err=$(tmux display-popup -w "$w" -h 6 -x "$X" -y S -E \
  "printf '\033[1m%s\033[0m\n\n%s\n\n\033[2many key to close\033[0m' \
     $(printf '%q' "$TITLE") $(printf '%q' "$BODY"); read -rsn1" 2>&1)
rc=$?
# tmux's own words, not discarded: popup needs tmux 3.2+, a client, a sane size.
(( rc == 0 )) || die 4 "tmux display-popup failed (exit $rc): ${err//$'\n'/ }"
