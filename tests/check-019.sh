#!/usr/bin/env bash
# Task 019 test: demote a service back to an app (reverse drag).
# - demote_service_to_app writes apps.d/<name>.app from the registry
#   row and removes the registry row (generated unit cleanup rides on
#   remove_service)
# - hand-managed services (exec "-") are refused and stay registered
# - unknown services are refused
# - the panel wires service rows as drag sources (svc: payload) and
#   the apps card as a drop destination
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD=""
cleanup() { [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
TMPD="$(mktemp -d)" || fail "mktemp"
mkdir -p "$TMPD/repo/services" "$TMPD/repo/apps.d" "$TMPD/units"
cp "$ROOT/panel/hanare-panel.py" "$TMPD/repo/panel.py"
printf 'fake-svc\t9999\t-\tFake Service\thanare-fake-svc\t/bin/true\t/tmp\t-\n' > "$TMPD/repo/services/services.tsv"
printf 'hand-svc\t9998\t-\tHand Service\thanare-hand\t-\t-\t-\n' >> "$TMPD/repo/services/services.tsv"

cat > "$TMPD/demote_test.py" <<'PYEOF'
import importlib.util, os
repo = os.environ["TMP_REPO"]
spec = importlib.util.spec_from_file_location("panel", os.path.join(repo, "panel.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

ok, msg = m.demote_service_to_app("fake-svc")
assert ok, msg
app_file = os.path.join(repo, "apps.d", "fake-svc.app")
assert os.path.isfile(app_file), "app file not written"
body = open(app_file, encoding="utf-8").read()
assert "name=Fake Service" in body, body
assert "exec=/bin/true" in body, body
assert "workdir=/tmp" in body, body
names = [r["name"] for r in m.load_service_registry()]
assert "fake-svc" not in names, names
assert "hand-svc" in names, names

ok, msg = m.demote_service_to_app("hand-svc")
assert not ok, msg
names = [r["name"] for r in m.load_service_registry()]
assert "hand-svc" in names, names
assert not os.path.exists(os.path.join(repo, "apps.d", "hand-svc.app"))

ok, msg = m.demote_service_to_app("no-such")
assert not ok, msg
print("demote function OK")
PYEOF
HANARE_REPO="$TMPD/repo" HANARE_SERVICE_GEN=/bin/true HANARE_SYSTEMCTL=/bin/true \
  HANARE_UNIT_DIR="$TMPD/units" TMP_REPO="$TMPD/repo" \
  python3 "$TMPD/demote_test.py" || fail "demote asserts"

P="$ROOT/panel/hanare-panel.py"
grep -qF 'seb.drag_source_set' "$P" || fail "service rows are not drag sources"
grep -qF 'app_eb.drag_dest_set' "$P" || fail "apps card is not a drop dest"
grep -qF '"svc:" + _n' "$P" || fail "service payload has no svc: prefix"
grep -qF 'demote_service_to_app(svc_name)' "$P" || fail "drop does not demote"
echo PASS
