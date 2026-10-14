# Review round 25 (read-only) of 4ff12d3

Scope: `git diff 2b2aa83..4ff12d3` (statusline.sh:74, README.md:64, silent-failures.sh new `git-killed-no-timeout` case), then the wider branch. Rounds 18 to 24 and worklog-round19-fixes read first; fixed items and the /tmp git-cache symlink item skipped. No source edited.

Ran in the repo: `bash tests/difftest.sh` = 164/164 identical (provenance HEAD=4ff12d3 clean); `bash tests/silent-failures.sh` = PASS; `bash tests/bridge-selfchecks.sh` = PASS (shadow, logcheck, mklayout, cards 319 rows all ok).

Round 24 fixes verified: statusline.sh:74 now requires `_NF_TMO_US` before treating rc 137 as a deadline hit, so with no timeout(1) it falls to the `killed:` arm (:80-83) with no git-hung stamp, and the new test covers it. README.md:64 carries the once-per-render exception. Twin divergence: none found.

## 1. LOW - cosmetic: "nos deadline" in the killed log line when no timeout(1) exists
scripts/statusline.sh:82 (`${_NF_TMO:-no}s deadline`).
Scenario: no `timeout`/`gtimeout` on PATH, git SIGKILLed externally. `_NF_TMO` is unset (the no-timeout branch at :46 never sets it), so the line reads "before the nos deadline". It is logged, so not silent, but the text is garbled, and this arm is now reachable for exactly this case.
Fix: `${_NF_TMO:+${_NF_TMO}s}${_NF_TMO:-no} deadline`, or simply branch the wording: `before the ${_NF_TMO:+${_NF_TMO}s }${_NF_TMO:-no }deadline`. Simplest: `"... was killed (rc=137)${_NF_TMO:+ before the ${_NF_TMO}s deadline}; killed externally?"`. The test matches the key `killed:git:status`, not the text, so it still passes.

## Verdict
No MEDIUM or higher findings. One LOW cosmetic item above. Nothing else found: no new silent failures, bugs, twin divergence or stale docs in the reviewed range.
