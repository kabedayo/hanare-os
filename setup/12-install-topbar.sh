#!/usr/bin/env bash
# Install the top-bar extension files (user-level only, no privileges needed).
# Idempotent: safe to run multiple times.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXT_DIR="${HOME}/.local/share/gnome-shell/extensions/vram-ram-monitor@kabe.local"

SRC_DIR="$REPO_ROOT/topbar"
if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: repo topbar/ directory not found at $SRC_DIR" >&2
  exit 1
fi

mkdir -p "$EXT_DIR"

cp "$SRC_DIR/extension.js" "$EXT_DIR/extension.js"
cp "$SRC_DIR/metadata.json" "$EXT_DIR/metadata.json"
cp "$SRC_DIR/stylesheet.css" "$EXT_DIR/stylesheet.css"

echo "Installed vram-ram-monitor@kabe.local to $EXT_DIR"
echo "Note: on Wayland the change appears after one logout/login."
