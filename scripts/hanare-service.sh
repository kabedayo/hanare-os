#!/usr/bin/env bash
# HANARE service helper: operations on the managed services that systemd
# alone cannot cover.
#
#   hanare-service.sh stop-external <llama-server|comfyui|strata>
#   hanare-service.sh stop-app-external <app-id>
#
# stop-app-external is the same idea for panel/dashboard "apps"
# (apps.d/<app-id>.app): an app started outside its hanare-app-<id>
# transient unit (e.g. from a desktop launcher in a terminal) cannot
# be stopped by `systemctl stop`, yet it keeps the app's port. The
# identity of an app process is its apps.d definition: a listener on
# the app's URL port whose working directory equals the app's
# workdir, or whose command line contains the workdir or the app's
# exec path. Anything else on that port is refused, never killed.
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

stop_app_external() {
  local app_id="$1"
  case "$app_id" in
    ''|*[!a-z0-9-]*|-*)
      echo "usage: hanare-service.sh stop-app-external <app-id>" >&2
      return 2
      ;;
  esac
  local apps_dir="${HANARE_APPS_DIR:-$REPO_ROOT/apps.d}"
  local app_file="$apps_dir/$app_id.app"
  if [ ! -r "$app_file" ]; then
    echo "unknown app: $app_id" >&2
    return 2
  fi
  local a_exec="" a_workdir="" a_url=""
  local line key value
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) : ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "$key" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$key" in
      exec) a_exec="$value" ;;
      workdir) a_workdir="$value" ;;
      url) a_url="$value" ;;
    esac
  done < "$app_file"
  if [ -z "$a_exec" ]; then
    echo "app $app_id has no exec" >&2
    return 2
  fi
  # Port from the app URL (http://127.0.0.1:8765/ -> 8765). Without a
  # port there is no safe way to identify the app's listener.
  local port=""
  port="$(printf '%s' "$a_url" | sed -n 's#^[a-zA-Z][a-zA-Z0-9+.-]*://[^/:]*:\([0-9][0-9]*\).*#\1#p')"
  if [ -z "$port" ]; then
    echo "no port known for app $app_id"
    return 3
  fi
  local exec_head="${a_exec%% *}"
  local my_uid targets="" refused="" found_listener=0 managed=0
  my_uid="$(id -u)"
  local lines pids pid owner cmdline cwd cgroup matched
  lines="$(ss -tlnp 2>/dev/null | awk -v p="$port" '{n=split($4,a,":"); if (a[n]==p) print}')"
  if [ -z "$lines" ]; then
    echo "no external process for app $app_id"
    return 3
  fi
  pids="$(printf '%s\n' "$lines" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)"
  for pid in $pids; do
    [ -n "$pid" ] || continue
    found_listener=1
    [ "$pid" = "1" ] && continue
    [ "$pid" = "$$" ] && continue
    [ -e "/proc/$pid/cmdline" ] || continue
    owner="$(stat -c %u "/proc/$pid" 2>/dev/null)" || continue
    [ "$owner" = "$my_uid" ] || continue
    cgroup="$(cat "/proc/$pid/cgroup" 2>/dev/null)"
    case "$cgroup" in
      *"hanare-app-$app_id.service"*) managed=1; continue ;;
    esac
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
    matched=0
    if [ -n "$a_workdir" ] && [ "$cwd" = "$a_workdir" ]; then
      matched=1
    fi
    if [ "$matched" = 0 ] && [ -n "$a_workdir" ]; then
      case "$cmdline" in
        *"$a_workdir"*) matched=1 ;;
      esac
    fi
    if [ "$matched" = 0 ]; then
      case "$exec_head" in
        /*)
          case "$cmdline" in
            *"$exec_head"*) matched=1 ;;
          esac
          ;;
      esac
    fi
    if [ "$matched" = 1 ]; then
      case " $targets " in
        *" $pid "*) : ;;
        *) targets="$targets $pid" ;;
      esac
    else
      case " $refused " in
        *" $pid "*) : ;;
        *) refused="$refused $pid" ;;
      esac
    fi
  done
  if [ -n "$refused" ] && [ -z "$targets" ]; then
    echo "refused: pid(s)$refused on the port of app $app_id do not match its identity"
    return 4
  fi
  if [ -z "$targets" ]; then
    if [ "$managed" = 1 ]; then
      echo "no external process for app $app_id"
      return 3
    fi
    if [ "$found_listener" = 1 ]; then
      echo "refused: listener(s) on the port of app $app_id are not owned by this user or not identifiable"
      return 4
    fi
    echo "no external process for app $app_id"
    return 3
  fi
  for pid in $targets; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  local survivors="" _
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
    return 1
  fi
  local pid_list
  pid_list="$(printf '%s' "$targets" | sed 's/^ //' | tr ' ' ',')"
  echo "stopped external app $app_id pid=$pid_list"
  return 0
}

if [ "$cmd" = "stop-app-external" ]; then
  stop_app_external "$service"
  exit $?
fi

if [ "$cmd" != "stop-external" ] || [ -z "$service" ]; then
  echo "usage: hanare-service.sh stop-external <llama-server|comfyui|strata>" >&2
  echo "       hanare-service.sh stop-app-external <app-id>" >&2
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
