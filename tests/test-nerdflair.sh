#!/usr/bin/env bash
# Tests for nerdflair plugin scripts.
#
# Usage:
#   ./plugins/nerdflair/tests/test-nerdflair.sh
#   TRACE=1 ./plugins/nerdflair/tests/test-nerdflair.sh

set -euo pipefail
if [[ "${TRACE-0}" == "1" ]]; then
  set -o xtrace
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RENDERER="$PLUGIN_ROOT/scripts/statusline.sh"
CONFIGURATOR="$PLUGIN_ROOT/scripts/nerdflair.sh"
BELL="$PLUGIN_ROOT/hooks/bell.sh"

# ── Test harness ────────────────────────────────────────────────
_pass=0
_fail=0
_errors=()

_setup() {
  TMPDIR_ROOT=$(mktemp -d)
  FAKE_HOME="$TMPDIR_ROOT/home"
  mkdir -p "$FAKE_HOME/.claude/nerdflair"

  FAKE_CWD="$TMPDIR_ROOT/workspace/my-project"
  mkdir -p "$FAKE_CWD"

  # Minimal git repo so renderer can detect branch
  (
    cd "$FAKE_CWD"
    git init -q
    git checkout -q -b main
    echo "hello" > file.txt
    git add -A
    git commit -q -m "init"
    git checkout -q -b feature/test-branch
    echo "change" >> file.txt
  ) >/dev/null 2>&1
}

_teardown() {
  rm -rf "$TMPDIR_ROOT"
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: $label — expected to contain '$needle'")
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: $label — expected NOT to contain '$needle'")
  fi
}

assert_equals() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: $label — expected '$expected', got '$actual'")
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: $label — expected exit code $expected, got $actual")
  fi
}

# Strip ANSI escape codes for text assertions
_strip_ansi() {
  sed $'s/\033\\[[0-9;]*m//g'
}

# Build a JSON payload for the renderer
_make_input() {
  local pct="${1:-42}" cost="${2:-5.00}" model="${3:-us.anthropic.claude-opus-4-6-v1}"
  local tokens=$(( 200000 * pct / 100 ))
  cat <<EOF
{
  "workspace": {"current_dir": "$FAKE_CWD", "project_dir": "$FAKE_CWD"},
  "model": {"id": "$model"},
  "cost": {"total_cost_usd": $cost, "total_duration_ms": 120000, "total_api_duration_ms": 120000},
  "output_style": {"name": "default"},
  "session_id": "test-session-001",
  "context_window": {
    "used_percentage": $pct,
    "total_input_tokens": $tokens,
    "total_output_tokens": 0,
    "context_window_size": 200000
  }
}
EOF
}

# Run the renderer with a given state and input
_render() {
  local state="$1" input="$2"
  echo "$state" > "$FAKE_HOME/.claude/nerdflair/state.json"
  printf '%s' "$input" | HOME="$FAKE_HOME" bash "$RENDERER"
}

# Run the configurator
_configure() {
  HOME="$FAKE_HOME" bash "$CONFIGURATOR" "$@"
}

# Read a field from the state file
_state_field() {
  local field="$1"
  grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$FAKE_HOME/.claude/nerdflair/state.json" \
    | head -1 | sed 's/.*"\([^"]*\)"/\1/'
}

_state_field_raw() {
  local field="$1"
  grep -o "\"$field\"[[:space:]]*:[[:space:]]*[a-z]*" "$FAKE_HOME/.claude/nerdflair/state.json" \
    | head -1 | sed 's/.*:[[:space:]]*//'
}


# ════════════════════════════════════════════════════════════════
# RENDERER TESTS
# ════════════════════════════════════════════════════════════════

test_renderer_full_mode_has_three_rows() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00)")
  # Full mode: row1 (folder/branch), row2 (bar on its own line), row3 (logos/cost)
  local line_count
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  # The bar prints a leading \n, so full mode = row1 + \n + bar + \n + row3 = 3 content lines
  if (( line_count >= 3 )); then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: full mode should have >= 3 lines, got $line_count")
  fi
  _teardown
}

test_renderer_compact_mode_has_two_rows() {
  _setup
  local state='{"mode": "compact", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00)")
  local line_count
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  # Compact: row1 + \n + bar = 2 content lines
  if (( line_count >= 2 && line_count < 4 )); then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: compact mode should have 2-3 lines, got $line_count")
  fi
  _teardown
}

test_renderer_minimal_mode_has_one_row() {
  _setup
  local state='{"mode": "minimal", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00)")
  local line_count
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  assert_equals "minimal mode line count" "$line_count" "1"
  _teardown
}

test_renderer_shows_folder_name() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input)" | _strip_ansi)
  assert_contains "folder name in output" "$output" "my-project"
  _teardown
}

test_renderer_shows_branch() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input)" | _strip_ansi)
  assert_contains "branch in output" "$output" "feature/test-branch"
  _teardown
}

test_renderer_shows_model_name() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00 us.anthropic.claude-opus-4-6-v1)" | _strip_ansi)
  assert_contains "model name opus" "$output" "Opus 4.6"
  _teardown
}

test_renderer_shows_sonnet_model() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00 us.anthropic.claude-sonnet-4-6-v1)" | _strip_ansi)
  assert_contains "model name sonnet" "$output" "Sonnet 4.6"
  _teardown
}

test_renderer_shows_context_percentage() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 65)" | _strip_ansi)
  assert_contains "context percentage" "$output" "65%"
  _teardown
}

test_renderer_shows_cost() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 12.50)" | _strip_ansi)
  assert_contains "cost in output" "$output" "12.50"
  _teardown
}

test_renderer_zero_cost_not_shown() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 10 0)" | _strip_ansi)
  # Row 3 should not show $0.00
  assert_not_contains "zero cost hidden" "$output" '$0.00'
  _teardown
}

test_renderer_mcp_servers_shown() {
  _setup
  cat > "$FAKE_HOME/.claude.json" << 'EOF'
{"mcpServers":{"Slack":{},"Glean":{}}}
EOF
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input)" | _strip_ansi)
  assert_contains "MCP servers in output" "$output" "Glean"
  _teardown
}

test_renderer_no_state_file_uses_defaults() {
  _setup
  rm -f "$FAKE_HOME/.claude/nerdflair/state.json"
  local output
  output=$(printf '%s' "$(_make_input)" | HOME="$FAKE_HOME" bash "$RENDERER")
  local stripped
  stripped=$(echo "$output" | _strip_ansi)
  # Default is full mode — should have folder, branch, and percentage
  assert_contains "defaults: folder" "$stripped" "my-project"
  assert_contains "defaults: percentage" "$stripped" "42%"
  _teardown
}

test_renderer_width_respected() {
  _setup
  local state_narrow='{"mode": "full", "width": "50", "flair": false, "terminal_bell": "off", "chime_volume": "0", "chime_style": "random", "chime_events": "", "color": "vibrant"}'
  local state_wide='{"mode": "full", "width": "120", "flair": false, "terminal_bell": "off", "chime_volume": "0", "chime_style": "random", "chime_events": "", "color": "vibrant"}'
  local out_narrow out_wide len_narrow len_wide
  out_narrow=$(_render "$state_narrow" "$(_make_input 50 0)" | _strip_ansi | head -1)
  out_wide=$(_render "$state_wide" "$(_make_input 50 0)" | _strip_ansi | head -1)
  len_narrow=${#out_narrow}
  len_wide=${#out_wide}
  if (( len_wide > len_narrow )); then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: wide ($len_wide) should be wider than narrow ($len_narrow)")
  fi
  _teardown
}


# ════════════════════════════════════════════════════════════════
# CONFIGURATOR TESTS
# ════════════════════════════════════════════════════════════════

test_config_default_state_created() {
  _setup
  _configure layout full >/dev/null 2>&1
  local mode
  mode=$(_state_field "mode")
  assert_equals "default mode is full" "$mode" "full"
  _teardown
}

test_config_layout_cycle() {
  _setup
  # Start at full, cycle to compact
  _configure layout full >/dev/null 2>&1
  _configure layout >/dev/null 2>&1
  assert_equals "full -> compact" "$(_state_field "mode")" "compact"
  # compact -> minimal
  _configure layout >/dev/null 2>&1
  assert_equals "compact -> minimal" "$(_state_field "mode")" "minimal"
  # minimal -> full
  _configure layout >/dev/null 2>&1
  assert_equals "minimal -> full" "$(_state_field "mode")" "full"
  _teardown
}

test_config_layout_direct_set() {
  _setup
  _configure layout compact >/dev/null 2>&1
  assert_equals "set compact" "$(_state_field "mode")" "compact"
  _configure layout minimal >/dev/null 2>&1
  assert_equals "set minimal" "$(_state_field "mode")" "minimal"
  _teardown
}

test_config_invalid_layout_fails() {
  _setup
  _configure layout full >/dev/null 2>&1
  local rc=0
  _configure layout bogus >/dev/null 2>&1 || rc=$?
  assert_exit_code "invalid layout exits nonzero" "1" "$rc"
  _teardown
}

test_config_width_set() {
  _setup
  _configure layout full >/dev/null 2>&1
  _configure width 60 >/dev/null 2>&1
  assert_equals "width 60" "$(_state_field "width")" "60"
  _configure width auto >/dev/null 2>&1
  assert_equals "width auto" "$(_state_field "width")" "auto"
  _teardown
}

test_config_width_validation() {
  _setup
  _configure layout full >/dev/null 2>&1
  local rc=0
  _configure width 999 >/dev/null 2>&1 || rc=$?
  assert_exit_code "width > 150 rejected" "1" "$rc"
  rc=0
  _configure width 10 >/dev/null 2>&1 || rc=$?
  assert_exit_code "width < 50 rejected" "1" "$rc"
  _teardown
}

test_config_flair_always_on() {
  _setup
  _configure layout full >/dev/null 2>&1
  assert_equals "flair default true" "$(_state_field_raw "flair")" "true"
  # flair command is legacy — should exit 0 without changing state
  local output
  output=$(_configure flair 2>&1)
  assert_contains "flair prints always-on message" "$output" "always on"
  _teardown
}

test_config_terminal_bell_toggle() {
  _setup
  _configure layout full >/dev/null 2>&1
  assert_equals "bell default on" "$(_state_field "terminal_bell")" "on"
  _configure terminal-bell >/dev/null 2>&1
  assert_equals "bell toggled off" "$(_state_field "terminal_bell")" "off"
  _configure terminal-bell >/dev/null 2>&1
  assert_equals "bell toggled on" "$(_state_field "terminal_bell")" "on"
  _teardown
}

test_config_color_cycle() {
  _setup
  _configure color-palette vibrant >/dev/null 2>&1
  assert_equals "color vibrant" "$(_state_field "color")" "vibrant"
  _configure color-palette >/dev/null 2>&1
  assert_equals "vibrant -> muted" "$(_state_field "color")" "muted"
  _configure color-palette >/dev/null 2>&1
  assert_equals "muted -> mono" "$(_state_field "color")" "mono"
  _configure color-palette >/dev/null 2>&1
  assert_equals "mono -> vibrant" "$(_state_field "color")" "vibrant"
  _teardown
}

test_config_color_direct_set() {
  _setup
  _configure color-palette mono >/dev/null 2>&1
  assert_equals "set mono" "$(_state_field "color")" "mono"
  _teardown
}

test_config_invalid_color_fails() {
  _setup
  _configure layout full >/dev/null 2>&1
  local rc=0
  _configure color-palette neon >/dev/null 2>&1 || rc=$?
  assert_exit_code "invalid color exits nonzero" "1" "$rc"
  _teardown
}

test_config_chime_volume() {
  _setup
  _configure layout full >/dev/null 2>&1
  _configure chime-volume 50 >/dev/null 2>&1
  assert_equals "volume 50%" "$(_state_field "chime_volume")" "0.50"
  _configure chime-volume 0 >/dev/null 2>&1
  assert_equals "volume muted" "$(_state_field "chime_volume")" "0.00"
  _teardown
}

test_config_chime_volume_validation() {
  _setup
  _configure layout full >/dev/null 2>&1
  local rc=0
  _configure chime-volume 200 >/dev/null 2>&1 || rc=$?
  assert_exit_code "volume > 100 rejected" "1" "$rc"
  _teardown
}

test_config_chime_events_toggle() {
  _setup
  _configure layout full >/dev/null 2>&1
  # Default includes all events
  local events
  events=$(_state_field "chime_events")
  assert_contains "default has Stop" "$events" "Stop"
  assert_contains "default has SessionEnd" "$events" "SessionEnd"
  # Toggle Stop off
  _configure chime-events Stop >/dev/null 2>&1
  events=$(_state_field "chime_events")
  if echo ",$events," | grep -q ",Stop,"; then
    (( _fail++ ))
    _errors+=("FAIL: Stop still present as standalone event: $events")
  else
    (( _pass++ ))
  fi
  # Toggle it back on
  _configure chime-events Stop >/dev/null 2>&1
  events=$(_state_field "chime_events")
  assert_contains "Stop re-added" "$events" "Stop"
  _teardown
}

test_config_chime_events_toggle_does_not_corrupt_substring_events() {
  _setup
  _configure layout full >/dev/null 2>&1
  # Enable UserPromptSubmit (not in default) to test substring safety
  _configure chime-events UserPromptSubmit >/dev/null 2>&1
  local events
  events=$(_state_field "chime_events")
  assert_contains "has UserPromptSubmit" "$events" "UserPromptSubmit"
  assert_contains "has Stop" "$events" "Stop"
  # Toggle Stop off — must not corrupt UserPromptSubmit
  _configure chime-events Stop >/dev/null 2>&1
  events=$(_state_field "chime_events")
  # Use comma-sandwich to verify bare "Stop" is gone (can't use plain assert_not_contains
  # because "UserPromptSubmit" contains the substring "Stop")
  if echo ",$events," | grep -q ",Stop,"; then
    (( _fail++ ))
    _errors+=("FAIL: Stop still present as standalone event: $events")
  else
    (( _pass++ ))
  fi
  assert_contains "UserPromptSubmit intact" "$events" "UserPromptSubmit"
  _teardown
}

test_config_invalid_chime_event_fails() {
  _setup
  _configure layout full >/dev/null 2>&1
  local rc=0
  _configure chime-events BogusEvent >/dev/null 2>&1 || rc=$?
  assert_exit_code "invalid event exits nonzero" "1" "$rc"
  _teardown
}

test_config_info_mode() {
  _setup
  _configure layout full >/dev/null 2>&1
  local output
  output=$(_configure info 2>&1 | _strip_ansi)
  assert_contains "info shows mode" "$output" "full"
  assert_contains "info shows width" "$output" "width"
  _teardown
}

test_config_no_args_cycles_layout() {
  _setup
  _configure layout full >/dev/null 2>&1
  _configure >/dev/null 2>&1
  assert_equals "no args cycles to compact" "$(_state_field "mode")" "compact"
  _teardown
}

test_config_invalid_command_fails() {
  _setup
  local rc=0
  _configure nonsense >/dev/null 2>&1 || rc=$?
  assert_exit_code "unknown command exits nonzero" "1" "$rc"
  _teardown
}

test_config_legacy_default_color_migrated() {
  _setup
  # Write state with old "default" color value
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_sound": "Glass", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "default"}
EOF
  # Any state-writing action should migrate "default" -> "vibrant"
  _configure layout >/dev/null 2>&1
  assert_equals "default migrated to vibrant" "$(_state_field "color")" "vibrant"
  _teardown
}


# ════════════════════════════════════════════════════════════════
# BELL HOOK TESTS
# ════════════════════════════════════════════════════════════════

test_bell_exits_early_when_all_disabled() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "off", "chime_sound": "Glass", "chime_volume": "0", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}
EOF
  local rc=0
  echo '{}' | HOME="$FAKE_HOME" bash "$BELL" Stop || rc=$?
  assert_exit_code "bell exits 0 when all disabled" "0" "$rc"
  _teardown
}

test_bell_reads_state_correctly() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "off", "chime_sound": "Glass", "chime_volume": "0", "chime_style": "BalladPiano", "chime_events": "Stop", "color": "vibrant"}
EOF
  # With both off, it should exit cleanly without errors
  local output rc=0
  output=$(echo '{}' | HOME="$FAKE_HOME" bash "$BELL" Stop 2>&1) || rc=$?
  assert_exit_code "bell runs without error" "0" "$rc"
  # Should not produce any output when disabled
  assert_equals "bell silent when disabled" "$output" ""
  _teardown
}

test_bell_picks_random_style_on_session_start() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "off", "chime_sound": "Glass", "chime_volume": "0.50", "chime_style": "random", "chime_events": "SessionStart", "color": "vibrant"}
EOF
  echo '{"session_id":"test-new-session"}' | HOME="$FAKE_HOME" bash "$BELL" SessionStart >/dev/null 2>&1 || true
  # bell.sh should pick a real style on SessionStart and write it to per-session file
  local resolved=""
  local _session_file="$FAKE_HOME/.claude/nerdflair/sessions/test-new-session"
  if [[ -f "$_session_file" ]]; then
    resolved=$(grep -o '"chime"[[:space:]]*:[[:space:]]*"[^"]*"' "$_session_file" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  fi
  if [[ -n "$resolved" && "$resolved" != "random" ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: per-session chime style should be a real style, got '$resolved'")
  fi
  _teardown
}

test_bell_suppresses_resume() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_sound": "Glass", "chime_volume": "1", "chime_style": "random", "chime_events": "SessionStart", "color": "vibrant"}
EOF
  # source=resume should cause bell.sh to exit early without creating a per-session style file
  local rc=0
  echo '{"session_id":"old-session","source":"resume"}' | HOME="$FAKE_HOME" bash "$BELL" SessionStart >/dev/null 2>&1 || rc=$?
  local _session_file="$FAKE_HOME/.claude/nerdflair/sessions/old-session"
  if [[ ! -f "$_session_file" ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: resume should not create per-session style file, but it exists")
  fi
  _teardown
}

test_bell_writes_texture_on_session_start() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "off", "chime_sound": "Glass", "chime_volume": "0.50", "chime_style": "random", "chime_events": "SessionStart", "color": "vibrant"}
EOF
  echo '{"session_id":"texture-test-session"}' | HOME="$FAKE_HOME" bash "$BELL" SessionStart >/dev/null 2>&1 || true
  local _session_file="$FAKE_HOME/.claude/nerdflair/sessions/texture-test-session"
  local texture=""
  if [[ -f "$_session_file" ]]; then
    texture=$(grep -o '"texture"[[:space:]]*:[[:space:]]*"[^"]*"' "$_session_file" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  fi
  # Texture should be a known texture name
  local _valid_textures="Wind ThickDots SinWave SquareWave Beads Arrows DotChain Soundwaves Pulse Sparkle InfinityLoop"
  if [[ -n "$texture" && " $_valid_textures " == *" $texture "* ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: texture should be a valid name, got '$texture'")
  fi
  _teardown
}

test_bell_cleans_up_session_file_on_session_end() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "off", "chime_sound": "Glass", "chime_volume": "0.50", "chime_style": "random", "chime_events": "SessionStart,SessionEnd", "color": "vibrant"}
EOF
  # Create a session file via SessionStart
  echo '{"session_id":"cleanup-session"}' | HOME="$FAKE_HOME" bash "$BELL" SessionStart >/dev/null 2>&1 || true
  local _session_file="$FAKE_HOME/.claude/nerdflair/sessions/cleanup-session"
  # Verify it exists
  if [[ ! -f "$_session_file" ]]; then
    (( _fail++ ))
    _errors+=("FAIL: session file should exist after SessionStart")
    _teardown
    return
  fi
  # SessionEnd should remove it
  echo '{"session_id":"cleanup-session"}' | HOME="$FAKE_HOME" bash "$BELL" SessionEnd >/dev/null 2>&1 || true
  if [[ ! -f "$_session_file" ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: session file should be removed after SessionEnd")
  fi
  _teardown
}

test_renderer_reads_texture_from_session_file() {
  _setup
  local state='{"mode": "full", "width": "80", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  # Write a session file with one texture
  mkdir -p "$FAKE_HOME/.claude/nerdflair/sessions"
  printf '{"chime":"BalladPiano","texture":"Wind"}\n' > "$FAKE_HOME/.claude/nerdflair/sessions/test-session-001"
  local output1 output2
  output1=$(_render "$state" "$(_make_input 42 5.00)")
  # Change the texture — output should differ
  printf '{"chime":"BalladPiano","texture":"Beads"}\n' > "$FAKE_HOME/.claude/nerdflair/sessions/test-session-001"
  output2=$(_render "$state" "$(_make_input 42 5.00)")
  if [[ "$output1" != "$output2" ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: different textures should produce different output")
  fi
  _teardown
}


# ════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ════════════════════════════════════════════════════════════════

# Collect all functions starting with test_
_tests=()
while IFS= read -r fn; do
  _tests+=("$fn")
done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)

# Use temp files to collect results across subshells
_results_dir=$(mktemp -d)
trap 'rm -rf "$_results_dir"' EXIT

echo "Running ${#_tests[@]} tests..."
echo ""

for t in "${_tests[@]}"; do
  printf "  %-55s" "$t"
  # Run each test; capture pass/fail via temp files
  _pass=0
  _fail=0
  _errors=()
  if "$t" 2>/dev/null; then
    if (( _fail > 0 )); then
      echo "FAIL"
      echo "$_fail" >> "$_results_dir/fails"
      for e in "${_errors[@]}"; do
        echo "$e" >> "$_results_dir/errors"
      done
    else
      echo "ok"
      echo "$_pass" >> "$_results_dir/passes"
    fi
  else
    echo "FAIL (crashed)"
    echo "1" >> "$_results_dir/fails"
    echo "FAIL: $t -- crashed or exited nonzero" >> "$_results_dir/errors"
  fi
done

_total_pass=0
_total_fail=0
if [[ -f "$_results_dir/passes" ]]; then
  while read -r n; do (( _total_pass += n )); done < "$_results_dir/passes"
fi
if [[ -f "$_results_dir/fails" ]]; then
  while read -r n; do (( _total_fail += n )); done < "$_results_dir/fails"
fi

echo ""
echo "Results: $_total_pass passed, $_total_fail failed"

if [[ -f "$_results_dir/errors" ]]; then
  echo ""
  while IFS= read -r e; do
    echo "  $e"
  done < "$_results_dir/errors"
  exit 1
fi

exit 0
