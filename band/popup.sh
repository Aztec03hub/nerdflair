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

command -v tmux >/dev/null 2>&1 || exit 0
[[ -n "${TMUX:-}" ]] || exit 0   # not inside tmux: no popup, and no error either

# Width from the content, clamped so it never exceeds the client.
cols=$(tmux display-message -p '#{client_width}' 2>/dev/null || echo 120)
w=$(( ${#BODY} + 4 ))
(( w < ${#TITLE} + 4 )) && w=$(( ${#TITLE} + 4 ))
(( w > cols - 4 )) && w=$(( cols - 4 ))
(( w < 24 )) && w=24

# Keep the popup on screen when the readout sits near the right edge.
(( X + w > cols )) && X=$(( cols - w ))
(( X < 0 )) && X=0

# -E closes the popup when the command exits, so `read -n1` means "any key
# dismisses". Without that the popup would persist and hold the keyboard.
tmux display-popup -w "$w" -h 6 -x "$X" -y S -E \
  "printf '\033[1m%s\033[0m\n\n%s\n\n\033[2many key to close\033[0m' \
     $(printf '%q' "$TITLE") $(printf '%q' "$BODY"); read -rsn1" \
  2>/dev/null
