#!/usr/bin/env bash
# install.sh — build and install the avod daemon for the current user.
#
# No sudo, no root, no flags: everything lands under $HOME
# (~/.local/bin and ~/.config/systemd/user), matching the user-unit shape of
# avod.service. The script lives at host/avod/dist/, so the repo root is two
# directories up from host/avod, i.e. three up from this script.
set -euo pipefail

DIST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIST_DIR/../../.." && pwd)"
CARGO_MANIFEST="$ROOT/host/avod/Cargo.toml"
BIN_SRC="$ROOT/target/release/avod"
BIN_DST="$HOME/.local/bin/avod"
UNIT_DST="$HOME/.config/systemd/user/avod.service"

cargo build --release --manifest-path "$CARGO_MANIFEST"

mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"

# host/avod/Cargo.toml currently defines the crate with no [[bin]] section
# and there is no src/main.rs — the crate is lib-only at this base, so
# cargo produces an rlib and target/release/avod does not exist yet. The
# binary appears with the daemon-body slice, which will add src/main.rs
# (Cargo then auto-builds a binary named after the package: avod). Handle
# both cases so the unit install never depends on the binary being there.
if [[ -f "$BIN_SRC" ]]; then
    cp "$BIN_SRC" "$BIN_DST"
    echo "installed: $BIN_DST"
else
    echo "note: target/release/avod not found — host/avod is lib-only at this base; the avod binary appears with the daemon-body slice. Installing the unit only."
fi

cp "$DIST_DIR/avod.service" "$UNIT_DST"

systemctl --user daemon-reload

echo "remaining manual step: systemctl --user enable --now avod.service"
