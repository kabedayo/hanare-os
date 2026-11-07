#!/usr/bin/env bash
# Task 017 test: URL auto-fill from the port in the service form.
# - auto_url_for_port builds http://127.0.0.1:<port>/ for valid ports
# - upsert_service fills an empty URL from the port at save time
# - the panel wires live fill to the port entry (without overwriting a
#   manually edited URL: that logic is UI-side, checked here by grep
#   for the last-auto tracking state)
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD=""
cleanup() {
  [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }

TMPD="$(mktemp -d)" || fail "mktemp"
mkdir -p "$TMPD/repo"
cp "$ROOT/panel/hanare-panel.py" "$TMPD/repo/panel.py"

cat > "$TMPD/autourl_test.py" <<'PYEOF'
import importlib.util, os
repo = os.environ["TMP_REPO"]
spec = importlib.util.spec_from_file_location("panel", os.path.join(repo, "panel.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

assert m.auto_url_for_port(8765) == "http://127.0.0.1:8765/"
assert m.auto_url_for_port("5000") == "http://127.0.0.1:5000/"
assert m.auto_url_for_port(" 8899 ") == "http://127.0.0.1:8899/"
assert m.auto_url_for_port("") == ""
assert m.auto_url_for_port("abc") == ""
assert m.auto_url_for_port(0) == ""
assert m.auto_url_for_port(65536) == ""
assert m.auto_url_for_port(None) == ""
print("auto-url helpers OK")
PYEOF
TMP_REPO="$TMPD/repo" python3 "$TMPD/autourl_test.py" || fail "helper asserts"

grep -qF 'auto_url_for_port(port) or "-"' "$ROOT/panel/hanare-panel.py" || fail "upsert does not auto-fill url"
grep -qF 'on_port_changed' "$ROOT/panel/hanare-panel.py" || fail "no live fill handler"
grep -qF 'url_auto_state' "$ROOT/panel/hanare-panel.py" || fail "no manual-edit tracking state"
echo PASS
