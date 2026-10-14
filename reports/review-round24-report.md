# Review round 24 (read-only) of 2b2aa83

Scope: `git diff 18f86a3..2b2aa83`, then the wider silent-failure branch. Rounds 18 to 23 reports and worklog-round19-fixes read first; fixed items and the /tmp git-cache symlink item skipped. No source edited.

Ran in the repo: `bash tests/difftest.sh` = 164/164 identical (one payload, 162, UNSTABLE: differed once, matched on retry; the worklog already records this flake on 145). `bash tests/silent-failures.sh` = PASS. Not run: band tests, bridge selfchecks.

Round 23 changes checked and correct: errlog.rs:85 and lib.sh:65-70 now agree (symlink marker = not recent, logs per render, write skipped for a link); statusline.sh:51-55 and :68 strip both radix characters and treat non-numeric as "ran to deadline"; register.tsx:555-558 guarded like :540-543 and `now` is in scope. Twin divergence: none found.

## 1. LOW - bash logs a false "timeout" line when rc 137 arrives with no deadline
scripts/statusline.sh:51-53 (`_nf_ran_to_deadline`), :74-77 and :46.
Scenario: no `timeout`/`gtimeout` on PATH (the `no-timeout` branch, :46), so `_NF_TMO_US` is unset. git is SIGKILLed externally (OOM, user `kill -9`), rc 137. `_nf_ran_to_deadline` returns 0 at :52 because `_NF_TMO_US` is empty, so :74 takes the timeout arm: `_nf_touch git-hung` arms a 60 s back-off and the log says `timeout:git:status ... still running after s, killed` (empty `${_NF_TMO}`). There is no deadline, so "timeout" and the back-off are wrong; the :82 arm already anticipates this case (`${_NF_TMO:-no}`) but is unreachable for it. Same wrong arm on bash < 5 (no EPOCHREALTIME), which is documented. Not a silent failure (a line is written), but a lying one.
Fix: in :74 require a deadline: `(( _rc == 137 )) && [[ -n "$_NF_TMO_US" ]] && _nf_ran_to_deadline "$_t0"`; with no deadline rc 137 falls to the `killed:` arm. Add a bash case with `PATH` lacking timeout and a SIGKILLing git stub expecting `killed:git:status` and no `git-hung` stamp.

## 2. LOW - README says every cause is logged at most once an hour
README.md:64 ("The renderer logs a given cause at most once an hour").
Since round 23 the `stamp-dir` line with a symlink marker is logged once per render (errlog.rs:81-85, lib.sh:65), and the per-process memo only limits repeats within a render. Comment text in code is accurate; the README sentence is now untrue for that case. The README.md:62 row also lists no key for stamp, clock, chime, usage or timeout problems; "a bad payload, a panic" is a sample, not a table of keys, so that is acceptable.
Fix: append to :64 "(except when the stamp directory and its marker are both unusable: then once per render, since nothing can rate limit)".

## 3. INFO - test gaps already accepted
register.tsx clock-reject paths (:540, :555) still have no test (mock clock cannot reject). Not a defect.

## Verdict
No MEDIUM or higher findings. Two LOW items above (1 is a mislabelled log line plus a wrong 60 s back-off in a no-timeout environment; 2 is a stale doc sentence). Nothing else found.
