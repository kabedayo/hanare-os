#!/usr/bin/env bash
# Install the HANARE panel: a .desktop launcher for the native window.
# The panel itself is panel/hanare-panel.py in this repo (no build step).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PANEL="$ROOT/panel/hanare-panel.py"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$APPS_DIR/hanare-panel.desktop"

[ -f "$PANEL" ] || { echo "panel not found: $PANEL" >&2; exit 1; }
chmod +x "$PANEL"
mkdir -p "$APPS_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=HANARE パネル
Comment=HANARE の状態と操作（ネイティブウィンドウ）
Exec=python3 $PANEL
Icon=utilities-system-monitor
Terminal=false
Categories=Utility;System;
EOF
echo "installed: $DESKTOP_FILE"
