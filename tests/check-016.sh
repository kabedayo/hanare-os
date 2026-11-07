#!/usr/bin/env bash
# Task 016 test: drag an app onto the services card -> form prefill.
# - app_to_service_prefill maps a discovered app dict to the service
#   form: id slug, display name, exec (systemd-quoted), workdir, url
# - the port is extracted from the app URL (127.0.0.1:8765 -> 8765);
#   apps without a usable URL keep the port blank
# - an app id that already exists in the registry is flagged as a
#   conflict (the drop then acts as an edit, never a silent duplicate)
# - wrapper execs (gnome-terminal etc.) are flagged like the picker
# - the DnD wiring (drag source on app rows, drop dest on the
#   services card, refresh guard while dragging) is present
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD=""
cleanup() {
  [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }

TMPD="$(mktemp -d)" || fail "mktemp"

cat > "$TMPD/dnd_test.py" <<'PYEOF'
import importlib.util, os
repo = os.environ["TMP_REPO"]
spec = importlib.util.spec_from_file_location("panel", os.path.join(repo, "panel.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# --- id normalization -------------------------------------------------
assert m.service_id_from_app_id("local-story-studio") == "local-story-studio"
assert m.service_id_from_app_id("Motion App") == "motion-app"
assert m.service_id_from_app_id("My_App 2") == "my-app-2"
assert m.service_id_from_app_id("UPPER--Case") == "upper-case"
assert m.service_id_from_app_id("!!!") == ""
assert m.service_id_from_app_id("") == ""
assert m.service_id_from_app_id(None) == ""

# --- port extraction ---------------------------------------------------
assert m.port_from_url("http://127.0.0.1:8765/") == 8765
assert m.port_from_url("http://127.0.0.1:5000/") == 5000
assert m.port_from_url("http://127.0.0.1/") is None
assert m.port_from_url("") is None
assert m.port_from_url(None) is None
assert m.port_from_url("-") is None
assert m.port_from_url("http://127.0.0.1:99999/") is None

# --- prefill mapping: Story Studio shaped app --------------------------
story = {
    "id": "local-story-studio",
    "name": "Local Story Studio",
    "exec_argv": ["/home/kabe/story-studio/run.sh"],
    "workdir": "/home/kabe/story-studio",
    "url": "http://127.0.0.1:8765/",
    "source": "登録",
}
pre = m.app_to_service_prefill(story, registry_names={"llama-server", "comfyui"})
assert pre["name"] == "local-story-studio", pre
assert pre["display"] == "Local Story Studio", pre
assert pre["port"] == "8765", pre
assert pre["exec"] == "/home/kabe/story-studio/run.sh", pre
assert pre["workdir"] == "/home/kabe/story-studio", pre
assert pre["url"] == "http://127.0.0.1:8765/", pre
assert pre["conflict"] is False, pre
assert pre["wrapper"] is None, pre

# --- no URL: port stays blank ------------------------------------------
no_url = dict(story, id="folder-tool", url=None, workdir=None)
pre = m.app_to_service_prefill(no_url, registry_names=set())
assert pre["port"] == "", pre
assert pre["url"] == "", pre
assert pre["workdir"] == "", pre

# --- conflict against an explicit name set ------------------------------
pre = m.app_to_service_prefill(story, registry_names={"local-story-studio"})
assert pre["conflict"] is True, pre

# --- conflict against the on-disk registry (registry_names omitted) -----
pre = m.app_to_service_prefill(dict(story, id="llama-server"))
assert pre["name"] == "llama-server", pre
assert pre["conflict"] is True, pre
pre = m.app_to_service_prefill(story)
assert pre["conflict"] is False, pre

# --- quoting + wrapper detection ----------------------------------------
spaced = dict(
    story,
    id="spaced-app",
    exec_argv=["/usr/bin/python3", "/home/kabe/My Apps/tool/app.py"],
)
pre = m.app_to_service_prefill(spaced, registry_names=set())
assert pre["exec"] == '/usr/bin/python3 "/home/kabe/My Apps/tool/app.py"', pre
wrapped = dict(
    story,
    id="agent-tool",
    exec_argv=["gnome-terminal", "--", "/home/kabe/tool/run.sh"],
    url=None,
)
pre = m.app_to_service_prefill(wrapped, registry_names=set())
assert pre["wrapper"] == "gnome-terminal", pre

# --- dump still works and carries apps ----------------------------------
model = m.collect_model()
assert "apps" in model and "services" in model, sorted(model)
print("dnd prefill helpers OK")
PYEOF

mkdir -p "$TMPD/repo/services" "$TMPD/repo/models" "$TMPD/repo/runtime"
ln -s "$ROOT/dashboard" "$TMPD/repo/dashboard"
printf 'llama-server\t8080\tTesla V100\tllama\thanare-llama\t-\t-\t-\n' > "$TMPD/repo/services/services.tsv"
printf 'name\tgguf_path\tmmproj_path\tctx\tprofile\tnote\tdraft_path\n' > "$TMPD/repo/models/models.tsv"
cp "$ROOT/panel/hanare-panel.py" "$TMPD/repo/panel.py"
TMP_REPO="$TMPD/repo" \
HANARE_REPO="$TMPD/repo" \
  python3 "$TMPD/dnd_test.py" || fail "dnd helper test failed"

# --dump is unchanged in shape
TMP_REPO="$TMPD/repo" \
HANARE_REPO="$TMPD/repo" \
  python3 "$TMPD/repo/panel.py" --dump > "$TMPD/dump.json" || fail "--dump failed"
python3 -c '
import json
d = json.load(open("'"$TMPD"'/dump.json"))
assert "apps" in d and "registry" in d, sorted(d)
' || fail "--dump shape changed"

# DnD wiring present in the panel source
grep -qF 'app_to_service_prefill' "$ROOT/panel/hanare-panel.py" || fail "panel has no prefill helper use"
grep -qF 'drag_source_set' "$ROOT/panel/hanare-panel.py" || fail "app rows are not drag sources"
grep -qF 'drag_dest_set' "$ROOT/panel/hanare-panel.py" || fail "services card is not a drop dest"
grep -qF 'drag-data-received' "$ROOT/panel/hanare-panel.py" || fail "no drop handler"
grep -qF 'drop-active' "$ROOT/panel/hanare-panel.py" || fail "no drop highlight"
grep -qF 'drag_state' "$ROOT/panel/hanare-panel.py" || fail "no refresh guard for drags"
grep -qF 'サービス登録フォームに取り込めます' "$ROOT/panel/hanare-panel.py" || fail "no drag hint text"

echo "PASS"
exit 0
