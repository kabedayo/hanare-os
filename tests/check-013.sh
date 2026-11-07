#!/usr/bin/env bash
# Task 013 test: stop-external. A managed service started outside its
# systemd unit must still be stoppable ("cannot stop the LLM" bug), and
# the UIs must mark such a service as externally managed （管理外）.
# Ports are picked at random per run so leftovers from earlier runs
# (or parallel work) can never collide with this test.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/hanare-service.sh"
DASH="$ROOT/dashboard/dashboard.py"
PANEL="$ROOT/panel/hanare-panel.py"

free_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}
PORT_L="$(free_port)"
PORT_INTERNAL="$(free_port)"
PORT_COMFY="$(free_port)"
DASH_PORT="$(free_port)"

TMPD=""
PIDS=""
DASH_PID=""
cleanup() {
  [ -n "$DASH_PID" ] && kill "$DASH_PID" 2>/dev/null
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

[ -f "$HELPER" ] || fail "missing hanare-service.sh"
bash -n "$HELPER" || fail "helper does not parse"
TMPD="$(mktemp -d)" || fail "mktemp"

printf 'llama-server\t%s\tNone\ncomfyui\t%s\tNone\n' "$PORT_L" "$PORT_COMFY" > "$TMPD/services.tsv"
export HANARE_SERVICES_TSV="$TMPD/services.tsv"
export HANARE_LLAMA_INTERNAL_PORT="$PORT_INTERNAL"

LAST_PID=""
listener() { # listener <port> [marker-arg]; sets LAST_PID
  python3 -c 'import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
time.sleep(60)' "$@" &
  LAST_PID=$!
  PIDS="$PIDS $LAST_PID"
}

verify_listener() { # verify_listener <pid> <port>: my process owns the port
  for _ in $(seq 1 50); do
    kill -0 "$1" 2>/dev/null || return 1
    if ss -tlnp 2>/dev/null | grep -q "pid=$1,"; then
      ss -tlnp 2>/dev/null | grep -E ":$2 .*pid=$1," >/dev/null && return 0
    fi
    sleep 0.1
  done
  return 1
}

# --- helper: matching external listener is stopped ---------------------
( exec -a llama-server sleep 60 ) &
DECOY=$!
PIDS="$PIDS $DECOY"

listener "$PORT_L" llama-server
LPID="$LAST_PID"
verify_listener "$LPID" "$PORT_L" || fail "dummy listener did not start (or port collision)"
out="$(bash "$HELPER" stop-external llama-server 2>&1)"
rc=$?
[ "$rc" = 0 ] || fail "helper exit $rc (want 0): $out"
kill -0 "$LPID" 2>/dev/null && fail "matching listener still alive"
kill -0 "$DECOY" 2>/dev/null || fail "decoy (non-listener) was killed"

# --- helper: nothing left -> exit 3 ------------------------------------
bash "$HELPER" stop-external llama-server >/dev/null 2>&1
[ $? = 3 ] || fail "helper should exit 3 when nothing is external"

# --- helper: unidentified listener -> refuse (4), process untouched ----
listener "$PORT_L"
LPID2="$LAST_PID"
verify_listener "$LPID2" "$PORT_L" || fail "plain listener did not start (or port collision)"
bash "$HELPER" stop-external llama-server >/dev/null 2>&1
[ $? = 4 ] || fail "helper should refuse (4) an unidentified listener"
kill -0 "$LPID2" 2>/dev/null || fail "unidentified listener was killed"
kill "$LPID2" 2>/dev/null

# --- helper: unknown service -> exit 2 ---------------------------------
bash "$HELPER" stop-external nope >/dev/null 2>&1
[ $? = 2 ] || fail "helper should exit 2 for an unknown service"

# --- dashboard: stop also reaps; badge marks the external service ------
cat > "$TMPD/stub-systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMPD/systemctl.log"
echo inactive
exit 0
EOF
cat > "$TMPD/stub-service" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMPD/service.log"
echo "stopped external llama-server pid=4242"
exit 0
EOF
chmod +x "$TMPD/stub-systemctl" "$TMPD/stub-service"
cat > "$TMPD/snap.json" <<'EOF'
{"timestamp": "2026-11-05T10:00:00+0900", "gpus": [], "memory": {},
 "services": [
   {"name": "llama-server", "state": "running", "port": 8080, "pid": 4242},
   {"name": "comfyui", "state": "stopped", "port": 8188, "pid": null}]}
EOF

HANARE_DASH_PORT="$DASH_PORT" \
  HANARE_SYSTEMCTL="$TMPD/stub-systemctl" \
  HANARE_SERVICE_CLI="$TMPD/stub-service" \
  HANARE_CAPTURE_CLI=/bin/true \
  HANARE_STATUS_SNAP="$TMPD/snap.json" \
  python3 "$DASH" >"$TMPD/dash.log" 2>&1 &
DASH_PID=$!
ok=0
for _ in $(seq 1 50); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DASH_PORT/" 2>/dev/null || true)"
  [ "$code" = "200" ] && { ok=1; break; }
  sleep 0.2
done
[ "$ok" = 1 ] || fail "dashboard did not start (see $TMPD/dash.log)"

body="$(curl -s "http://127.0.0.1:$DASH_PORT/")"
printf '%s' "$body" | grep -qF '管理外</span>' || fail "dashboard does not badge the external service"

resp="$(curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"service": "llama-server", "action": "stop"}' \
  "http://127.0.0.1:$DASH_PORT/action")"
printf '%s' "$resp" | grep -qF '"result": "stopped"' || fail "stop response lacks external result: $resp"
grep -qF -- '--user stop hanare-llama' "$TMPD/systemctl.log" || fail "unit stop not called"
grep -qF 'stop-external llama-server' "$TMPD/service.log" || fail "stop-external not called"
kill "$DASH_PID" 2>/dev/null; DASH_PID=""

# --- panel: --dump flags the external service --------------------------
mkdir -p "$TMPD/repo/runtime" "$TMPD/repo/models" "$TMPD/repo/apps" "$TMPD/repo/drop"
ln -s "$ROOT/dashboard" "$TMPD/repo/dashboard"
cp "$TMPD/snap.json" "$TMPD/repo/runtime/last-status.json"
printf 'name\tgguf_path\tmmproj_path\tctx\tprofile\tnote\tdraft_path\nm\t/m/m.gguf\t-\t1024\tgeneric\tt\t-\n' > "$TMPD/repo/models/models.tsv"

HANARE_REPO="$TMPD/repo" HANARE_APPS_DIR="$TMPD/repo/apps" \
HANARE_APPS_DROP_DIR="$TMPD/repo/drop" HANARE_SYSTEMCTL="$TMPD/stub-systemctl" \
  python3 "$PANEL" --dump > "$TMPD/dump.json" || fail "panel --dump failed"
python3 - "$TMPD/dump.json" <<'EOF' || fail "panel dump: llama-server should be external"
import json, sys
d = json.load(open(sys.argv[1]))
svc = {s["name"]: s for s in d["services"]}
assert svc["llama-server"].get("external") is True, svc["llama-server"]
assert svc["comfyui"].get("external") is False, svc["comfyui"]
EOF

cat > "$TMPD/stub-systemctl-active" <<'EOF'
#!/bin/sh
echo active
exit 0
EOF
chmod +x "$TMPD/stub-systemctl-active"
HANARE_REPO="$TMPD/repo" HANARE_APPS_DIR="$TMPD/repo/apps" \
HANARE_APPS_DROP_DIR="$TMPD/repo/drop" HANARE_SYSTEMCTL="$TMPD/stub-systemctl-active" \
  python3 "$PANEL" --dump > "$TMPD/dump2.json" || fail "panel --dump (active) failed"
python3 - "$TMPD/dump2.json" <<'EOF' || fail "panel dump: unit-managed service must not be external"
import json, sys
d = json.load(open(sys.argv[1]))
svc = {s["name"]: s for s in d["services"]}
assert svc["llama-server"].get("external") is False, svc["llama-server"]
EOF

echo "PASS"
exit 0
