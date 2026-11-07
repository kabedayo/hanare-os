#!/usr/bin/env bash
# Task 021 test: wrapper detection also peeks inside scripts.
# - a .py/.sh whose body opens a terminal/browser (gnome-terminal,
#   xdg-open, webbrowser, nohup...) is flagged as a wrapper even when
#   the Exec line itself looks clean
# - a foreground server script (exec uvicorn) stays clean
# - binaries and missing files are skipped without error
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD=""
cleanup() { [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
TMPD="$(mktemp -d)" || fail "mktemp"
mkdir -p "$TMPD/repo"
cp "$ROOT/panel/hanare-panel.py" "$TMPD/repo/panel.py"

cat > "$TMPD/wrap_test.py" <<'PYEOF'
import importlib.util, os
repo = os.environ["TMP_REPO"]
tmp = os.environ["TMP_FIX"]
spec = importlib.util.spec_from_file_location("panel", os.path.join(repo, "panel.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

def write(name, body, binary=False):
    path = os.path.join(tmp, name)
    mode = "wb" if binary else "w"
    with open(path, mode) as fh:
        fh.write(body)
    return path

wrapper_py = write("launch-desktop.py", "import subprocess\nsubprocess.run(['gnome-terminal', '--', 'bash'])\n")
assert m.script_wrapper_token(["/usr/bin/python3", wrapper_py]) is not None
assert "gnome-terminal" in m.script_wrapper_token(["/usr/bin/python3", wrapper_py])

browser_sh = write("start.sh", "#!/bin/bash\nnohup python3 server.py &\nxdg-open http://127.0.0.1:9000/\n")
assert m.script_wrapper_token([browser_sh]) is not None

clean_sh = write("run.sh", "#!/bin/bash\nexec uvicorn app.main:app --host 127.0.0.1 --port 8765\n")
assert m.script_wrapper_token([clean_sh]) is None

resident_sh = write("resident.sh", "#!/bin/bash\npython3 app.py &\nSERVER=$!\nxdg-open http://127.0.0.1:8777/ || true\nwait \"$SERVER\"\n")
assert m.script_wrapper_token([resident_sh]) is None

binary = write("python3", b"\x7fELF\x00\x01gnome-terminal\x00", binary=True)
assert m.script_wrapper_token([binary]) is None

assert m.script_wrapper_token(["/nonexistent/none.py"]) is None
assert m.script_wrapper_token([]) is None
assert m.script_wrapper_token(None) is None

# a .desktop whose Exec hides the wrapper inside a script is flagged
desktop = write("wrap.desktop", "[Desktop Entry]\nType=Application\nName=Wrap Test\nExec=/usr/bin/python3 %s\n" % wrapper_py)
parsed = m.parse_desktop_file(desktop)
assert parsed is not None and parsed["wrapper"], parsed
print("script wrapper check OK")
PYEOF
TMP_REPO="$TMPD/repo" TMP_FIX="$TMPD" python3 "$TMPD/wrap_test.py" || fail "script wrapper asserts"
echo PASS
