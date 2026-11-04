#!/usr/bin/env bash
# Task 002 test: status/status.sh + services/services.tsv
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD=""
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
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

# 1. --json output parses and has required keys
out="$(bash "$ROOT/status/status.sh" --json 2>/dev/null)" || fail
printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1 || fail
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("timestamp", "gpus", "memory", "services"):
    assert k in d, "missing key: " + k
' >/dev/null 2>&1 || fail

# 2. dummy server on 18999 from a temp dir + temp registry copy
mkdir -p "$TMPD/www" || fail
( cd "$TMPD" && exec python3 -m http.server 18999 --bind 127.0.0.1 ) &
SERVER_PID=$!

ready=0
for _ in $(seq 1 100); do
  if curl -s -o /dev/null -m 1 http://127.0.0.1:18999/ 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" = 1 ] || fail

cp "$ROOT/services/services.tsv" "$TMPD/services.tsv" || fail
printf 'dummy\t18999\tNone\n' >> "$TMPD/services.tsv" || fail
printf 'stoppedsvc\t18998\tNone\n' >> "$TMPD/services.tsv" || fail

# 2+3. dummy => running, unused port 18998 => stopped
out2="$(HANARE_SERVICES_TSV="$TMPD/services.tsv" bash "$ROOT/status/status.sh" --json 2>/dev/null)" || fail
printf '%s' "$out2" | python3 -c '
import json, sys
d = json.load(sys.stdin)
svc = {s["name"]: s for s in d["services"]}
assert "dummy" in svc and svc["dummy"]["state"] == "running", svc.get("dummy")
assert "stoppedsvc" in svc and svc["stoppedsvc"]["state"] == "stopped", svc.get("stoppedsvc")
' >/dev/null 2>&1 || fail

echo "PASS"
exit 0
