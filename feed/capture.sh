#!/usr/bin/env bash
# HANARE capture: compare the current status snapshot with the previous one
# and emit events for state changes (plus a llama-server metric event).
# Usage: capture.sh [interval-sec]
# The interval argument is accepted for a future loop mode; this version
# performs exactly ONE capture pass and exits 0.
# Env: HANARE_STATUS_SNAP overrides the snapshot path
#      (default: runtime/last-status.json relative to the repo root).
#      HANARE_STATUS_INPUT, when set, is read as the current snapshot
#      instead of running status/status.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SNAP="${HANARE_STATUS_SNAP:-$ROOT/runtime/last-status.json}"
mkdir -p "$(dirname "$SNAP")" || exit 1

# Serialize capture passes: the 60 s timer, the panel and the
# dashboard can all trigger a capture, and two concurrent passes
# would race on the snapshot file and double-emit events. Wait for
# a running pass to finish (a pass takes well under a second); if
# the lock cannot be had in 30 s, skip this pass -- the snapshot is
# being refreshed by whoever holds the lock.
LOCK="${HANARE_CAPTURE_LOCK:-$(dirname "$SNAP")/capture.lock}"
exec 9>"$LOCK" || exit 1
if ! flock -w 30 9; then
  exit 0
fi

if [ -n "${HANARE_STATUS_INPUT:-}" ]; then
  CUR="$(cat "$HANARE_STATUS_INPUT" 2>/dev/null)" || exit 1
else
  CUR="$(bash "$ROOT/status/status.sh" --json 2>/dev/null)"
fi
[ -n "$CUR" ] || exit 1

while IFS=$'\t' read -r k a n d; do
  [ -n "$k" ] || continue
  bash "$SCRIPT_DIR/hanare-event.sh" "$k" "$a" "$n" "$d" >/dev/null || exit 1
done < <(printf '%s' "$CUR" | python3 -c '
import json, sys
snap_path = sys.argv[1]
cur = json.load(sys.stdin)
try:
    with open(snap_path) as f:
        prev = {s["name"]: s.get("state") for s in json.load(f).get("services", [])}
except Exception:
    prev = {}
events = []
for s in cur.get("services", []):
    name = s.get("name")
    new = s.get("state")
    if name is not None and name in prev and prev[name] != new:
        events.append(("service", "hanare-capture", name,
                       json.dumps({"from": prev[name], "to": new})))
llama = next((s for s in cur.get("services", []) if s.get("name") == "llama-server"), None)
if llama is not None and llama.get("pid") is not None:
    gpus = cur.get("gpus") or []
    vram = gpus[0].get("memory_used_mib") if gpus else None
    ram = (cur.get("memory") or {}).get("ram_used_mib")
    events.append(("metric", "hanare-capture", "llama-server",
                   json.dumps({"vram_mib": vram, "ram_used_mib": ram})))
for e in events:
    print("\t".join(e))
' "$SNAP") || exit 1

printf '%s\n' "$CUR" > "$SNAP" || exit 1
exit 0
