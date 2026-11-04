#!/usr/bin/env bash
# HANARE status collector. READ-ONLY: no file writes, no signals, no sudo.
# Usage: status.sh [--json]
# Env: HANARE_SERVICES_TSV overrides the registry path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TSV="${HANARE_SERVICES_TSV:-$ROOT/services/services.tsv}"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

TIMESTAMP="$(date +%Y-%m-%dT%H:%M:%S%z)"

# ---- 1. GPUs -----------------------------------------------------------
GPU_OK=1
gpu_lines=""
if gpu_out="$(nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null)"; then
  gpu_lines="$gpu_out"
else
  GPU_OK=0
fi

gpu_json=""
gpu_table=""
if [ -n "$gpu_lines" ]; then
  while IFS=',' read -r gi gn gu gm gmt; do
    gi="$(trim "$gi")"; gn="$(trim "$gn")"; gu="$(trim "$gu")"; gm="$(trim "$gm")"; gmt="$(trim "$gmt")"
    [ -z "$gi" ] && continue
    gpu_json+="${gpu_json:+,}{\"index\":${gi},\"name\":\"$(json_escape "$gn")\",\"utilization\":${gu},\"memory_used_mib\":${gm},\"memory_total_mib\":${gmt}}"
    gpu_table+=$(printf '  %s  %-32s  %s%%  %s/%s MiB\n' "$gi" "$gn" "$gu" "$gm" "$gmt")
  done <<< "$gpu_lines"
fi

# ---- 2. GPU processes (failure => empty list, continue) ----------------
proc_json=""
proc_table=""
if pout="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null)"; then
  while IFS=',' read -r pp pn pm; do
    pp="$(trim "$pp")"; pn="$(trim "$pn")"; pm="$(trim "$pm")"
    [[ "$pp" =~ ^[0-9]+$ ]] || continue
    proc_json+="${proc_json:+,}{\"pid\":${pp},\"name\":\"$(json_escape "$pn")\",\"memory_mib\":${pm}}"
    proc_table+=$(printf '  %s  %-32s  %s MiB\n' "$pp" "$pn" "$pm")
  done <<< "$pout"
fi

# ---- 3. System memory from /proc/meminfo (MiB) --------------------------
MEM_OK=1
meminfo=""
if meminfo="$(cat /proc/meminfo 2>/dev/null)"; then
  :
else
  MEM_OK=0
fi
get_mib() { awk -v k="$1" '$1==k":"{print int($2/1024)}' <<< "$meminfo"; }
ram_total="$(get_mib MemTotal)"; ram_total=${ram_total:-0}
ram_avail="$(get_mib MemAvailable)"; ram_avail=${ram_avail:-0}
ram_used=$(( ram_total - ram_avail ))
swap_total="$(get_mib SwapTotal)"; swap_total=${swap_total:-0}
swap_free="$(get_mib SwapFree)"; swap_free=${swap_free:-0}
swap_used=$(( swap_total - swap_free ))

# ---- 4. Services --------------------------------------------------------
svc_json=""
svc_table=""
if [ -r "$TSV" ]; then
  while IFS=$'\t' read -r name port kw; do
    name="$(trim "$name")"
    case "$name" in ''|'#'*) continue ;; esac
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    kw="$(trim "$kw")"

    # listening pid from ss -tlnp (may be invisible => null)
    pid=""
    ss_line="$(ss -tlnp 2>/dev/null | awk -v p="$port" '{n=split($4,a,":"); if (a[n]==p) {print; exit}}')"
    if [ -n "$ss_line" ]; then
      pid="$(printf '%s' "$ss_line" | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2)"
    fi

    # port responds: any HTTP status counts (curl exit 0 = connected+responded)
    responds=0
    if curl -s -o /dev/null -m 2 "http://127.0.0.1:${port}/" 2>/dev/null; then
      responds=1
    fi

    rss="null"; cpu="null"; elapsed="null"; start=""
    if [ -n "$pid" ]; then
      r="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
      c="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
      es="$(ps -o etimes=,lstart= -p "$pid" 2>/dev/null)"
      e=""; s=""
      if [ -n "$es" ]; then
        read -r e l1 l2 l3 l4 l5 <<< "$es"
        s="$l1 $l2 $l3 $l4 $l5"
      fi
      [[ "$r" =~ ^[0-9]+$ ]] && rss="$r"
      [[ "$c" =~ ^[0-9]+(\.[0-9]+)?$ ]] && cpu="$c"
      [[ "$e" =~ ^[0-9]+$ ]] && elapsed="$e"
      [ -n "$s" ] && start="$s"
    fi

    state="degraded"
    if [ -n "$pid" ] && [ "$responds" = 1 ]; then
      state="running"
    elif [ -z "$pid" ] && [ "$responds" = 0 ]; then
      state="stopped"
    elif [ -n "$pid" ] && [ "$responds" = 0 ] && [ "$elapsed" != "null" ]; then
      # stuck-suspect: pid known, elapsed >= 600s, average CPU since start
      # below 2 percent, port does not respond. Average CPU is computed
      # reproducibly as: (utime+stime from /proc/<pid>/stat, in clock ticks,
      # 100 ticks/sec) divided by elapsed seconds, times 100 =>
      # (ticks/100)/elapsed*100 = ticks/elapsed. So <2% <=> ticks < 2*elapsed.
      # Label only: never kill or signal the process.
      stuck=0
      if [ "$elapsed" -ge 600 ] && [ -r "/proc/${pid}/stat" ]; then
        statstr="$(cat "/proc/${pid}/stat" 2>/dev/null)"
        if [ -n "$statstr" ]; then
          rest="${statstr##*) }"
          read -r _f1 _f2 _f3 _f4 _f5 _f6 _f7 _f8 _f9 _f10 _f11 utime stime _rest <<< "$rest"
          if [[ "$utime" =~ ^[0-9]+$ ]] && [[ "$stime" =~ ^[0-9]+$ ]]; then
            ticks=$(( utime + stime ))
            if [ "$ticks" -lt $(( 2 * elapsed )) ]; then
              stuck=1
            fi
          fi
        fi
      fi
      [ "$stuck" = 1 ] && state="stuck-suspect"
    fi

    start_json="null"
    [ -n "$start" ] && start_json="\"$(json_escape "$start")\""
    svc_json+="${svc_json:+,}{\"name\":\"$(json_escape "$name")\",\"port\":${port},\"gpu_keyword\":\"$(json_escape "$kw")\",\"state\":\"${state}\",\"pid\":${pid:-null},\"rss_kib\":${rss},\"cpu_percent\":${cpu},\"elapsed_sec\":${elapsed},\"start_time\":${start_json},\"port_responds\":${responds}}"
    svc_table+=$(printf '  %-16s %s  %-14s pid=%s rss=%s cpu=%s elapsed=%s\n' "$name" "$port" "$state" "${pid:-null}" "$rss" "$cpu" "$elapsed")
  done < "$TSV"
fi

# ---- Output --------------------------------------------------------------
if [ "$JSON" = 1 ]; then
  printf '{"timestamp":"%s","gpus":[%s],"gpu_processes":[%s],"memory":{"ram_total_mib":%s,"ram_used_mib":%s,"swap_total_mib":%s,"swap_used_mib":%s},"services":[%s]}\n' \
    "$TIMESTAMP" "$gpu_json" "$proc_json" \
    "$ram_total" "$ram_used" "$swap_total" "$swap_used" "$svc_json"
else
  printf 'timestamp: %s\n' "$TIMESTAMP"
  printf 'GPUs:\n'
  [ -n "$gpu_table" ] && printf '%s\n' "$gpu_table" || printf '  (none)\n'
  printf 'GPU processes:\n'
  [ -n "$proc_table" ] && printf '%s\n' "$proc_table" || printf '  (none)\n'
  printf 'Memory:\n'
  printf '  RAM:  %s/%s MiB used\n' "$ram_used" "$ram_total"
  printf '  Swap: %s/%s MiB used\n' "$swap_used" "$swap_total"
  printf 'Services:\n'
  [ -n "$svc_table" ] && printf '%s\n' "$svc_table" || printf '  (none)\n'
fi

[ "$GPU_OK" = 1 ] && [ "$MEM_OK" = 1 ] || exit 1
exit 0
