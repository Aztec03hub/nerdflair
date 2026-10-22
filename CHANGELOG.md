# Changelog

## Unreleased - fork work, 2026-08-19 to 2026-10-22

Phil LaFayette's fork. How it all fits together is in [docs/architecture.md](docs/architecture.md).

### Added
- A Rust renderer, `nerdflair-statusline`, about 2 ms a render against 54 ms for bash. The bash script stays as its twin and `tests/difftest.sh` holds them byte-identical over 228 payloads
- Burn rate, billing block and 5h / 7d plan limits, from our own spend ledger (`~/.claude/nerdflair-usage.tsv`) instead of ccusage
- Cost per repo across sessions, MCP health, git ahead/behind, the tmux session name and a compaction ETA
- Plan limits that stay up between payloads, from a last-known `limits-last` record, dim when derived
- A Remote Control readout on the main line (on, off, unknown), kept fresh by the band plugin's `--rc-sync`
- Hover cards: point at a readout and a card says what it is and where it comes from, and the readout lights up. It runs through a pty relay (`band/bridge/nfpty.py`) with a private tmux shadow screen, with nothing patched inside Claude Code
- A launcher shim that wraps `claude` only when hover can work, and `band/hover/install.sh` to put it on `PATH` and take it off again
- `nf-tmux-heal` and `nf-tmux-watch`, which bring back a deleted tmux socket without starting or killing a server
- `--json`, the same segments with stable ids, for the band plugin
- Dim placeholders (`--/s`, `~--`, `$--`, `--`) for readouts that have no data yet, so the line doesn't shift when they arrive
- A test suite for every rule above, run against a temp HOME and cache dir

### Changed
- Every renderer cache moved out of `/tmp` into one private 0700 dir (`~/.cache/nerdflair` by default), checked on every use
- The band row is off by default; `BAND_ROW_ENABLED` or `~/.claude/nerdflair/band-debug` turns it back on for debugging
- The published band plugin's version is a content stamp, so `claude plugin update` actually picks up a change
- The MCP health cache is per project, so one project's count no longer shows in another
- Ledger and transcript reads are bounded tails, and compaction is single-flight and can't drop a row
- Row 3 caps the gap between the MCP readout and the rest at 3 columns
- ccusage is gone from both renderers

### Fixed
- The status line going permanently blank on Linux with GNU coreutils
- Chimes never playing on Linux for Stop, Notification and PermissionRequest, and chimes stacking when several sessions finish at once
- The status line being able to melt the machine (22 runaway ccusage processes on 2026-10-08)
- Repo-cost corruption from a non-atomic append, a stale lock and unvalidated rows
- The compaction ETA vanishing on long sessions, and token throughput and billing block arithmetic
- The RC chip reading the wrong signal and saying off while RC was on
- The branch vanishing when git hangs or is missing; it's read from `.git/HEAD` instead
- A state file written relative to the working directory when HOME was empty
- Silent failures: every fallback in the renderers, bridge, plugin and launcher now logs its reason once

## 1.1.0 — 2026-03-19

### Added
- Linux audio support via `paplay` (PulseAudio/PipeWire) — chimes now work on Linux
- Token speed display (`t/s`) on row 3 in full mode
- Clickable OSC 8 hyperlinks on folder name (links to GitHub repo) and branch (links to branch)
- Git data caching (3-second TTL) to reduce git subprocess overhead per render
- Auto terminal width detection (`$COLUMNS`) for `width: auto` instead of hardcoded 80
- Worktree branch display when running with `--worktree`
- `PreCompact` and `UserPromptSubmit` hook events registered in hooks.json
- `PreCompact` added to default chime events
- `install` command to reset all settings to defaults
- This changelog

### Changed
- Audio playback abstracted to shared `_nf_play_audio` helper in lib.sh

## 1.0.0 — 2026-03-09

Initial release.

- 3 layout modes: full, compact, minimal
- Context bar with color gradient, compaction threshold marker, and randomizable textures
- 3 color palettes: vibrant, muted, mono
- 20 audio chime styles with per-event configuration (macOS)
- 150 custom spinner verbs
- Terminal bell on Notification, PermissionRequest, Stop
- Git branch, dirty file count, lines added/removed
- Model name with output style indicator
- MCP server display with smart truncation
- Session cost and API duration
- Per-session random chime style and bar texture
- `/nerdflair` skill for configuration via natural language
