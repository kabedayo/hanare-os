#!/usr/bin/env bash
# HANARE event logger. Appends exactly one JSON line to the event log and
# prints it to stdout.
# Usage: hanare-event.sh <kind> <actor> <name> <detail-json-or-string>
# Env: HANARE_EVENT_LOG overrides the log path (default: runtime/events.jsonl
# relative to the repo root).
set -u

if [ "$#" -lt 4 ] || [ -z "${2:-}" ]; then
  echo "usage: hanare-event.sh <kind> <actor> <name> <detail-json-or-string>" >&2
  exit 2
fi

kind=$1
actor=$2
name=$3
detail=$4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG="${HANARE_EVENT_LOG:-$ROOT/runtime/events.jsonl}"
mkdir -p "$(dirname "$LOG")" || exit 1

TS="$(date +%Y-%m-%dT%H:%M:%S%z)"

line="$(python3 - "$kind" "$actor" "$name" "$detail" "$TS" <<'EOF'
import json, sys
kind, actor, name, detail, ts = sys.argv[1:6]
try:
    d = json.loads(detail)
except Exception:
    d = detail
print(json.dumps({"ts": ts, "kind": kind, "actor": actor, "name": name, "detail": d}))
EOF
)" || exit 1

printf '%s\n' "$line" >> "$LOG" || exit 1
printf '%s\n' "$line"
exit 0
