#!/usr/bin/env bash
# Builds a deterministic fixture HOME + git repos for differential testing.
set -euo pipefail
FIX="${1:?fixture dir}"
rm -rf "$FIX"
mkdir -p "$FIX/home/.claude/nerdflair/sessions"
mkdir -p "$FIX/work"

cat > "$FIX/home/.claude/nerdflair/state.json" <<'JSON'
{
  "mode": "full",
  "width": "120",
  "flair": true,
  "terminal_bell": "on",
  "chime_sound": "Glass",
  "chime_volume": "1",
  "chime_style": "Vibraphone",
  "chime_events": "Notification,PermissionRequest,PreCompact,SessionEnd,SessionStart,Stop",
  "color": "vibrant",
  "last_session": "sess-fixed-0001",
  "chime_recent_styles": [
    "TapedMarimba"
  ]
}
JSON

cat > "$FIX/home/.claude.json" <<'JSON'
{
  "mcpServers": {
    "zeta-tools": {"command": "x"},
    "alpha-search": {"command": "x"},
    "Beta_Docs": {"command": "x"},
    "disabled-one": {"command": "x", "disabled": true}
  },
  "projects": {
    "PROJ": {
      "mcpServers": {"proj-scoped": {"command": "x"}},
      "disabledMcpServers": ["zeta-tools"]
    }
  }
}
JSON

echo '{"chime":"Vibraphone"}' > "$FIX/home/.claude/nerdflair/sessions/sess-fixed-0001"

# repo A: a normal repo, dirty, on a feature branch
mkdir -p "$FIX/work/my-project"
(
  cd "$FIX/work/my-project"
  git init -q -b main
  git config user.email t@t; git config user.name t
  printf 'a\nb\nc\n' > file.txt
  git add -A; git commit -qm init
  git checkout -q -b feature/a-long-branch-name-here
  printf 'a\nb\nc\nd\ne\n' > file.txt
  printf 'x\ny\n' > untracked.txt
  git remote add origin git@github.com:acme/my-project.git
) >/dev/null 2>&1

# repo B: clean repo on main
mkdir -p "$FIX/work/clean-repo"
(
  cd "$FIX/work/clean-repo"
  git init -q -b main
  git config user.email t@t; git config user.name t
  echo hi > a.txt; git add -A; git commit -qm init
) >/dev/null 2>&1

# wrapper folder holding 3 repos (multi-repo summary)
mkdir -p "$FIX/work/wrapper"
for r in alpha-service beta-frontend gamma-infra; do
  mkdir -p "$FIX/work/wrapper/$r"
  (
    cd "$FIX/work/wrapper/$r"
    git init -q -b main
    git config user.email t@t; git config user.name t
    echo x > f; git add -A; git commit -qm init
    if [[ "$r" != "gamma-infra" ]]; then git checkout -q -b "feat/$r-work"; fi
  ) >/dev/null 2>&1
done

# wrapper folder holding exactly one repo (adopted)
mkdir -p "$FIX/work/single-wrapper/inner-repo"
(
  cd "$FIX/work/single-wrapper/inner-repo"
  git init -q -b main
  git config user.email t@t; git config user.name t
  echo x > f; git add -A; git commit -qm init
  git checkout -q -b dev/inner
) >/dev/null 2>&1

# non-git plain directory
mkdir -p "$FIX/work/plain-dir"
echo "$FIX"
