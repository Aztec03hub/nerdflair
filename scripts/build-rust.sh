#!/usr/bin/env bash
# Build the Rust statusline and install it where settings.json points.
# Kept out of target/ deliberately: `cargo clean` must not blank the statusline.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
cargo build --release --manifest-path rust/Cargo.toml
mkdir -p "$HOME/.local/bin"
install -m 0755 rust/target/release/nerdflair-statusline "$HOME/.local/bin/nerdflair-statusline"
echo "installed -> $HOME/.local/bin/nerdflair-statusline"
"$HOME/.local/bin/nerdflair-statusline" --version 2>/dev/null || true
# The band plugin is a COPY of band/ and goes stale silently; say so here, where a code change gets deployed.
bash "$(dirname "${BASH_SOURCE[0]}")/../band/sync-local-plugin.sh" --check || echo "build-rust: the installed band plugin is out of date (see above); run band/sync-local-plugin.sh" >&2
