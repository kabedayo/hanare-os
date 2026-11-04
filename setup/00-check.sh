#!/usr/bin/env bash
# HANARE v0.1 reference-environment check (read-only).
# Reports each item as OK / WARN / NG. Exit 1 if any item is NG, else 0.
# With --json, prints exactly one JSON object on stdout and nothing else.
set -u

JSON=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
  esac
done

NG=0
WARN=0

report() {
  local status=$1
  shift
  case "$status" in
    NG) NG=$((NG + 1)) ;;
    WARN) WARN=$((WARN + 1)) ;;
  esac
  if [ "$JSON" -eq 0 ]; then
    printf '[%s] %s\n' "$status" "$*"
  fi
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# --- 1. OS: Ubuntu 24.04 -----------------------------------------------------
OS="unknown"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS="${PRETTY_NAME:-unknown}"
  if [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ]; then
    report OK "OS: ${OS} (matches reference)"
  else
    report NG "OS: ${OS} (expected Ubuntu 24.04)"
  fi
else
  report NG "OS: /etc/os-release not readable"
fi

# --- 2-4. GPUs and NVIDIA driver --------------------------------------------
GPU_NAMES=()
GPU_MEM=()
DRIVER="unknown"
if command -v nvidia-smi >/dev/null 2>&1; then
  if csv=$(nvidia-smi --query-gpu=name,memory.total,driver_version \
      --format=csv,noheader,nounits 2>/dev/null); then
    while IFS=, read -r name mem drv; do
      [ -n "${name:-}" ] || continue
      GPU_NAMES+=("$(trim "$name")")
      GPU_MEM+=("$(trim "$mem")")
      DRIVER="$(trim "$drv")"
    done <<< "$csv"
  else
    report NG "nvidia-smi present but failed to query GPUs"
  fi
else
  report NG "nvidia-smi: command not found"
fi

GPU_COUNT=${#GPU_NAMES[@]}
if [ "$GPU_COUNT" -eq 0 ]; then
  report NG "GPUs: none listed"
elif [ "$GPU_COUNT" -eq 1 ]; then
  report NG "GPUs: only 1 GPU (${GPU_NAMES[0]}); the reference environment requires 2 or more (one for the human side, one for the AI side)"
else
  report OK "GPUs: ${GPU_COUNT} found"
  for i in "${!GPU_NAMES[@]}"; do
    report OK "  GPU ${i}: ${GPU_NAMES[$i]} (${GPU_MEM[$i]} MiB)"
  done
fi

if [ "$DRIVER" = "unknown" ]; then
  report WARN "NVIDIA driver: version unknown"
else
  report OK "NVIDIA driver: ${DRIVER}"
fi

# --- 5. Disk space ------------------------------------------------------------
ROOT_FREE_GIB="null"
if avail_kb=$(df -k --output=avail / 2>/dev/null | tail -n 1 | tr -d '[:space:]'); then
  if [ -n "$avail_kb" ] && [ "$avail_kb" -gt 0 ] 2>/dev/null; then
    ROOT_FREE_GIB=$((avail_kb / 1048576))
    report OK "Root filesystem free: ${ROOT_FREE_GIB} GiB"
  else
    report NG "Root filesystem: could not determine free space"
  fi
else
  report NG "Root filesystem: df failed"
fi

DATA_EXISTS=false
DATA_FREE_GIB="null"
if [ -d /mnt/HDD ]; then
  DATA_EXISTS=true
  if avail_kb=$(df -k --output=avail /mnt/HDD 2>/dev/null | tail -n 1 | tr -d '[:space:]'); then
    if [ -n "$avail_kb" ] && [ "$avail_kb" -gt 0 ] 2>/dev/null; then
      DATA_FREE_GIB=$((avail_kb / 1048576))
      report OK "/mnt/HDD: present, ${DATA_FREE_GIB} GiB free"
    else
      report NG "/mnt/HDD: present but free space could not be determined"
    fi
  else
    report NG "/mnt/HDD: present but df failed"
  fi
else
  report WARN "/mnt/HDD: does not exist"
fi

# --- 6. systemctl --------------------------------------------------------------
SYSTEMD=false
if command -v systemctl >/dev/null 2>&1; then
  SYSTEMD=true
  report OK "systemctl: available"
else
  report WARN "systemctl: command not found"
fi

# --- Output --------------------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  GPUS_JSON=""
  if [ "$GPU_COUNT" -gt 0 ]; then
    for i in "${!GPU_NAMES[@]}"; do
      [ -n "$GPUS_JSON" ] && GPUS_JSON+=", "
      GPUS_JSON+=$(printf '{"name": "%s", "memory_mib": %s}' \
        "$(json_escape "${GPU_NAMES[$i]}")" "${GPU_MEM[$i]}")
    done
  fi
  if [ "$NG" -gt 0 ]; then
    OK=false
  else
    OK=true
  fi
  printf '{"os": "%s", "gpus": [%s], "driver": "%s", "root_free_gib": %s, "data_disk": {"exists": %s, "free_gib": %s}, "systemd": %s, "ok": %s}\n' \
    "$(json_escape "$OS")" "$GPUS_JSON" "$(json_escape "$DRIVER")" \
    "$ROOT_FREE_GIB" "$DATA_EXISTS" "$DATA_FREE_GIB" "$SYSTEMD" "$OK"
fi

if [ "$NG" -gt 0 ]; then
  exit 1
fi
exit 0
