#!/usr/bin/env bash
# Task 009 test: dashboard controls (start/stop/restart + model select).
# Uses stub systemctl / model CLI so no real services are touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASH="$ROOT/dashboard/dashboard.py"
PORT="${HANARE_TEST_PORT:-8991}"
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
MD_LOG="$TMPD/model.log"

cat > "$TMPD/stub-systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SC_LOG"
exit 0
EOF
cat > "$TMPD/stub-model" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$MD_LOG"
echo "ok"
exit 0
EOF
chmod +x "$TMPD/stub-systemctl" "$TMPD/stub-model"

HANARE_DASH_PORT="$PORT" \
  HANARE_SYSTEMCTL="$TMPD/stub-systemctl" \
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

# 1. GET / renders controls and model section.
body="$(curl -s "$BASE/")"
echo "$body" | grep -qF '起動' || fail "GET / missing 起動"
echo "$body" | grep -qF '停止' || fail "GET / missing 停止"
echo "$body" | grep -qF '再起動' || fail "GET / missing 再起動"
echo "$body" | grep -qF 'モデル' || fail "GET / missing モデル"

# 2. Valid action: ok + stub log shows the exact argv.
post action '{"service":"comfyui","action":"start"}'
[ "$CODE" = "200" ] || fail "POST /action comfyui start expected 200, got $CODE"
grep -q '"ok": *true' "$TMPD/resp" || fail "POST /action start not ok: $(cat "$TMPD/resp")"
grep -qF '"unit": "hanare-comfyui"' "$TMPD/resp" || fail "POST /action missing unit: $(cat "$TMPD/resp")"
grep -qF -- '--user start hanare-comfyui' "$SC_LOG" || fail "stub log missing '--user start hanare-comfyui'"

# 3. Invalid service / action -> 400, stub log unchanged.
before="$(cat "$SC_LOG" 2>/dev/null || true)"
post action '{"service":"evil","action":"start"}'
[ "$CODE" = "400" ] || fail "POST /action evil service expected 400, got $CODE"
post action '{"service":"comfyui","action":"enable"}'
[ "$CODE" = "400" ] || fail "POST /action enable expected 400, got $CODE"
post action 'not-json'
[ "$CODE" = "400" ] || fail "POST /action non-JSON expected 400, got $CODE"
after="$(cat "$SC_LOG" 2>/dev/null || true)"
[ "$before" = "$after" ] || fail "stub systemctl log changed on invalid input"

# 4. Model select: stub called with 'use <name>', response ok + current.
post model '{"name":"gemma4"}'
[ "$CODE" = "200" ] || fail "POST /model expected 200, got $CODE"
grep -q '"ok": *true' "$TMPD/resp" || fail "POST /model not ok: $(cat "$TMPD/resp")"
grep -qF '"current": "gemma4"' "$TMPD/resp" || fail "POST /model missing current: $(cat "$TMPD/resp")"
grep -qF 'use gemma4' "$MD_LOG" || fail "model stub log missing 'use gemma4'"
post model '{"name":""}'
[ "$CODE" = "400" ] || fail "POST /model empty name expected 400, got $CODE"

# 5. Routing: POST other path -> 404; GET /action, /model -> 405.
post nope '{}'
[ "$CODE" = "404" ] || fail "POST /nope expected 404, got $CODE"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/action")" = "405" ] || fail "GET /action expected 405"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/model")" = "405" ] || fail "GET /model expected 405"

echo "PASS"
exit 0
