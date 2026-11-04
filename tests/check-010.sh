#!/usr/bin/env bash
# Task 010 test: user apps registry (apps.d) + dashboard launch/stop.
# Uses stub systemctl / systemd-run so no real services are touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASH="$ROOT/dashboard/dashboard.py"
PORT="${HANARE_TEST_PORT:-8992}"
BASE="http://127.0.0.1:$PORT"

TMPD=""
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

[ -f "$DASH" ] || fail "missing dashboard.py"
TMPD="$(mktemp -d)" || fail "mktemp"
SC_LOG="$TMPD/systemctl.log"
SR_LOG="$TMPD/systemd-run.log"
STATE_FILE="$TMPD/app-state"
APPS_DIR="$TMPD/apps"
mkdir -p "$APPS_DIR"
echo "inactive" > "$STATE_FILE"

cat > "$APPS_DIR/sample.app" <<'EOF'
name=Sample App
exec=/usr/bin/sample --flag "quoted arg"
workdir=/tmp/sample
url=http://127.0.0.1:9999/
note=sample note
EOF

cat > "$TMPD/stub-systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SC_LOG"
if [ "\${1:-}" = "--user" ] && [ "\${2:-}" = "is-active" ]; then
  cat "$STATE_FILE" 2>/dev/null || echo inactive
  exit 0
fi
exit 0
EOF
cat > "$TMPD/stub-systemd-run" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SR_LOG"
exit 0
EOF
cat > "$TMPD/stub-model" <<EOF
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMPD/stub-systemctl" "$TMPD/stub-systemd-run" "$TMPD/stub-model"

HANARE_DASH_PORT="$PORT" \
  HANARE_APPS_DIR="$APPS_DIR" \
  HANARE_SYSTEMCTL="$TMPD/stub-systemctl" \
  HANARE_SYSTEMD_RUN="$TMPD/stub-systemd-run" \
  HANARE_MODEL_CLI="$TMPD/stub-model" \
  python3 "$DASH" >"$TMPD/server.log" 2>&1 &
SERVER_PID=$!

ok=0
for _ in $(seq 1 50); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null || true)"
  [ "$code" = "200" ] && { ok=1; break; }
  sleep 0.2
done
[ "$ok" = "1" ] || fail "dashboard did not start (see $TMPD/server.log)"

post() { # post <path> <body> -> sets CODE, writes body to $TMPD/resp
  CODE="$(curl -s -o "$TMPD/resp" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d "$2" "$BASE/$1" 2>/dev/null || true)"
}

# 1. GET / shows the アプリ section with the sample app.
body="$(curl -s "$BASE/")"
echo "$body" | grep -qF 'アプリ' || fail "GET / missing アプリ"
echo "$body" | grep -qF 'Sample App' || fail "GET / missing sample app name"
echo "$body" | grep -qF '停止中' || fail "GET / missing 停止中 state"
echo "$body" | grep -qF 'http://127.0.0.1:9999/' || fail "GET / missing url link"

# 2. Start: systemd-run called with unit, workdir and exec argv.
post app '{"id":"sample","action":"start"}'
[ "$CODE" = "200" ] || fail "POST /app start expected 200, got $CODE"
grep -q '"ok": *true' "$TMPD/resp" || fail "POST /app start not ok: $(cat "$TMPD/resp")"
grep -qF '"unit": "hanare-app-sample"' "$TMPD/resp" || fail "POST /app start missing unit: $(cat "$TMPD/resp")"
grep -qF -- '--unit=hanare-app-sample' "$SR_LOG" || fail "systemd-run log missing --unit=hanare-app-sample"
grep -qF -- '--working-directory=/tmp/sample' "$SR_LOG" || fail "systemd-run log missing --working-directory"
grep -qF -- '-- /usr/bin/sample --flag quoted arg' "$SR_LOG" || fail "systemd-run log missing exec argv"

# 3. Already active: start returns already_running, no new systemd-run call.
echo "active" > "$STATE_FILE"
before="$(cat "$SR_LOG" 2>/dev/null || true)"
post app '{"id":"sample","action":"start"}'
[ "$CODE" = "200" ] || fail "POST /app start (active) expected 200, got $CODE"
grep -q '"already_running": *true' "$TMPD/resp" || fail "POST /app start (active) missing already_running: $(cat "$TMPD/resp")"
after="$(cat "$SR_LOG" 2>/dev/null || true)"
[ "$before" = "$after" ] || fail "systemd-run called again while already active"

# 4. Stop: systemctl stop called for the unit.
post app '{"id":"sample","action":"stop"}'
[ "$CODE" = "200" ] || fail "POST /app stop expected 200, got $CODE"
grep -q '"ok": *true' "$TMPD/resp" || fail "POST /app stop not ok: $(cat "$TMPD/resp")"
grep -qF -- '--user stop hanare-app-sample' "$SC_LOG" || fail "systemctl log missing 'stop hanare-app-sample'"

# 5. Unknown id -> 400.
post app '{"id":"nope","action":"start"}'
[ "$CODE" = "400" ] || fail "POST /app unknown id expected 400, got $CODE"
post app '{"id":"sample","action":"restart"}'
[ "$CODE" = "400" ] || fail "POST /app unknown action expected 400, got $CODE"

echo "PASS"
exit 0
