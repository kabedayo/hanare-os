#!/usr/bin/env bash
# Task 003 test: feed/hanare-event.sh + feed/capture.sh
# Works only inside a temp dir; never touches the real runtime/ files.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD=""
EVENT_LOG=""
SNAP=""

cleanup() {
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
EVENT_LOG="$TMPD/events.jsonl"
SNAP="$TMPD/last-status.json"

# 1. hanare-event.sh with a JSON detail
HANARE_EVENT_LOG="$EVENT_LOG" bash "$ROOT/feed/hanare-event.sh" service hanare-test "my-svc" '{"a":1,"b":"two"}' >"$TMPD/out1" 2>&1 || fail
[ "$(wc -l < "$EVENT_LOG")" -eq 1 ] || fail
python3 - "$EVENT_LOG" <<'PYEOF' || fail
import json, sys
lines = open(sys.argv[1]).read().splitlines()
assert len(lines) == 1, lines
d = json.loads(lines[0])
for k in ("ts", "kind", "actor", "name", "detail"):
    assert k in d, "missing key: " + k
assert d["kind"] == "service", d
assert d["actor"] == "hanare-test", d
assert d["name"] == "my-svc", d
assert d["detail"] == {"a": 1, "b": "two"}, d
PYEOF

# 2. hanare-event.sh with an empty actor: exit 2, nothing appended
HANARE_EVENT_LOG="$EVENT_LOG" bash "$ROOT/feed/hanare-event.sh" service "" "x" "y" 2>/dev/null
[ $? -eq 2 ] || fail
[ "$(wc -l < "$EVENT_LOG")" -eq 1 ] || fail

# 3. capture.sh comparison with two fake snapshots
cat > "$TMPD/snap1.json" <<'EOF'
{"timestamp":"2026-11-02T00:00:00+0000","gpus":[{"index":0,"name":"Tesla V100","utilization":50,"memory_used_mib":10000,"memory_total_mib":16384}],"gpu_processes":[],"memory":{"ram_total_mib":32768,"ram_used_mib":8192,"swap_total_mib":0,"swap_used_mib":0},"services":[{"name":"llama-server","port":8080,"gpu_keyword":"llama","state":"running","pid":1234,"rss_kib":100000,"cpu_percent":1.0,"elapsed_sec":100,"start_time":null,"port_responds":1},{"name":"comfyui","port":8188,"gpu_keyword":"comfyui","state":"stopped","pid":null,"rss_kib":null,"cpu_percent":null,"elapsed_sec":null,"start_time":null,"port_responds":0}]}
EOF
cat > "$TMPD/snap2.json" <<'EOF'
{"timestamp":"2026-11-02T00:01:00+0000","gpus":[{"index":0,"name":"Tesla V100","utilization":50,"memory_used_mib":10000,"memory_total_mib":16384}],"gpu_processes":[],"memory":{"ram_total_mib":32768,"ram_used_mib":8192,"swap_total_mib":0,"swap_used_mib":0},"services":[{"name":"llama-server","port":8080,"gpu_keyword":"llama","state":"running","pid":1234,"rss_kib":100000,"cpu_percent":1.0,"elapsed_sec":160,"start_time":null,"port_responds":1},{"name":"comfyui","port":8188,"gpu_keyword":"comfyui","state":"running","pid":5678,"rss_kib":50000,"cpu_percent":0.5,"elapsed_sec":50,"start_time":null,"port_responds":1}]}
EOF

cp "$TMPD/snap1.json" "$SNAP" || fail
rm -f "$EVENT_LOG"
HANARE_STATUS_SNAP="$SNAP" HANARE_STATUS_INPUT="$TMPD/snap2.json" \
  HANARE_EVENT_LOG="$EVENT_LOG" bash "$ROOT/feed/capture.sh" 60 >"$TMPD/out3" 2>&1 || fail
[ -f "$EVENT_LOG" ] || fail
python3 - "$EVENT_LOG" <<'PYEOF' || fail
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]).read().splitlines()]
svc = [e for e in events if e["kind"] == "service"]
assert len(svc) == 1, svc
assert svc[0]["name"] == "comfyui", svc
assert svc[0]["actor"] == "hanare-capture", svc
assert svc[0]["detail"] == {"from": "stopped", "to": "running"}, svc
metric = [e for e in events if e["kind"] == "metric" and e["name"] == "llama-server"]
assert len(metric) == 1, events
assert metric[0]["detail"]["vram_mib"] == 10000, metric
assert metric[0]["detail"]["ram_used_mib"] == 8192, metric
PYEOF
# snapshot must have been overwritten with the new one
cmp -s "$SNAP" "$TMPD/snap2.json" || fail

echo "PASS"
exit 0
