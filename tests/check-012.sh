#!/usr/bin/env bash
# Task 012 test: native panel window (GTK), topbar launcher, .desktop install.
set -u
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }

PANEL="panel/hanare-panel.py"
[ -f "$PANEL" ] || fail "missing $PANEL"
python3 -m py_compile "$PANEL" || fail "panel does not compile"

grep -q "Gtk.Application" "$PANEL" || fail "panel is not a Gtk.Application"
grep -q "org.hanare.panel" "$PANEL" || fail "panel has no application id"
grep -q "hanare-box\|Noto Serif CJK" "$PANEL" || fail "panel lost wa-modern styling"
grep -q "shell=True" "$PANEL" && fail "panel must never use shell=True"

# --dump must emit the full data model without a display.
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/apps" "$TMPD/drop" "$TMPD/runtime" "$TMPD/models"
ln -s "$PWD/dashboard" "$TMPD/dashboard"
cat > "$TMPD/apps/story.app" <<'EOF'
name=Story App
exec=/opt/story/run.sh --serve
url=http://127.0.0.1:8765/
EOF
cat > "$TMPD/runtime/last-status.json" <<'EOF'
{"timestamp": "2026-11-03T02:00:00+0900",
 "gpus": [{"index": 0, "name": "Tesla V100-PCIE-32GB", "memory_used_mib": 100, "memory_total_mib": 32768}],
 "memory": {"ram_used_mib": 1000, "ram_total_mib": 48000},
 "services": [{"name": "llama-server", "state": "running", "port": 8080, "elapsed_sec": 60},
              {"name": "comfyui", "state": "stopped", "port": 8188}]}
EOF
printf '%s\n' '{"ts": "2026-11-03T02:00:00+0900", "kind": "metric", "actor": "hanare-capture", "name": "llama-server", "detail": {"vram_mib": 100}}' > "$TMPD/runtime/events.jsonl"
printf 'name\tgguf_path\tmmproj_path\tctx\tprofile\tnote\tdraft_path\nqwen3.8-27b\t/m/q.gguf\t-\t131072\tqwen38\ttest\t-\n' > "$TMPD/models/models.tsv"
echo "qwen3.8-27b" > "$TMPD/runtime/current-model"
cat > "$TMPD/stub-systemctl" <<'EOF'
#!/bin/sh
echo inactive
exit 0
EOF
chmod +x "$TMPD/stub-systemctl"

HANARE_REPO="$TMPD" \
HANARE_APPS_DIR="$TMPD/apps" \
HANARE_APPS_DROP_DIR="$TMPD/drop" \
HANARE_SYSTEMCTL="$TMPD/stub-systemctl" \
  python3 "$PANEL" --dump > "$TMPD/dump.json" || fail "--dump exited nonzero"
python3 - "$TMPD/dump.json" <<'EOF' || fail "--dump JSON incomplete"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["current_model"] == "qwen3.8-27b", d["current_model"]
assert [m["name"] for m in d["models"]] == ["qwen3.8-27b"]
assert {s["name"] for s in d["services"]} == {"llama-server", "comfyui"}
assert any(a["name"] == "Story App" for a in d["apps"]), d["apps"]
assert len(d["events"]) == 1
EOF

# Topbar integration: menu item + launcher method.
grep -q "パネルを開く" topbar/extension.js || fail "topbar has no panel menu item"
grep -q "_openPanel" topbar/extension.js || fail "topbar has no _openPanel"
grep -q "hanare-panel.py" topbar/extension.js || fail "topbar does not launch the panel"

# Installer writes a valid .desktop into a scratch HOME.
FAKEHOME="$TMPD/home"
mkdir -p "$FAKEHOME"
HOME="$FAKEHOME" bash setup/14-install-panel.sh >/dev/null || fail "installer failed"
DF="$FAKEHOME/.local/share/applications/hanare-panel.desktop"
[ -f "$DF" ] || fail "installer wrote no .desktop"
grep -q "hanare-panel.py" "$DF" || fail ".desktop does not point at the panel"

echo "PASS"
