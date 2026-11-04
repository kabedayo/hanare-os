#!/usr/bin/env bash
# HANARE model registry CLI: list / current / use
# Selection precedence: env HANARE_MODEL > runtime/current-model > first registry row
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_TSV="$REPO_ROOT/models/models.tsv"
CURRENT_FILE="${HANARE_CURRENT_MODEL:-$REPO_ROOT/runtime/current-model}"

usage() {
  cat <<'EOF'
Usage: hanare-model.sh <command>
  list            show registered models (current one marked with *)
  current         print the currently selected model name
  use <name>      select a model (applies on next hanare-llama restart)
EOF
}

current_name() {
  if [ -f "$CURRENT_FILE" ]; then
    head -n 1 "$CURRENT_FILE" | tr -d '[:space:]'
  else
    awk -F'\t' '$1 != "name" && NF >= 2 { print $1; exit }' "$MODELS_TSV"
  fi
}

cmd="${1:-}"
case "$cmd" in
  list)
    [ -f "$MODELS_TSV" ] || { echo "model registry not found: $MODELS_TSV" >&2; exit 1; }
    cur="$(current_name)"
    while IFS=$'\t' read -r name gguf mmproj ctx profile note; do
      [ -n "$name" ] || continue
      mark="  "
      [ "$name" = "$cur" ] && mark="* "
      if [ "$gguf" != "-" ] && [ -f "$gguf" ]; then
        size="$(du -hL "$gguf" 2>/dev/null | cut -f1)"
        printf '%s%-18s ctx %-7s [OK]      %s\n' "$mark" "$name" "$ctx" "${size:-n/a}"
      else
        printf '%s%-18s ctx %-7s [MISSING]\n' "$mark" "$name" "$ctx"
      fi
    done < <(tail -n +2 "$MODELS_TSV")
    ;;
  current)
    current_name
    ;;
  use)
    name="${2:-}"
    [ -n "$name" ] || { usage; exit 2; }
    row="$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$MODELS_TSV")"
    if [ -z "$row" ]; then
      echo "unknown model: $name" >&2
      usage >&2
      exit 2
    fi
    gguf="$(printf '%s\n' "$row" | cut -f2)"
    if [ "$gguf" = "-" ] || [ ! -f "$gguf" ]; then
      echo "model file not found: $gguf" >&2
      exit 2
    fi
    mkdir -p "$(dirname "$CURRENT_FILE")"
    printf '%s\n' "$name" > "$CURRENT_FILE"
    echo "selected model: $name"
    echo "applies on next hanare-llama restart (systemctl --user restart hanare-llama)"
    ;;
  *)
    usage
    exit 2
    ;;
esac
