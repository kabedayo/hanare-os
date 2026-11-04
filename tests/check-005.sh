#!/usr/bin/env bash
# Task 005 test: read-only dashboard (temp files + test port only).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=18991
TMPD=""
SRV_PID=""

cleanup() {
  if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
    kill "$SRV_PID" 2>/dev/null
    wait "$SRV_PID" 2>/dev/null
  fi
  if [ -n "$TMPD" ] && [ -d "$TMPD" ]; then
    rm -rf "$TMPD"
  fi
}
trap cleanup EXIT

fail() {
  echo "FAIL"
  exit 1
}

TMPD="$(mktemp -d)" || fail

cat > "$TMPD/last-status.json" <<'EOF'
{
  "timestamp": "2026-11-02T12:00:00+0900",
  "gpus": [
    {"index": 0, "name": "Fake GPU 0", "utilization": 42, "memory_used_mib": 1000, "memory_total_mib": 8192}
  ],
  "gpu_processes": [
    {"pid": 1234, "name": "fake-proc", "memory_mib": 900}
  ],
  "memory": {"ram_total_mib": 8000, "ram_used_mib": 2000, "swap_total_mib": 4096, "swap_used_mib": 0},
  "services": [
    {"name": "llama-server", "port": 8080, "state": "running"},
    {"name": "comfyui", "port": 8188, "state": "stuck-suspect"}
  ]
}
EOF

cat > "$TMPD/events.jsonl" <<'EOF'
{"ts": "2026-11-02T11:59:00+0900", "kind": "metric", "actor": "check-005-actor", "name": "llama-server", "detail": {"vram_mib": 1000}}
{"ts": "2026-11-02T11:59:30+0900", "kind": "inference", "actor": "check-005-actor", "name": "fake-model", "detail": {"tokens": 16}}
EOF

HANARE_DASH_PORT="$PORT" \
HANARE_STATUS_SNAP="$TMPD/last-status.json" \
HANARE_EVENT_LOG="$TMPD/events.jsonl" \
python3 "$ROOT/dashboard/dashboard.py" 2>"$TMPD/server.log" &
SRV_PID=$!

# Wait until the server responds (up to ~10s).
ready=0
for _ in $(seq 1 50); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)" || code=""
  if [ "$code" = "200" ]; then
    ready=1
    break
  fi
  sleep 0.2
done
[ "$ready" = "1" ] || fail

# 1. GET / returns 200 with expected content.
body="$(curl -s "http://127.0.0.1:$PORT/")" || fail
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")" || fail
[ "$code" = "200" ] || fail
echo "$body" | grep -q 'llama-server' || fail
echo "$body" | grep -q 'stuck-suspect' || fail
echo "$body" | grep -q 'check-005-actor' || fail

# 2. Controls present on the page (Task 009: dashboard is no longer read-only).
echo "$body" | grep -q '<button' || fail
echo "$body" | grep -qF '起動' || fail

# 3. POST to / (not an action path) is rejected.
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/")" || fail
[ "$code" = "404" ] || fail

# 4. Other paths are 404.
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/nope")" || fail
[ "$code" = "404" ] || fail

echo "PASS"
exit 0
