#!/usr/bin/env bash
# Task 020 test: (1) apps started outside their hanare-app unit can be
# stopped (stop-app-external reap + 管理外 detection), (2) the update
# policy is "60 s periodic, immediate capture on open and on action"
# for both the panel and the dashboard, with capture passes
# flock-serialized in feed/capture.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD=""
DASH_PID=""
cleanup() {
  [ -n "$DASH_PID" ] && kill "$DASH_PID" 2>/dev/null
  for port in 18991 18992 18994 18995; do
    pkill -f "http.server $port" 2>/dev/null
  done
  [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"
  true
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }

TMPD="$(mktemp -d)" || fail "mktemp"
mkdir -p "$TMPD/apps.d" "$TMPD/work" "$TMPD/work-other" "$TMPD/drop" \
         "$TMPD/repo/services" "$TMPD/repo/apps.d" "$TMPD/repo/dashboard"

start_listener() { # dir port
  ( cd "$1" && exec setsid python3 -m http.server "$2" --bind 127.0.0.1 ) \
    >/dev/null 2>&1 &
  local i
  for i in $(seq 1 24); do
    ss -tln 2>/dev/null | grep -q ":$2 " && return 0
    sleep 0.25
  done
  return 1
}
port_open() { ss -tln 2>/dev/null | grep -q ":$1 "; }

# ---------------------------------------------------------------- wiring
P="$ROOT/panel/hanare-panel.py"
D="$ROOT/dashboard/dashboard.py"
S="$ROOT/scripts/hanare-service.sh"
C="$ROOT/feed/capture.sh"

bash -n "$S" || fail "hanare-service.sh syntax"
bash -n "$C" || fail "capture.sh syntax"
grep -qF 'stop-app-external' "$S" || fail "helper has no stop-app-external"
grep -qF 'stop-app-external' "$P" || fail "panel stop does not reap external apps"
grep -qF 'stop-app-external' "$D" || fail "dashboard stop does not reap external apps"
grep -qF 'app_external_pid' "$P" || fail "panel has no external app detection"
grep -qF 'app_external_pid' "$D" || fail "dashboard has no external app detection"
grep -qF 'flock' "$C" || fail "capture.sh has no flock serialization"
grep -qF 'capture_now_async' "$P" || fail "panel has no immediate capture"
grep -qF 'GLib.timeout_add_seconds(60, refresh)' "$P" \
  || fail "panel periodic refresh is not 60 s"
if grep -qF 'GLib.timeout_add_seconds(5, refresh)' "$P"; then
  fail "panel still refreshes every 5 s"
fi
grep -qF 'run_capture' "$D" || fail "dashboard has no immediate capture"
grep -qF 'hanare_seen' "$D" || fail "dashboard has no first-load cookie"
grep -qF 'Set-Cookie' "$D" || fail "dashboard never sets the seen cookie"

# ------------------------------------------------- helper: matching reap
cat > "$TMPD/apps.d/fake-app.app" <<EOF
name=Fake App
exec=/usr/bin/python3 -m http.server 18991
workdir=$TMPD/work
url=http://127.0.0.1:18991/
EOF
start_listener "$TMPD/work" 18991 || fail "listener 18991 did not start"
HANARE_APPS_DIR="$TMPD/apps.d" bash "$S" stop-app-external fake-app \
  || fail "stop-app-external refused a cwd-matching listener"
port_open 18991 && fail "port 18991 still open after reap"

# ------------------------------------------------ helper: identity refusal
cat > "$TMPD/apps.d/fake-app2.app" <<EOF
name=Fake App 2
exec=/usr/bin/python3 -m http.server 18992
workdir=$TMPD/work
url=http://127.0.0.1:18992/
EOF
start_listener "$TMPD/work-other" 18992 || fail "listener 18992 did not start"
rc=0
HANARE_APPS_DIR="$TMPD/apps.d" bash "$S" stop-app-external fake-app2 || rc=$?
[ "$rc" -eq 4 ] || fail "mismatched listener: expected refusal rc=4, got $rc"
port_open 18992 || fail "mismatched listener was killed (must be refused)"
pkill -f "http.server 18992" 2>/dev/null

# ------------------------------------------------------ helper: no/none
cat > "$TMPD/apps.d/fake-app3.app" <<EOF
name=Fake App 3
exec=/usr/bin/python3 -m http.server 18993
workdir=$TMPD/work
url=http://127.0.0.1:18993/
EOF
rc=0
HANARE_APPS_DIR="$TMPD/apps.d" bash "$S" stop-app-external fake-app3 || rc=$?
[ "$rc" -eq 3 ] || fail "no listener: expected rc=3, got $rc"
rc=0
HANARE_APPS_DIR="$TMPD/apps.d" bash "$S" stop-app-external no-such-app || rc=$?
[ "$rc" -eq 2 ] || fail "unknown app: expected rc=2, got $rc"

# ------------------------------------------- panel: detection + stop path
cat > "$TMPD/apps.d/panel-app.app" <<EOF
name=Panel App
exec=/usr/bin/python3 -m http.server 18994
workdir=$TMPD/work
url=http://127.0.0.1:18994/
EOF
cp "$ROOT/panel/hanare-panel.py" "$TMPD/repo/panel.py"
cp "$ROOT/dashboard/discovery.py" "$TMPD/repo/dashboard/discovery.py"
start_listener "$TMPD/work" 18994 || fail "listener 18994 did not start"

cat > "$TMPD/panel_test.py" <<'PYEOF'
import importlib.util, os
repo = os.environ["TMP_REPO"]
spec = importlib.util.spec_from_file_location("panel", os.path.join(repo, "panel.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

apps = {a["id"]: a for a in m.scan_apps()}
assert "panel-app" in apps, sorted(apps)
item = apps["panel-app"]
assert item["active"] is False, item
assert item["external"] is True, item
ok = m.do_app_action(item, "stop")
assert ok, "do_app_action stop returned False"
apps = {a["id"]: a for a in m.scan_apps()}
assert apps["panel-app"]["external"] is False, apps["panel-app"]
print("panel external detection + stop OK")
PYEOF
HANARE_REPO="$TMPD/repo" TMP_REPO="$TMPD/repo" \
  HANARE_APPS_DIR="$TMPD/apps.d" \
  HANARE_SYSTEMCTL=/bin/true \
  HANARE_SERVICE_CLI="$ROOT/scripts/hanare-service.sh" \
  HANARE_APPS_DROP_DIR="$TMPD/drop" \
  python3 "$TMPD/panel_test.py" || fail "panel functional asserts"
port_open 18994 && fail "port 18994 still open after panel stop"

# ------------------------------------------------ capture lock: parallel
( bash "$C" & bash "$C" & wait ) || fail "parallel captures failed"
HANARE_STATUS_SNAP="$TMPD/snap.json" bash "$C" || fail "capture with tmp snap"
python3 -c "import json; json.load(open('$TMPD/snap.json'))" \
  || fail "snapshot is not valid JSON"

# ------------------------------------- dashboard: first-load capture cookie
cat > "$TMPD/apps.d/dash-app.app" <<EOF
name=Dash App
exec=/usr/bin/python3 -m http.server 18995
workdir=$TMPD/work
url=http://127.0.0.1:18995/
EOF
start_listener "$TMPD/work" 18995 || fail "listener 18995 did not start"
HANARE_DASH_PORT=18990 HANARE_SYSTEMCTL=/bin/true HANARE_SYSTEMD_RUN=/bin/true \
  HANARE_SERVICE_CLI="$S" HANARE_APPS_DIR="$TMPD/apps.d" \
  HANARE_APPS_DROP_DIR="$TMPD/drop" \
  HANARE_STATUS_SNAP="$TMPD/dash-snap.json" HANARE_EVENT_LOG="$TMPD/events.jsonl" \
  python3 "$ROOT/dashboard/dashboard.py" >"$TMPD/dash.log" 2>&1 &
DASH_PID=$!
ok=0
for i in $(seq 1 24); do
  curl -s -o /dev/null "http://127.0.0.1:18990/" && { ok=1; break; }
  sleep 0.25
done
[ "$ok" -eq 1 ] || fail "dashboard did not come up"
curl -s -D "$TMPD/h1" -o "$TMPD/page1.html" "http://127.0.0.1:18990/" \
  || fail "first GET failed"
grep -qi 'Set-Cookie: hanare_seen=1' "$TMPD/h1" \
  || fail "first load did not set the seen cookie"
grep -q '管理外' "$TMPD/page1.html" \
  || fail "dashboard page does not mark the external app"
curl -s -D "$TMPD/h2" -o /dev/null -H 'Cookie: hanare_seen=1' \
  "http://127.0.0.1:18990/" || fail "second GET failed"
if grep -qi 'Set-Cookie: hanare_seen' "$TMPD/h2"; then
  fail "second load (with cookie) captured again / re-set the cookie"
fi
resp="$(curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"id": "dash-app", "action": "stop"}' "http://127.0.0.1:18990/app")" \
  || fail "POST /app failed"
case "$resp" in
  *'"result": "stopped"'*) : ;;
  *) fail "dashboard stop did not reap the external app: $resp" ;;
esac
port_open 18995 && fail "port 18995 still open after dashboard stop"
kill "$DASH_PID" 2>/dev/null
DASH_PID=""

echo PASS
