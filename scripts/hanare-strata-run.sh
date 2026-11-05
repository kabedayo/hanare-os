#!/usr/bin/env bash
# HANARE Strata runner: Strata server (FlashNext) on 127.0.0.1:8095.
# Run by the hanare-strata user unit; exec so systemd tracks the server
# process itself (the GPU engine is its child, in the same cgroup).
set -u

STRATA_DIR="$HOME/Documents/Codex/Strata"
LOG_DIR="$HOME/hanare-os/runtime/logs"
mkdir -p "$LOG_DIR"

cd "$STRATA_DIR" || exit 1
export STRATA_ENGINE_READY_S="${STRATA_ENGINE_READY_S:-3600}"

echo "hanare-strata: starting Strata (FlashNext) on 127.0.0.1:8095"
exec "$STRATA_DIR/.venv/bin/python" serve/server.py --engine strata \
  --config strata-sojal-iq3_xxs.json --port 8095 >> "$LOG_DIR/strata.log" 2>&1
