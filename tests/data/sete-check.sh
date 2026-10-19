#!/usr/bin/env bash
# sete-check.sh - run by tests/log-sanitizers.sh as a FILE (never `bash -c`): sources the two
# bash loggers under `set -eu`, as hooks/bell.sh, scripts/nerdflair.sh and band/hover/install.sh
# do, and logs a string with a raw 0x9b and a valid CJK string. Under set -e a logger whose
# byte loop returned non-zero (an `(( i++ ))` at 0) used to kill the caller.
# Usage: sete-check.sh REPO WORKDIR     Prints SURVIVED when the shell lived to the end.
set -eu
REPO=$1 W=$2
export HOME="$W/home" NF_STATE_DIR="$W/state" NF_LOG_NOSTAMP=1 NERDFLAIR_ERR_STAMP_DIR="$W/stamps"
mkdir -p "$HOME/.claude" "$NF_STATE_DIR" "$NERDFLAIR_ERR_STAMP_DIR"
. "$REPO/scripts/lib.sh"
. "$REPO/band/hover/nf-log.sh"
_nf_log_line setekey "a$(printf '\x9b')b"
_nf_log_line setekey "$(printf '\xe6\x97\xa5\xe6\x9c\xac')"
nf_log setecomp "a$(printf '\x92')b"
nf_log setecomp "$(printf '\xe6\x97\xa5\xe6\x9c\xac')"
# Unwritable log: the logger degrades to stderr and the caller must still live (a bare mkdir or a
# bare `return 1` used to end every set -e caller).
NF_ERR_LOG=/proc/nonexistent/x.log; _NF_MEM=" "
_nf_err unwritable-dir "log under a directory that cannot be made"
mkdir -p "$W/logdir"; NF_ERR_LOG="$W/logdir"; _NF_MEM=" "
_nf_err unwritable-isdir "log path is a directory"
echo SURVIVED
