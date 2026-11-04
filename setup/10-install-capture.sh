#!/usr/bin/env bash
# Install the HANARE capture timer as a systemd USER unit (user-level only).
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

cp "$SRC_DIR/hanare-capture.service" "$UNIT_DIR/hanare-capture.service"
cp "$SRC_DIR/hanare-capture.timer" "$UNIT_DIR/hanare-capture.timer"

systemctl --user daemon-reload
systemctl --user enable --now hanare-capture.timer

echo "--- timers ---"
systemctl --user list-timers hanare-capture.timer --no-pager
