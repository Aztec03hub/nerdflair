#!/usr/bin/env bash
# gen-payloads.sh — regenerate the difftest payload corpus.
#
# Writes /home/plafayette/nerdflair/tests/payloads/NNN.json  (stdin payload)
#                                              NNN.txt   (one-line description)
#                                              NNN.env   (per-case environment)
#
# Placeholders resolved by difftest.sh at run time (identically for both sides):
#   @@REPO:<name>@@   -> absolute path of git fixture repo <name>
#   @@HOME@@          -> the per-run sandbox HOME
#   @@NOW+<seconds>@@ -> EPOCHSECONDS + <seconds>   (rate-limit resets_at)
#   @@NOW-<seconds>@@ -> EPOCHSECONDS - <seconds>
#
# NOW offsets always end in +30s so the integer-minute countdown produced by
# _fmt_countdown is stable across the two invocations (see worklog).
set -euo pipefail
OUT="$(cd "$(dirname "$0")" && pwd)/payloads"
rm -f "$OUT"/*.json "$OUT"/*.txt "$OUT"/*.env 2>/dev/null || true
mkdir -p "$OUT"

N=0
# emit <description> <json> [env-lines...]
emit() {
  local desc="$1" json="$2"; shift 2
  N=$((N+1)); local id; printf -v id '%03d' "$N"
  printf '%s\n' "$json" | jq -S . > "$OUT/$id.json"
  printf '%s\n' "$desc" > "$OUT/$id.txt"
  : > "$OUT/$id.env"
  # Values are single-quoted: they are sourced by difftest.sh, and raw JSON
  # would otherwise lose its double quotes to word splitting.
  local l k v
  for l in "$@"; do
    k="${l%%=*}"; v="${l#*=}"
    printf "%s='%s'\n" "$k" "${v//\'/\'\\\'\'}" >> "$OUT/$id.env"
  done
}

# ── state.json bodies ────────────────────────────────────────────
st() { # st <mode> <color> [width] [chime_style] [chime_volume]
  jq -nc --arg m "$1" --arg c "$2" --arg w "${3:-auto}" --arg cs "${4:-random}" --arg cv "${5:-1}" \
    '{mode:$m,width:$w,flair:true,terminal_bell:"on",chime_sound:"Glass",
      chime_volume:$cv,chime_style:$cs,
      chime_events:"Notification,Stop",color:$c,last_session:"",
      chime_recent_styles:["Chime Alpha","Chime Beta"]}'
}
FULL_VIB=$(st full vibrant)

# ── payload builder ──────────────────────────────────────────────
# p <<'JSON' ... JSON  — just a heredoc passthrough for readability
base() {
  cat <<JSON
{
  "session_id": "sess-fixed-0001",
  "transcript_path": "/nonexistent/transcript.jsonl",
  "workspace": {"current_dir": "@@REPO:clean@@", "project_dir": "@@REPO:clean@@"},
  "model": {"display_name": "Opus 4.6", "id": "claude-opus-4-6-20250101"},
  "cost": {"total_cost_usd": 4.73, "total_duration_ms": 1860000, "total_api_duration_ms": 240000},
  "output_style": {"name": "default"},
  "effort": {"level": "high"},
  "thinking": {"enabled": true},
  "fast_mode": false,
  "context_window": {"used_percentage": 37, "total_input_tokens": 74000,
                     "total_output_tokens": 12000, "context_window_size": 200000},
  "rate_limits": {"five_hour": {"used_percentage": 23.5, "resets_at": "@@NOW+1830@@"},
                  "seven_day": {"used_percentage": 59, "resets_at": "@@NOW+200030@@"}}
}
JSON
}
# mut <jq filter> — base payload with a jq mutation applied
mut() { base | jq -c "$1"; }

E_FULL=("CASE_STATE=$FULL_VIB" "CASE_COLUMNS=120")

# ═══ 1. Degenerate / minimal inputs ═══════════════════════════════
emit "empty payload {} — every field absent"                 '{}'                          "${E_FULL[@]}"
emit "only session_id present"                               '{"session_id":"s-only"}'     "${E_FULL[@]}"
emit "empty payload, no state.json at all (all defaults)"    '{}'                          "CASE_STATE=" "CASE_COLUMNS=120"
emit "only workspace.current_dir, non-repo dir"              '{"workspace":{"current_dir":"@@REPO:notarepo@@"}}' "${E_FULL[@]}"
emit "model as a bare string, not an object"                 '{"session_id":"s","model":"claude-sonnet-4-5-20250929"}' "${E_FULL[@]}"

# ═══ 2. Layout modes × palettes (3 × 3) ═══════════════════════════
for m in full compact minimal; do
  for c in vibrant muted mono; do
    emit "layout=$m palette=$c, standard populated payload" "$(base)" \
      "CASE_STATE=$(st "$m" "$c")" "CASE_COLUMNS=120"
  done
done

# ═══ 3. Context used_percentage sweep ═════════════════════════════
for p in 0 1 5 37 79 80 81 95 100; do
  emit "context used_percentage=$p (bar fill / tier / compact-mark boundary)" \
    "$(mut ".context_window.used_percentage=$p")" "${E_FULL[@]}"
done
emit "context_window.used_percentage null"        "$(mut '.context_window.used_percentage=null')" "${E_FULL[@]}"
emit "context_window null entirely"               "$(mut '.context_window=null')"                 "${E_FULL[@]}"
emit "context_window key absent"                  "$(mut 'del(.context_window)')"                 "${E_FULL[@]}"
emit "context_window_size null, used_percentage set" "$(mut '.context_window.context_window_size=null')" "${E_FULL[@]}"
emit "context_window_size 1M (1M-context model)"  "$(mut '.context_window.context_window_size=1000000')" "${E_FULL[@]}"
emit "used_percentage as a float 37.6"            "$(mut '.context_window.used_percentage=37.6')" "${E_FULL[@]}"

# ═══ 4. Cost ══════════════════════════════════════════════════════
for c in 0 0.004 4.73 1234.56; do
  emit "cost.total_cost_usd=$c (0.004 rounds to 0.00 and hides the segment)" \
    "$(mut ".cost.total_cost_usd=$c")" "${E_FULL[@]}"
done
emit "cost.total_cost_usd null"  "$(mut '.cost.total_cost_usd=null')" "${E_FULL[@]}"
emit "cost object absent"        "$(mut 'del(.cost)')"                "${E_FULL[@]}"

# ═══ 5. Durations (burn-rate 2-minute gate, _fmt_duration units) ══
for d in 0 1000 120000 120001 1860000 7200000 360000000; do
  emit "total_duration_ms=$d (burn-rate gate at 120000; hours formatting above 60m)" \
    "$(mut ".cost.total_duration_ms=$d")" "${E_FULL[@]}"
done
emit "total_api_duration_ms=999 (below the >999 gate, time segment hidden)" \
  "$(mut '.cost.total_api_duration_ms=999')" "${E_FULL[@]}"
emit "total_api_duration_ms=1000 (time segment appears; token-speed divisor)" \
  "$(mut '.cost.total_api_duration_ms=1000')" "${E_FULL[@]}"
emit "token speed >=1000 tok/s (output_tokens high, api ms low)" \
  "$(mut '.context_window.total_output_tokens=500000 | .cost.total_api_duration_ms=100000')" "${E_FULL[@]}"

# ═══ 6. Rate limits ═══════════════════════════════════════════════
emit "rate_limits absent"        "$(mut 'del(.rate_limits)')"       "${E_FULL[@]}"
emit "rate_limits null"          "$(mut '.rate_limits=null')"       "${E_FULL[@]}"
emit "five_hour only, seven_day absent" "$(mut 'del(.rate_limits.seven_day)')" "${E_FULL[@]}"
emit "seven_day only, five_hour absent" "$(mut 'del(.rate_limits.five_hour)')" "${E_FULL[@]}"
for p in 0 23.5 59 60 84 85 99 100; do
  emit "rate_limits.five_hour.used_percentage=$p (colour thresholds at 60 and 85)" \
    "$(mut ".rate_limits.five_hour.used_percentage=$p")" "${E_FULL[@]}"
done
emit "rate-limit resets_at already in the past (countdown suppressed)" \
  "$(mut '.rate_limits.five_hour.resets_at="@@NOW-3600@@"')" "${E_FULL[@]}"
emit "rate-limit resets_at null (percentage shown, no countdown)" \
  "$(mut '.rate_limits.five_hour.resets_at=null')" "${E_FULL[@]}"
emit "rate-limit reset in 3h10m (h%02dm countdown branch)" \
  "$(mut '.rate_limits.five_hour.resets_at="@@NOW+11430@@"')" "${E_FULL[@]}"
emit "rate-limit reset in 6 days (d countdown branch)" \
  "$(mut '.rate_limits.seven_day.resets_at="@@NOW+518430@@"')" "${E_FULL[@]}"

# ═══ 7. Effort / thinking / fast / output style ═══════════════════
emit "effort absent"  "$(mut 'del(.effort)')" "${E_FULL[@]}"
for e in low medium high xhigh max; do
  emit "effort.level=$e" "$(mut ".effort.level=\"$e\"")" "${E_FULL[@]}"
done
emit "thinking.enabled=false"                 "$(mut '.thinking.enabled=false')" "${E_FULL[@]}"
emit "thinking absent"                        "$(mut 'del(.thinking)')"          "${E_FULL[@]}"
emit "fast_mode=true"                         "$(mut '.fast_mode=true')"         "${E_FULL[@]}"
emit "thinking=true and fast_mode=true together" "$(mut '.fast_mode=true|.thinking.enabled=true')" "${E_FULL[@]}"
emit "output_style Explanatory (E icon branch)"  "$(mut '.output_style.name="Explanatory"')" "${E_FULL[@]}"
emit "output_style Learning (L icon branch)"     "$(mut '.output_style.name="Learning"')"    "${E_FULL[@]}"
emit "output_style Proactive (P icon branch)"    "$(mut '.output_style.name="Proactive"')"   "${E_FULL[@]}"
emit "output_style custom name (fallback letter branch)" "$(mut '.output_style.name="zebra-mode"')" "${E_FULL[@]}"
emit "output_style absent"                       "$(mut 'del(.output_style)')"  "${E_FULL[@]}"
emit "all state suffixes at once: xhigh + thinking + style + fast" \
  "$(mut '.effort.level="xhigh"|.thinking.enabled=true|.fast_mode=true|.output_style.name="Explanatory"')" "${E_FULL[@]}"

# ═══ 8. Model naming ══════════════════════════════════════════════
emit "model Opus display_name"    "$(mut '.model={"display_name":"Opus 4.6","id":"claude-opus-4-6-20250101"}')"      "${E_FULL[@]}"
emit "model Sonnet display_name"  "$(mut '.model={"display_name":"Sonnet 4.5","id":"claude-sonnet-4-5-20250929"}')"  "${E_FULL[@]}"
emit "model Haiku display_name"   "$(mut '.model={"display_name":"Haiku 4.5","id":"claude-haiku-4-5"}')"             "${E_FULL[@]}"
emit "model Fable display_name"   "$(mut '.model={"display_name":"Fable 1.0","id":"claude-fable-1-0"}')"             "${E_FULL[@]}"
emit "model unknown string (falls through to _sanitize)" "$(mut '.model={"display_name":"Zephyr Ultra XL"}')"        "${E_FULL[@]}"
emit "model id only, no display_name, with version"      "$(mut '.model={"id":"claude-opus-4-8"}')"                  "${E_FULL[@]}"
emit "model id only, bare major version"                 "$(mut '.model={"id":"claude-sonnet-5"}')"                  "${E_FULL[@]}"
emit "model id only, no version at all"                  "$(mut '.model={"id":"claude-opus"}')"                      "${E_FULL[@]}"
emit "model display_name with [1m] 1M-context marker"    "$(mut '.model={"display_name":"Opus 4.6 [1m]","id":"claude-opus-4-6[1m]"}')" "${E_FULL[@]}"
emit "model display_name with (1M context) suffix"       "$(mut '.model={"display_name":"Opus 4.8 (1M context)","id":"claude-opus-4-8"}')" "${E_FULL[@]}"
emit "model with datestamp only (must not pick up the date)" "$(mut '.model={"id":"claude-opus-20251001"}')"          "${E_FULL[@]}"
emit "model null"                                        "$(mut '.model=null')"                                      "${E_FULL[@]}"
emit "model name containing backslashes (sanitizer path)" "$(mut '.model={"display_name":"Zed\\033[31mX"}')"         "${E_FULL[@]}"

# ═══ 9. Workspace / worktree ══════════════════════════════════════
emit "project_dir != current_dir (folder name comes from project_dir)" \
  "$(mut '.workspace={"current_dir":"@@REPO:clean@@/sub/deeper","project_dir":"@@REPO:clean@@"}')" "${E_FULL[@]}"
emit "workspace absent entirely" "$(mut 'del(.workspace)')" "${E_FULL[@]}"
emit "project_dir points at a path that does not exist" \
  "$(mut '.workspace={"current_dir":"@@HOME@@/nope","project_dir":"@@HOME@@/nope"}')" "${E_FULL[@]}"
emit "current_dir is HOME itself (home-icon branch, no folder name)" \
  "$(mut '.workspace={"current_dir":"@@HOME@@","project_dir":"@@HOME@@"}')" "${E_FULL[@]}"
emit "worktree.branch present (tree icon, branch overrides git)" \
  "$(mut '.worktree={"branch":"feature/from-payload"}')" "${E_FULL[@]}"
emit "worktree present but branch null" "$(mut '.worktree={"branch":null}')" "${E_FULL[@]}"
emit "real linked git worktree on disk (worktree icon from git)" \
  "$(mut '.workspace={"current_dir":"@@REPO:wt-linked@@","project_dir":"@@REPO:wt-linked@@"}')" "${E_FULL[@]}"

# ═══ 10. Git states ═══════════════════════════════════════════════
emit "git: not a repository at all"        "$(mut '.workspace={"current_dir":"@@REPO:notarepo@@","project_dir":"@@REPO:notarepo@@"}')" "${E_FULL[@]}"
emit "git: clean tree on main with origin"  "$(mut '.workspace={"current_dir":"@@REPO:clean@@","project_dir":"@@REPO:clean@@"}')"     "${E_FULL[@]}"
emit "git: dirty tree (modified + untracked, +/- diff counts)" \
  "$(mut '.workspace={"current_dir":"@@REPO:dirty@@","project_dir":"@@REPO:dirty@@"}')" "${E_FULL[@]}"
emit "git: detached HEAD (short sha instead of branch)" \
  "$(mut '.workspace={"current_dir":"@@REPO:detached@@","project_dir":"@@REPO:detached@@"}')" "${E_FULL[@]}"
emit "git: NO origin remote — the cached-field-shift regression case" \
  "$(mut '.workspace={"current_dir":"@@REPO:noremote@@","project_dir":"@@REPO:noremote@@"}')" "${E_FULL[@]}"
emit "git: no origin remote AND dirty — shift case with fields after remote" \
  "$(mut '.workspace={"current_dir":"@@REPO:noremote-dirty@@","project_dir":"@@REPO:noremote-dirty@@"}')" "${E_FULL[@]}"
emit "git: 2 commits ahead of upstream"     "$(mut '.workspace={"current_dir":"@@REPO:ahead@@","project_dir":"@@REPO:ahead@@"}')"     "${E_FULL[@]}"
emit "git: 3 commits behind upstream"       "$(mut '.workspace={"current_dir":"@@REPO:behind@@","project_dir":"@@REPO:behind@@"}')"   "${E_FULL[@]}"
emit "git: diverged, both ahead and behind" "$(mut '.workspace={"current_dir":"@@REPO:diverged@@","project_dir":"@@REPO:diverged@@"}')" "${E_FULL[@]}"
emit "git: very long branch name that must truncate" \
  "$(mut '.workspace={"current_dir":"@@REPO:longbranch@@","project_dir":"@@REPO:longbranch@@"}')" "${E_FULL[@]}"
emit "git: wrapper dir containing exactly one repo (adopted repo: prefix)" \
  "$(mut '.workspace={"current_dir":"@@REPO:wrap-one@@","project_dir":"@@REPO:wrap-one@@"}')" "${E_FULL[@]}"
emit "git: wrapper dir with 3 repos, all off main (multi-branch list)" \
  "$(mut '.workspace={"current_dir":"@@REPO:wrap-many@@","project_dir":"@@REPO:wrap-many@@"}')" "${E_FULL[@]}"
emit "git: wrapper dir with 3 repos all on main (N repos collapse)" \
  "$(mut '.workspace={"current_dir":"@@REPO:wrap-main@@","project_dir":"@@REPO:wrap-main@@"}')" "${E_FULL[@]}"
emit "git: wrapper with 3 off-main repos at COLUMNS=60 (multi list collapses to N branches)" \
  "$(mut '.workspace={"current_dir":"@@REPO:wrap-many@@","project_dir":"@@REPO:wrap-many@@"}')" \
  "CASE_STATE=$FULL_VIB" "CASE_COLUMNS=60"
emit "git: unicode + spaces in directory and branch names" \
  "$(mut '.workspace={"current_dir":"@@REPO:unicode@@","project_dir":"@@REPO:unicode@@"}')" "${E_FULL[@]}"
emit "git: heavily dirty repo, 4-digit file count formatting" \
  "$(mut '.workspace={"current_dir":"@@REPO:bigdirty@@","project_dir":"@@REPO:bigdirty@@"}')" "${E_FULL[@]}"

# ═══ 11. Width / COLUMNS ══════════════════════════════════════════
for w in 60 80 120 150 200; do
  emit "COLUMNS=$w (width clamps to [50,150])" "$(base)" "CASE_STATE=$FULL_VIB" "CASE_COLUMNS=$w"
done
emit "COLUMNS unset (tput cols fallback)"    "$(base)" "CASE_STATE=$FULL_VIB" "CASE_COLUMNS="
emit "COLUMNS=40 (below the 50 floor)"       "$(base)" "CASE_STATE=$FULL_VIB" "CASE_COLUMNS=40"
emit "state width=100 pinned, COLUMNS=60 ignored" "$(base)" "CASE_STATE=$(st full vibrant 100)" "CASE_COLUMNS=60"
emit "state width=200 pinned (clamps to 150)"     "$(base)" "CASE_STATE=$(st full vibrant 200)" "CASE_COLUMNS=80"
emit "state width=10 pinned (clamps to 50)"       "$(base)" "CASE_STATE=$(st full vibrant 10)"  "CASE_COLUMNS=80"
emit "long branch at COLUMNS=60 (branch/model budget contention)" \
  "$(mut '.workspace={"current_dir":"@@REPO:longbranch@@","project_dir":"@@REPO:longbranch@@"} | .effort.level="xhigh"')" \
  "CASE_STATE=$FULL_VIB" "CASE_COLUMNS=60"
emit "long branch at COLUMNS=80 with effort (MIN_BRANCH_FIT yield path)" \
  "$(mut '.workspace={"current_dir":"@@REPO:longbranch@@","project_dir":"@@REPO:longbranch@@"} | .effort.level="medium"')" \
  "CASE_STATE=$FULL_VIB" "CASE_COLUMNS=80"
emit "minimal mode at COLUMNS=60 with dirty repo (pill + dirty reserve)" \
  "$(mut '.workspace={"current_dir":"@@REPO:dirty@@","project_dir":"@@REPO:dirty@@"}')" \
  "CASE_STATE=$(st minimal vibrant)" "CASE_COLUMNS=60"
emit "compact mode at COLUMNS=60 (in-bar right label drops time then cost)" \
  "$(base)" "CASE_STATE=$(st compact vibrant)" "CASE_COLUMNS=60"

# ═══ 12. MCP configuration (~/.claude.json + .mcp.json) ═══════════
emit "MCP: no servers configured anywhere"           "$(base)" "${E_FULL[@]}" "CASE_MCP=none"
emit "MCP: one global server"                        "$(base)" "${E_FULL[@]}" "CASE_MCP=one"
emit "MCP: six global servers (expanded list truncation ladder)" "$(base)" "${E_FULL[@]}" "CASE_MCP=many"
emit "MCP: six servers at COLUMNS=60 (falls back to N MCP count)" \
  "$(base)" "CASE_STATE=$FULL_VIB" "CASE_COLUMNS=60" "CASE_MCP=many"
emit "MCP: one server disabled, one project-disabled" "$(base)" "${E_FULL[@]}" "CASE_MCP=disabled"
emit "MCP: project-scoped servers under .projects[dir]" "$(base)" "${E_FULL[@]}" "CASE_MCP=projscoped"

# ═══ 13. Seeded async caches (ccusage / mcp health / tmux) ════════
emit "ccusage cache seeded: burn rate + billing block segments" \
  "$(base)" "${E_FULL[@]}" 'CASE_SEED_CCUSAGE=$12.40 block (2h 15m left) $8.75/hr'
emit "ccusage cache seeded, burn >= \$20/hr (mustard threshold)" \
  "$(base)" "${E_FULL[@]}" 'CASE_SEED_CCUSAGE=$44.00 block (1h 02m left) $31.10/hr'
emit "ccusage cache seeded, burn >= \$50/hr (alert threshold)" \
  "$(base)" "${E_FULL[@]}" 'CASE_SEED_CCUSAGE=$99.99 block (0h 05m left) $77.50/hr'
emit "ccusage cache seeded but unparseable (segments stay hidden)" \
  "$(base)" "${E_FULL[@]}" 'CASE_SEED_CCUSAGE=garbage line with no numbers'
emit "mcp health cache seeded: all connected" \
  "$(base)" "${E_FULL[@]}" "CASE_MCP=many" "CASE_SEED_MCPHEALTH=6:0:0"
emit "mcp health cache seeded: one failed (alert colour + cross)" \
  "$(base)" "${E_FULL[@]}" "CASE_MCP=many" "CASE_SEED_MCPHEALTH=4:1:0"
emit "mcp health cache seeded: one needs auth (mustard colour + bang)" \
  "$(base)" "${E_FULL[@]}" "CASE_MCP=many" "CASE_SEED_MCPHEALTH=4:0:1"
emit "mcp health cache seeded: failed and auth-needed together" \
  "$(base)" "${E_FULL[@]}" "CASE_MCP=many" "CASE_SEED_MCPHEALTH=3:2:1"
emit "tmux: TMUX_PANE set, session-name cache seeded" \
  "$(base)" "${E_FULL[@]}" "CASE_TMUX=%17" "CASE_SEED_TMUX=aletheia-main"
emit "tmux: TMUX_PANE unset (segment absent)" "$(base)" "${E_FULL[@]}" "CASE_TMUX="
emit "repo cost: usage TSV seeded with prior sessions for this repo" \
  "$(base)" "${E_FULL[@]}" "CASE_SEED_REPOCOST=1"
emit "everything at once: ccusage + mcp health + tmux + rate limits + repo cost" \
  "$(base)" "${E_FULL[@]}" "CASE_MCP=many" "CASE_SEED_MCPHEALTH=5:1:0" \
  'CASE_SEED_CCUSAGE=$12.40 block (2h 15m left) $8.75/hr' \
  "CASE_TMUX=%3" "CASE_SEED_TMUX=orchestrator" "CASE_SEED_REPOCOST=1"

# ═══ 14. Chime / volume state ═════════════════════════════════════
emit "chime: style=random and cost 0.00 (chime label shown)" \
  "$(mut '.cost.total_cost_usd=0')" "CASE_STATE=$(st full vibrant auto random 1)" "CASE_COLUMNS=120"
emit "chime: style=random, cost 0.00, volume 0.4 (percentage shown)" \
  "$(mut '.cost.total_cost_usd=0')" "CASE_STATE=$(st full vibrant auto random 0.4)" "CASE_COLUMNS=120"
emit "chime: volume 0 (bell-off icon in compact bar, no chime segment)" \
  "$(mut '.cost.total_cost_usd=0')" "CASE_STATE=$(st compact vibrant auto random 0)" "CASE_COLUMNS=120"
emit "chime: explicit style name, not random (label suppressed)" \
  "$(mut '.cost.total_cost_usd=0')" "CASE_STATE=$(st full vibrant auto 'Chime Gamma' 1)" "CASE_COLUMNS=120"
emit "chime: per-session chime file present for this session_id" \
  "$(mut '.cost.total_cost_usd=0')" "CASE_STATE=$(st full vibrant auto random 1)" "CASE_COLUMNS=120" "CASE_SESSION_CHIME=Chime Delta"
emit "legacy state: color=default migrates to vibrant" \
  "$(base)" 'CASE_STATE={"mode":"full","color":"default"}' "CASE_COLUMNS=120"
emit "legacy state: bell=visual migrates to terminal_bell/chime_volume" \
  "$(mut '.cost.total_cost_usd=0')" 'CASE_STATE={"mode":"full","bell":"visual","audio_style":"Chime Zeta"}' "CASE_COLUMNS=120"
emit "state: unknown mode string (falls through as non-minimal, non-compact)" \
  "$(base)" 'CASE_STATE={"mode":"weird","color":"vibrant","width":"auto"}' "CASE_COLUMNS=120"
emit "state file is malformed JSON (jq fails, defaults apply)" \
  "$(base)" 'CASE_STATE={not json at all' "CASE_COLUMNS=120"

# ═══ 15. Compaction ETA + combined stress ═════════════════════════
emit "compaction ETA visible (5% <= used < 80%, >2min elapsed)" \
  "$(mut '.context_window.used_percentage=20 | .cost.total_duration_ms=600000')" "${E_FULL[@]}"
emit "compaction ETA under 15m (mustard)" \
  "$(mut '.context_window.used_percentage=70 | .cost.total_duration_ms=1800000')" "${E_FULL[@]}"
emit "compaction ETA under 5m (alert)" \
  "$(mut '.context_window.used_percentage=78 | .cost.total_duration_ms=1800000')" "${E_FULL[@]}"
emit "compaction ETA suppressed: used >= 80" \
  "$(mut '.context_window.used_percentage=85 | .cost.total_duration_ms=1800000')" "${E_FULL[@]}"
emit "compaction ETA suppressed: elapsed <= 2min" \
  "$(mut '.context_window.used_percentage=20 | .cost.total_duration_ms=60000')" "${E_FULL[@]}"
emit "stress: minimal mode, mono, 100% context, dirty repo, COLUMNS=60" \
  "$(mut '.context_window.used_percentage=100 | .workspace={"current_dir":"@@REPO:dirty@@","project_dir":"@@REPO:dirty@@"}')" \
  "CASE_STATE=$(st minimal mono)" "CASE_COLUMNS=60"
emit "stress: compact mode, muted, 0% context, long branch, COLUMNS=150" \
  "$(mut '.context_window.used_percentage=0 | .workspace={"current_dir":"@@REPO:longbranch@@","project_dir":"@@REPO:longbranch@@"}')" \
  "CASE_STATE=$(st compact muted)" "CASE_COLUMNS=150"
emit "stress: full mode, everything populated, COLUMNS=150" \
  "$(mut '.effort.level="max"|.fast_mode=true|.output_style.name="Explanatory"')" \
  "CASE_STATE=$FULL_VIB" "CASE_COLUMNS=150" "CASE_MCP=many" "CASE_SEED_MCPHEALTH=5:1:0" \
  'CASE_SEED_CCUSAGE=$12.40 block (2h 15m left) $8.75/hr' "CASE_TMUX=%9" "CASE_SEED_TMUX=nf"

echo "generated $N payloads in $OUT"
