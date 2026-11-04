#!/usr/bin/env bash
# Task 007 test: systemd units for ComfyUI + llama core, model registry.
# Two modes:
#   local   - this machine has a real models/models.tsv and a real
#             systemd/hanare-comfyui.service: host files are checked too.
#   example - a fresh clone: structure and the shipped samples are checked.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_UNIT="$ROOT/systemd/hanare-llama.service"
RUNNER="$ROOT/scripts/hanare-llama-run.sh"
MODEL_CLI="$ROOT/scripts/hanare-model.sh"
INSTALL="$ROOT/setup/13-install-services.sh"

LOCAL=0
if [ -f "$ROOT/models/models.tsv" ] && [ -f "$ROOT/systemd/hanare-comfyui.service" ]; then
  LOCAL=1
  REGISTRY="$ROOT/models/models.tsv"
  COMFY_UNIT="$ROOT/systemd/hanare-comfyui.service"
else
  REGISTRY="$ROOT/models/models.tsv.example"
  COMFY_UNIT="$ROOT/systemd/hanare-comfyui.service.example"
fi
echo "mode: $([ "$LOCAL" = 1 ] && echo local || echo example)"

TMPD=""
cleanup() { [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"; }
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

TMPD="$(mktemp -d)" || fail "mktemp"

for f in "$COMFY_UNIT" "$LLAMA_UNIT" "$RUNNER" "$MODEL_CLI" "$REGISTRY" "$INSTALL"; do
  [ -f "$f" ] || fail "missing file: $f"
done

# 1. systemd-analyze verify: llama unit always; comfy unit only when local
#    (the example carries placeholder paths on purpose).
if command -v systemd-analyze >/dev/null 2>&1; then
  cp "$LLAMA_UNIT" "$TMPD/hanare-llama.service"
  systemd-analyze verify "$TMPD/hanare-llama.service" || fail "systemd-analyze verify (llama)"
  if [ "$LOCAL" = 1 ]; then
    cp "$COMFY_UNIT" "$TMPD/hanare-comfyui.service"
    systemd-analyze verify "$TMPD/hanare-comfyui.service" || fail "systemd-analyze verify (comfyui)"
  fi
else
  echo "note: systemd-analyze not found; skipping unit verification"
fi

# 2. Host binaries (local mode, paths from runtime/llama-env.sh when present).
if [ "$LOCAL" = 1 ] && [ -f "$ROOT/runtime/llama-env.sh" ]; then
  set -a; . "$ROOT/runtime/llama-env.sh"; set +a
  [ -x "${HANARE_LLAMA_SERVER:-}" ] || fail "llama-server binary missing: ${HANARE_LLAMA_SERVER:-unset}"
  [ -f "${HANARE_AGENT_DIR:-}/effort-proxy.py" ] || fail "effort-proxy.py missing in HANARE_AGENT_DIR"
  COMFY_WD="$(sed -n 's/^WorkingDirectory=//p' "$COMFY_UNIT" | head -n 1)"
  [ -f "$COMFY_WD/main.py" ] || fail "ComfyUI main.py missing under $COMFY_WD"
fi

# 3. Runner script markers.
grep -qF 'draft-mtp' "$RUNNER" || fail "runner missing draft-mtp marker"
grep -qF 'effort-proxy.py' "$RUNNER" || fail "runner missing effort-proxy.py marker"
grep -qF -- '--port 8081' "$RUNNER" || fail "runner missing --port 8081 marker"

# 3b. ComfyUI ExecStartPre (local only): no broken `test` syntax; payload parses.
if [ "$LOCAL" = 1 ]; then
  grep -qF -- '-d /mnt/HDD/ComfyUI/output -w' "$COMFY_UNIT" \
    && fail "comfyui unit contains broken test pattern (-d ... -w ...)"
  PRE_PAYLOAD="$(sed -n "s/^ExecStartPre=\/usr\/bin\/bash -c '\(.*\)'$/\1/p" "$COMFY_UNIT" | tail -n 1)"
  [ -n "$PRE_PAYLOAD" ] || fail "could not extract ExecStartPre bash -c payload"
  bash -n <<<"$PRE_PAYLOAD" || fail "ExecStartPre payload fails bash -n"
fi

# 4. Registry structure: header + at least one row; in local mode every
#    referenced file (gguf / mmproj / draft) must exist.
[ "$(head -n 1 "$REGISTRY" | cut -f1)" = "name" ] || fail "registry header missing"
ROWS="$(tail -n +2 "$REGISTRY" | grep -c .)"
[ "$ROWS" -ge 1 ] || fail "registry has no model rows"
if [ "$LOCAL" = 1 ]; then
  while IFS=$'\t' read -r name gguf mmproj ctx profile note draft; do
    [ -n "$name" ] || continue
    [ -f "$gguf" ] || fail "registry gguf missing on host: $gguf"
    [ "$mmproj" = "-" ] || [ -f "$mmproj" ] || fail "registry mmproj missing on host: $mmproj"
    [ -z "${draft:-}" ] || [ "$draft" = "-" ] || [ -f "$draft" ] || fail "registry draft missing on host: $draft"
  done < <(tail -n +2 "$REGISTRY")
fi

# 5. Model CLI round-trip (local mode only; uses the first registry row).
if [ "$LOCAL" = 1 ]; then
  FIRST_MODEL="$(awk -F'\t' '$1 != "name" && NF >= 2 { print $1; exit }' "$REGISTRY")"
  [ -n "$FIRST_MODEL" ] || fail "no first model in registry"
  export HANARE_CURRENT_MODEL="$TMPD/current-model"
  bash "$MODEL_CLI" use "$FIRST_MODEL" >/dev/null 2>&1 || fail "model CLI use $FIRST_MODEL failed"
  [ "$(bash "$MODEL_CLI" current)" = "$FIRST_MODEL" ] || fail "model CLI current mismatch"
  bash "$MODEL_CLI" list | grep -q "^\* $FIRST_MODEL" || fail "model CLI list does not mark current"
  bash "$MODEL_CLI" use no-such-model >/dev/null 2>&1
  [ $? -eq 2 ] || fail "model CLI use no-such-model should exit 2"
fi

# 6. Install script: no sudo, no enable.
grep -q 'sudo' "$INSTALL" && fail "install script uses sudo"
grep -q 'enable' "$INSTALL" && fail "install script enables units"
grep -qF 'runtime/logs' "$INSTALL" || fail "install script does not create runtime/logs"

echo "PASS"
exit 0
