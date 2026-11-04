#!/usr/bin/env bash
# Task 011 test: discovery wired into the dashboard (登録 / 自動検出 / ランチャー).
# Uses stub systemctl / systemd-run so no real services are touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASH="$ROOT/dashboard/dashboard.py"
PORT="${HANARE_TEST_PORT:-8993}"
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
DROP_DIR="$TMPD/drop"
DESK_DIR="$TMPD/desktop"
mkdir -p "$APPS_DIR" "$DROP_DIR" "$DESK_DIR"
echo "inactive" > "$STATE_FILE"

cat > "$APPS_DIR/story.app" <<'EOF'
name=Story App
exec=/opt/story/run.sh --serve
url=http://127.0.0.1:8765/
note=manual app
EOF

mkdir -p "$DROP_DIR/mytool"
cat > "$DROP_DIR/mytool/run.sh" <<'EOF'
#!/bin/sh
echo run
EOF
chmod +x "$DROP_DIR/mytool/run.sh"

cat > "$DESK_DIR/browser.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Web Browser
Exec=/usr/bin/browser %U
EOF

cat > "$DROP_DIR/browser.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Web Browser
Exec=/usr/bin/browser %U
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
  HANARE_APPS_DROP_DIR="$DROP_DIR" \
  HANARE_DESKTOP_DIRS="$DESK_DIR" \
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

# 1. GET / lists all three sources with their source tags.
body="$(curl -s "$BASE/")"
echo "$body" | grep -qF 'Story App（登録）' || fail "GET / missing 'Story App（登録）'"
echo "$body" | grep -qF 'mytool（自動検出）' || fail "GET / missing 'mytool（自動検出）'"
echo "$body" | grep -qF 'Web Browser（ランチャー）' && fail "GET / must not list launcher apps by default"
echo "$body" | grep -qF 'Web Browser（自動検出）' || fail "GET / missing 'Web Browser（自動検出）' from drop folder"


# 2. Start the drop folder app: systemd-run gets its run.sh.
post app '{"id":"mytool","action":"start"}'
[ "$CODE" = "200" ] || fail "POST /app start (mytool) expected 200, got $CODE"
grep -q '"ok": *true' "$TMPD/resp" || fail "POST /app start (mytool) not ok: $(cat "$TMPD/resp")"
grep -qF -- '--unit=hanare-app-mytool' "$SR_LOG" || fail "systemd-run log missing --unit=hanare-app-mytool"
grep -qF -- "$DROP_DIR/mytool/run.sh" "$SR_LOG" || fail "systemd-run log missing drop folder run.sh"

# 3. Start the drop-folder .desktop app: argv contains no % field codes.
post app '{"id":"browser","action":"start"}'
[ "$CODE" = "200" ] || fail "POST /app start (browser) expected 200, got $CODE"
grep -q '"ok": *true' "$TMPD/resp" || fail "POST /app start (browser) not ok: $(cat "$TMPD/resp")"
brow_line="$(grep -F '/usr/bin/browser' "$SR_LOG" 2>/dev/null | tail -n 1)"
[ -n "$brow_line" ] || fail "systemd-run log missing browser argv"
case "$brow_line" in
  *'%'*) fail "browser argv still contains %: $brow_line" ;;
esac

echo "PASS"
exit 0
