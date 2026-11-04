#!/usr/bin/env bash
# Install the HANARE read-only dashboard as a systemd USER unit (user-level only).
# Idempotent: safe to run multiple times.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNIT_DIR="${HOME}/.config/systemd/user"

SRC_DIR="$REPO_ROOT/systemd"
if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: repo systemd/ directory not found at $SRC_DIR" >&2
  exit 1
fi

mkdir -p "$UNIT_DIR"

cp "$SRC_DIR/hanare-dashboard.service" "$UNIT_DIR/hanare-dashboard.service"

systemctl --user daemon-reload
systemctl --user enable --now hanare-dashboard.service

echo "--- status ---"
systemctl --user status hanare-dashboard.service --no-pager | head -n 10
