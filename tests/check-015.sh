#!/usr/bin/env bash
# Task 015 test: settings-card launcher picker (desktop icon -> form).
# - panel helpers parse .desktop files: Name/Exec/Path, field codes stripped
# - quoted Exec values (incl. paths with spaces) survive shlex and are
#   re-quoted for systemd ExecStart
# - Hidden/NoDisplay entries are skipped; duplicate file names dedupe
# - wrapper Execs (gnome-terminal / steam / nohup / xdg-open) are flagged
# - --dump exposes "launchers" so the picker data is headless-checkable
# - the settings card has the picker UI wired to the service form
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD=""
cleanup() {
  [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }

TMPD="$(mktemp -d)" || fail "mktemp"
mkdir -p "$TMPD/desk1" "$TMPD/desk2"

cat > "$TMPD/desk1/scene-pipeline-app.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=3D Pipeline
Exec=/home/kabe/scene-pipeline-app/run.sh
Path=/home/kabe/scene-pipeline-app
Icon=utilities-terminal
EOF

cat > "$TMPD/desk1/local-story-studio.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Local Story Studio
Exec="/usr/bin/python3" "/home/kabe/My Apps/story-studio/launch-desktop.py"
EOF

cat > "$TMPD/desk1/strata-agent.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Strata Agent
Exec=gnome-terminal --title="Strata Agent" -- bash -lc "/home/kabe/strata-agent.sh; exec bash"
EOF

cat > "$TMPD/desk1/game.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Some Game
Exec=steam steam://rungameid/960170 %U
EOF

cat > "$TMPD/desk1/background.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Background Helper
Exec=nohup /opt/helper/run.sh &
EOF

cat > "$TMPD/desk1/hidden.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Hidden One
Exec=/bin/true
NoDisplay=true
EOF

# Same file name in the second folder must lose to the first folder.
cat > "$TMPD/desk2/scene-pipeline-app.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Duplicate Should Not Win
Exec=/bin/false
EOF

cat > "$TMPD/launcher_test.py" <<'PYEOF'
import importlib.util, os, sys
repo = os.environ["TMP_REPO"]
spec = importlib.util.spec_from_file_location("panel", os.path.join(repo, "panel.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
items = m.scan_launchers()
by_file = {os.path.basename(i["file"]): i for i in items}
assert "hidden.desktop" not in by_file, sorted(by_file)
scene = by_file["scene-pipeline-app.desktop"]
assert scene["name"] == "3D Pipeline", scene
assert scene["exec"] == "/home/kabe/scene-pipeline-app/run.sh", scene
assert scene["workdir"] == "/home/kabe/scene-pipeline-app", scene
assert scene["id_suggestion"] == "scene-pipeline-app", scene
assert scene["wrapper"] is None, scene
story = by_file["local-story-studio.desktop"]
assert story["exec_argv"] == ["/usr/bin/python3", "/home/kabe/My Apps/story-studio/launch-desktop.py"], story
assert story["exec"] == '/usr/bin/python3 "/home/kabe/My Apps/story-studio/launch-desktop.py"', story
assert story["workdir"] == "", story
agent = by_file["strata-agent.desktop"]
assert agent["wrapper"] == "gnome-terminal", agent
game = by_file["game.desktop"]
assert game["wrapper"] == "steam", game
assert "%" not in game["exec"], game
bg = by_file["background.desktop"]
assert bg["wrapper"] == "nohup", bg
# dump carries the same launchers
model = m.collect_model()
names = {i["name"] for i in model["launchers"]}
assert "3D Pipeline" in names and "Local Story Studio" in names, names
print("launcher helpers OK")
PYEOF

mkdir -p "$TMPD/repo/services" "$TMPD/repo/models" "$TMPD/repo/runtime"
ln -s "$ROOT/dashboard" "$TMPD/repo/dashboard"
printf 'llama-server\t8080\tTesla V100\tllama\thanare-llama\t-\t-\t-\n' > "$TMPD/repo/services/services.tsv"
printf 'name\tgguf_path\tmmproj_path\tctx\tprofile\tnote\tdraft_path\n' > "$TMPD/repo/models/models.tsv"
cp "$ROOT/panel/hanare-panel.py" "$TMPD/repo/panel.py"
TMP_REPO="$TMPD/repo" \
HANARE_REPO="$TMPD/repo" \
HANARE_LAUNCHER_DIRS="$TMPD/desk1:$TMPD/desk2" \
  python3 "$TMPD/launcher_test.py" || fail "launcher helper test failed"

# --dump exposes launchers without a display
TMP_REPO="$TMPD/repo" \
HANARE_REPO="$TMPD/repo" \
HANARE_LAUNCHER_DIRS="$TMPD/desk1:$TMPD/desk2" \
  python3 "$TMPD/repo/panel.py" --dump > "$TMPD/dump.json" || fail "--dump failed"
python3 -c '
import json
d = json.load(open("'"$TMPD"'/dump.json"))
names = {i["name"] for i in d["launchers"]}
assert "3D Pipeline" in names, names
' || fail "--dump lacks launchers"

# UI wiring present in the panel source
grep -qF 'アイコンから選ぶ' "$ROOT/panel/hanare-panel.py" || fail "panel has no launcher picker label"
grep -qF 'on_load_launcher' "$ROOT/panel/hanare-panel.py" || fail "panel has no launcher load handler"
grep -qF 'ComboBoxText' "$ROOT/panel/hanare-panel.py" || fail "panel picker is not a combo box"
grep -qF '人間用ラッパー' "$ROOT/panel/hanare-panel.py" || fail "panel has no wrapper warning"

echo "PASS"
exit 0
