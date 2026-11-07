#!/usr/bin/env bash
# Install the hanare-comfyui, hanare-llama and hanare-strata systemd user units.
# Idempotent: safe to run multiple times. Nothing is auto-started.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

mkdir -p "$UNIT_DIR"
mkdir -p "$REPO_ROOT/runtime/logs"
if [ -f "$REPO_ROOT/systemd/hanare-comfyui.service" ]; then
  cp "$REPO_ROOT/systemd/hanare-comfyui.service" "$UNIT_DIR/hanare-comfyui.service"
else
  echo "note: systemd/hanare-comfyui.service not found."
  echo "      Copy systemd/hanare-comfyui.service.example, set your ComfyUI paths,"
  echo "      save it as systemd/hanare-comfyui.service and re-run this script"
  echo "      to set up the ComfyUI unit."
fi
cp "$REPO_ROOT/systemd/hanare-llama.service" "$UNIT_DIR/hanare-llama.service"
cp "$REPO_ROOT/systemd/hanare-strata.service" "$UNIT_DIR/hanare-strata.service"
# Registry-managed services (services/services.tsv rows whose exec is
# not "-") get their units generated from the registry instead.
if [ -f "$REPO_ROOT/scripts/hanare-service-gen.sh" ]; then
  bash "$REPO_ROOT/scripts/hanare-service-gen.sh"
fi
systemctl --user daemon-reload

echo "Installed user units:"
[ -f "$UNIT_DIR/hanare-comfyui.service" ] && echo "  $UNIT_DIR/hanare-comfyui.service"
echo "  $UNIT_DIR/hanare-llama.service"
echo "  $UNIT_DIR/hanare-strata.service"
echo
echo "Status:"
systemctl --user status hanare-comfyui --no-pager || true
systemctl --user status hanare-llama --no-pager || true
systemctl --user status hanare-strata --no-pager || true
echo
echo "On-demand commands:"
echo "  systemctl --user start hanare-comfyui    # stop / status / restart"
echo "  systemctl --user start hanare-llama      # stop / status / restart"
echo "  systemctl --user start hanare-strata     # stop / status / restart"
