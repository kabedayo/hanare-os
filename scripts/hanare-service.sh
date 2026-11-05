#!/usr/bin/env bash
# HANARE service helper: operations on the managed services that systemd
# alone cannot cover.
#
#   hanare-service.sh stop-external <llama-server|comfyui|strata>
#
# Stops a process that listens on a managed service's port but is NOT
# managed by the service's systemd user unit (for example a llama-server
# started directly from a launcher script: `systemctl stop` cannot see
# it, yet it keeps the port and the VRAM). The UIs call this right after
# a successful unit stop, so "stop" really stops the service.
#
# Safety rules (fixed, not configurable):
#   - fixed allowlist of services, fixed identity matches per service
#   - only PIDs that listen on the service's registered port
#     (plus, for llama-server, its internal server port 8081)
#   - only processes owned by the current user
#   - the process command line must match the service identity,
#     otherwise the stop is refused for that PID
#   - SIGTERM only, wait up to 10 s; never SIGKILL, never automatic:
#     this runs only as part of a user-initiated stop
#
# Exit codes: 0 stopped · 1 still running / error · 2 usage ·
#             3 no external process · 4 identity mismatch (refused)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TSV="${HANARE_SERVICES_TSV:-$REPO_ROOT/services/services.tsv}"

cmd="${1:-}"
service="${2:-}"

if [ "$cmd" != "stop-external" ] || [ -z "$service" ]; then
  echo "usage: hanare-service.sh stop-external <llama-server|comfyui|strata>" >&2
  exit 2
fi

# Probe list: "port:match" pairs. The port "-" means the registered port.
case "$service" in
  llama-server)
    # The local llama stack serves the registered port through its
    # effort-proxy and the server itself on an internal port (8081 in
    # scripts/hanare-llama-run.sh; override with HANARE_LLAMA_INTERNAL_PORT).
    probes=("REG:llama-server" "REG:effort-proxy.py" "${HANARE_LLAMA_INTERNAL_PORT:-8081}:llama-server")
    default_port=8080
    ;;
  comfyui)
    probes=("REG:main.py")
    default_port=8188
    ;;
  strata)
    # Strata serves its registered port from the python server process
    # (serve/server.py); the GPU engine is its child and exits with it.
    probes=("REG:serve/server.py")
    default_port=8095
    ;;
  *)
    echo "hanare-service: unknown service: $service" >&2
    exit 2
    ;;
esac

port="$default_port"
if [ -r "$TSV" ]; then
  from_tsv="$(awk -F'\t' -v n="$service" '$1 == n { print $2; exit }' "$TSV")"
  case "$from_tsv" in
    ''|*[!0-9]*) : ;;
    *) port="$from_tsv" ;;
  esac
fi

my_uid="$(id -u)"
targets=""
refused=""
found_listener=0

for probe in "${probes[@]}"; do
  p="${probe%%:*}"
  match="${probe#*:}"
  [ "$p" = "REG" ] && p="$port"
  lines="$(ss -tlnp 2>/dev/null | awk -v p="$p" '{n=split($4,a,":"); if (a[n]==p) print}')"
  [ -n "$lines" ] || continue
  pids="$(printf '%s\n' "$lines" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)"
  for pid in $pids; do
    [ -n "$pid" ] || continue
    found_listener=1
    [ "$pid" = "1" ] && continue
    [ "$pid" = "$$" ] && continue
    [ -e "/proc/$pid/cmdline" ] || continue
    owner="$(stat -c %u "/proc/$pid" 2>/dev/null)" || continue
    [ "$owner" = "$my_uid" ] || continue
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    case "$cmdline" in
      *"$match"*)
        case " $targets " in
          *" $pid "*) : ;;
          *) targets="$targets $pid" ;;
        esac
        ;;
      *)
        case " $refused " in
          *" $pid "*) : ;;
          *) refused="$refused $pid" ;;
        esac
        ;;
    esac
  done
done

if [ -n "$refused" ] && [ -z "$targets" ]; then
  echo "refused: pid(s)$refused on the port(s) of $service do not match its identity"
  exit 4
fi
if [ -z "$targets" ]; then
  if [ "$found_listener" = 1 ]; then
    echo "refused: listener(s) on the port(s) of $service are not owned by this user or not identifiable"
    exit 4
  fi
  echo "no external process for $service"
  exit 3
fi

for pid in $targets; do
  kill -TERM "$pid" 2>/dev/null || true
done

survivors=""
for _ in $(seq 1 20); do
  survivors=""
  for pid in $targets; do
    if kill -0 "$pid" 2>/dev/null; then
      survivors="$survivors $pid"
    fi
  done
  [ -z "$survivors" ] && break
  sleep 0.5
done

if [ -n "$survivors" ]; then
  echo "still running:$survivors"
  exit 1
fi

pid_list="$(printf '%s' "$targets" | sed 's/^ //' | tr ' ' ',')"
echo "stopped external $service pid=$pid_list"
exit 0
