# Review round 18 (independent, read-only) of 956a458

Scope: rust/src/errlog.rs (whole), proc.rs, util.rs, main.rs, state.rs, scripts/lib.sh _nf_* block. Analysis only; nothing was run. Ranked.

## 1. HIGH - TIMED_OUT poisons the git cache, including for unrelated repos
rust/src/proc.rs:48-52 (guard), :84 (flag set); rust/src/main.rs:2086-2201 (git_cache).
Scenario: repo A's `git status` hangs (10 s). Every later git call in the render returns `(empty,false)` instantly, with no log. git_cache for repo A, and for every other repo B in the same render (multi-repo listing, tmux cwd), then builds the payload `0\x1f0\x1f0\x1f<empty branch>...` and writes it to /tmp/nerdflair-git-<cksum> (main.rs:2194-2201). It is served as "clean, no branch" for GIT_CACHE_TTL, even though B is healthy. Before this commit B's own git calls could still succeed. The flag is process-wide, not per directory or filesystem.
Fix: expose `proc::git_blocked()` and skip the cache write (and fall back to the stale cache file if present) when it is set. Better, key the flag by the dir that timed out (or its st_dev) so only that dir's git calls are short-circuited.

## 2. MEDIUM - rejected stamp dir means every render logs every key; bash and Rust disagree on "safe"
errlog.rs:53 (`mode & 0o077 == 0`) vs lib.sh:56 (`-d && ! -L && -O`, no mode check).
Scenario: ~/.claude/.nerdflair-stamps exists with mode 0755/0775. Causes: a restored backup, rsync, `chmod -R`, an earlier manual mkdir under umask 022 (the bash path `mkdir -m 700` is fine, but Rust's `.mode(0o700)` is only a request on a dir that already existed), or a HOME on a filesystem that reports 0777 (WSL drvfs without metadata, SMB, sshfs). Rust then returns None for the whole process: note() logs once per process, that is once per render per key (the spam you asked about); `recent("state-write-retry")` is always false, so the 60 s back-off is lost and update_field hammers the disk every render. Bash accepts the same dir and stamps normally, so the twins keep different rate-limit state. Frequency: never on a normal ext4 HOME created by this code; always on a permission-less FS. The comment at errlog.rs:36-42 does not mention it.
Fix: if the dir is a real dir and ours but lax, `set_permissions(0o700)` and re-check before rejecting; add `[[ $(stat -c %a "$_d") == 700 ]]`-equivalent in bash only if one fork on first use is acceptable (or accept both as "ours" and drop the mode test from Rust, since ownership and not-a-symlink are what matter once the parent is private). Pick one rule for both.

## 3. MEDIUM - emit() false means retry (and a stderr line) on every render; same for recovery
errlog.rs:155-158 and :191-195, :219-221; lib.sh:101-105, 114.
Scenario: log file unwritable (read-only ~/.claude, full disk, perms). emit() returns false, no stamp is written, and mem_seen only covers one process. Each render therefore redoes trim() + create_dir_all + open for every failing key and writes a stderr line per key. If the host surfaces statusline stderr, this is exactly the spam the stamp was meant to stop. ok() has the same loop: while F is fresh and R is absent, every healthy render re-attempts the recovery line. Bash is identical.
Fix: on emit failure still write the failure stamp (a different suffix, or touch the same one with a shorter back-off), or accept a "log unwritable" stamp that suppresses all keys for 60 s.

## 4. MEDIUM - ok() can never log a recovery for rarely-exercised keys
errlog.rs:209-214; lib.sh:129.
Scenario: `state-write` fails at 10:00 and logs. ok("state-write") only runs after a successful write (state.rs:232), which happens at the next session start, say 12:30. age >= 3600, so the stamps are deleted and the recovery is never logged, although a real failure line exists. Same for any key whose healthy path runs less than hourly. Conversely, a persistent failure cannot produce a false recovery: F is refreshed each hour by note and ok() runs only on the healthy path. A same-second F/R tie is handled correctly (`<=`).
Fix: delete the stale branch; log recovery whenever F exists and R is older than F. F is only written after a successful log line, and R > F then silences it, so it remains once per failure line. Cleanup of ancient stamps can be done there after logging.

## 5. MEDIUM - mcp-probe shell block has its own, different semantics
main.rs:2483-2485.
It still `rm -f`s the failure stamp on recovery and writes no recovered-* stamp, so a flapping probe logs a failure line every time (no hourly limit; the intent stated in errlog.rs:198-200 is explicitly the opposite). With no safe dir (`_st` empty) it logs on every probe. Also uses `stat -c` (GNU only), pre-existing.
Fix: have the script call the same logic (small helper script or env), or copy the keep-F/R-stamp rule.

## 6. LOW - note() runs before kill()
proc.rs:80-85. The comment says reaping can hang, but `kill()` is a non-blocking signal; only wait() blocks. note() does file I/O (trim reads up to 64 KB, create, append) in ~/.claude, which can sit on the same stuck filesystem and delay the kill past the deadline. Fix: kill(), then note(), then the bounded reap.
Reap loop: at most 200 x (1 ms + syscall) which is about 0.2-0.3 s; a child not reaped is a zombie until process exit (harmless, the renderer exits). No blocking found; drain threads are detached.

## 7. LOW - healthy-path cost
errlog.rs:51-52: first stamp_dir() call per process does `mkdir` (EEXIST) + `lstat`, plus the one-off /proc/self/status read in uid(). It is hit every render through `ok("state-corrupt")` (state.rs:88) even when nothing ever failed. Cost is about 3-5 syscalls, no forks. Fix: lstat first, mkdir only on ENOENT (as bash does, lib.sh:55). Bash healthy path forks nothing: `_nf_ok` returns at the -e test (lib.sh:123-124) before the second `_nf_stamp`, unless bash <5 and a stamp exists (date fork).

## 8. LOW - smaller items
- Stamps from tmp_key (errlog.rs:70) and `recovered-*` are never pruned except by ok() on the same key; one empty file per distinct failing cache file (per git dir, per tmux pane, per repo) accumulates forever. Bounded by distinct names, so low.
- trim() (errlog.rs:105-129) and its bash twin lose a line appended by another process between the read and the rename. Bash also always drops the first tail line, Rust only up to the first newline. Pre-existing.
- lib.sh:103 `_NF_MEM` uses a space-delimited substring match; a key "a" is treated as seen if "a b" was logged. Keys with spaces are rare (`timeout:...` labels). Rust uses an exact HashSet.
- Slug twin: bash `${1//[^a-zA-Z0-9]/_}` is per character in a UTF-8 locale but per byte in LC_ALL=C, while Rust is per char. Differs only for non-ASCII keys (file names via tmp_key). Truncation (100) agrees for ASCII.
- lib.sh:171 `jq ... 2>&1` on the success path merges any jq stderr into the returned styles list; the old code discarded it, Rust has no equivalent. Function also now returns 0 after a failure with empty output; callers not checked.
- proc.rs:35-40: the `run` doc comment now sits above `static TIMED_OUT` and is detached from `run`.
- Dir race: the stamp dir is verified once with symlink_metadata and stamps use O_NOFOLLOW on the leaf only. A symlinked ~/.claude is followed (parent); this needs write access to HOME to exploit, so not a practical bypass. Concurrent first-run mkdir is safe.

## Checked and fine
- OnceLock caching: tests are shell scripts, one env per process (tests/silent-failures.sh:99), so no stale-env problem; there is no `cfg(test)` in rust/src. Unit tests added later would see the first value, and mem_seen is process-global.
- set -e / -u: all new `[[ ]] && ...` lists are followed by `return 0` or sit in `if`; `_NF_SDIR_DONE` is guarded with `:-`; `_nf_recent` returning 1 is only used in conditions. `-O` is a bash builtin (tests effective uid), portable to bash 3.2.
- Stamp names: F = `nerdflair-err-<uid>-<slug>`, R = same with `recovered-<key>`; identical in both twins.
- mem_seen then stamp ordering is consistent in both twins.

## Not verified
Nothing run. I did not check callers of `_nf_read_recent_styles` for the new always-0 return, whether the host shows statusline stderr, uid() real vs effective uid, or GIT_CACHE_TTL's value.
