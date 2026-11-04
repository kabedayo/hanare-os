#!/usr/bin/env bash
# Task 006 test: top-bar HANARE indicator (static + syntax checks only).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$ROOT/topbar/extension.js"
META="$ROOT/topbar/metadata.json"
INSTALL="$ROOT/setup/12-install-topbar.sh"

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
[ -f "$INSTALL" ] || fail

# 1. Existing behaviour markers are preserved.
grep -qF 'nvidia-smi' "$EXT" || fail
grep -qF 'UPDATE_SECONDS' "$EXT" || fail

# 2. New HANARE behaviour markers.
for marker in \
  'last-status.json' \
  'events.jsonl' \
  "'center'" \
  'HANARE' \
  'ダッシュボードを開く' \
  '127.0.0.1:8790' \
  '#f85149' \
  '#d29922' \
  '#58a34c' \
  '#8a8a8a'
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

# 4. metadata.json parses and has version >= 2.
python3 - "$META" <<'PYEOF' || fail
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    meta = json.load(f)
assert isinstance(meta.get("version"), int) and meta["version"] >= 2, \
    "metadata version is not >= 2"
PYEOF

# 5. Install script exists, references the extensions dir, no sudo.
grep -qF '.local/share/gnome-shell/extensions' "$INSTALL" || fail
if grep -q 'sudo' "$INSTALL"; then
  fail
fi

echo "PASS"
exit 0
