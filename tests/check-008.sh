#!/usr/bin/env bash
# Task 008 test: topbar menu controls (static + syntax checks only).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$ROOT/topbar/extension.js"
META="$ROOT/topbar/metadata.json"

TMPD=""
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

[ -f "$EXT" ] || fail
[ -f "$META" ] || fail

# 1. Task 006 + VRAM markers are preserved.
for marker in \
  'last-status.json' \
  "'center'" \
  'HANARE' \
  'nvidia-smi'
do
  grep -qF -- "$marker" "$EXT" || fail
done

# 2. New Task 008 markers.
for marker in \
  'models.tsv' \
  'current-model' \
  'hanare-llama.service' \
  'replace_contents' \
  'systemctl' \
  '--user' \
  'restart' \
  'hanare-comfyui' \
  'hanare-llama'
do
  grep -qF -- "$marker" "$EXT" || fail
done

# 3. Syntax check with node if available.
NODE_BIN=""
if command -v node >/dev/null 2>&1; then
  NODE_BIN="$(command -v node)"
elif [ -x "${HOME}/llama.cpp/qwen38-agent/node/bin/node" ]; then
  NODE_BIN="${HOME}/llama.cpp/qwen38-agent/node/bin/node"
fi
if [ -n "$NODE_BIN" ]; then
  cp "$EXT" "$TMPD/extension.mjs" || fail
  "$NODE_BIN" --check "$TMPD/extension.mjs" || fail
else
  echo "note: node not found; skipping syntax check"
fi

# 4. metadata.json parses and has version 3.
python3 - "$META" <<'PYEOF' || fail
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    meta = json.load(f)
assert meta.get("version") == 3, "metadata version is not 3"
PYEOF

echo "PASS"
exit 0
