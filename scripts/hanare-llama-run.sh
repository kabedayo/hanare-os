#!/usr/bin/env bash
# HANARE llama core runner: effort-proxy (8080) -> llama-server (8081).
# Model is selected from models/models.tsv:
#   env HANARE_MODEL > runtime/current-model > first registry row
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_TSV="$REPO_ROOT/models/models.tsv"
LOG_DIR="$REPO_ROOT/runtime/logs"

# Local machine configuration: runtime/llama-env.sh (git-ignored).
# See scripts/llama-env.example.sh for the available variables.
if [ -f "$REPO_ROOT/runtime/llama-env.sh" ]; then
  set -a
  . "$REPO_ROOT/runtime/llama-env.sh"
  set +a
fi
agent_dir="${HANARE_AGENT_DIR:-$HOME/llama.cpp/qwen38-agent}"
server="${HANARE_LLAMA_SERVER:-$HOME/llama.cpp/build/bin/llama-server}"
python="${HANARE_PROXY_PYTHON:-python3}"

export CUDA_VISIBLE_DEVICES="${HANARE_CUDA_DEVICE:-0}"
if [ -n "${HANARE_CUDA_LIB:-}" ]; then
  export LD_LIBRARY_PATH="$HANARE_CUDA_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

mkdir -p "$LOG_DIR"

model_name="${HANARE_MODEL:-}"
if [ -z "$model_name" ] && [ -f "$REPO_ROOT/runtime/current-model" ]; then
  model_name="$(head -n 1 "$REPO_ROOT/runtime/current-model" | tr -d '[:space:]')"
fi
if [ -z "$model_name" ]; then
  model_name="$(awk -F'\t' '$1 != "name" && NF >= 5 { print $1; exit }' "$MODELS_TSV")"
fi

row="$(awk -F'\t' -v n="$model_name" '$1 == n { print; exit }' "$MODELS_TSV")"
if [ -z "$row" ]; then
  echo "hanare-llama: unknown model '$model_name' in $MODELS_TSV" >&2
  exit 1
fi
gguf="$(printf '%s\n' "$row" | cut -f2)"
mmproj="$(printf '%s\n' "$row" | cut -f3)"
ctx="$(printf '%s\n' "$row" | cut -f4)"
profile="$(printf '%s\n' "$row" | cut -f5)"
draft="$(printf '%s\n' "$row" | cut -f7)"
[ -n "$draft" ] || draft="-"

if [ ! -f "$gguf" ]; then
  echo "hanare-llama: model file not found: $gguf" >&2
  exit 1
fi
if [ "$profile" = gemma ] && [ ! -f "$draft" ]; then
  echo "hanare-llama: draft model file not found: $draft" >&2
  exit 1
fi

args=(-m "$gguf")
if [ "$mmproj" != "-" ]; then
  args+=(--mmproj "$mmproj")
fi
args+=(
  --alias "$model_name"
  --device CUDA0 -ngl 99 --fit off -fa on
  -c "$ctx" -np 1 -ctk q8_0 -ctv q8_0
  -b 2048 -ub 1024 -t 8 -tb 8
  --jinja --no-context-shift
  --reasoning on --reasoning-effort medium --reasoning-budget -1
  --reasoning-budget-message $'\n\n(Thinking budget reached. Answer now based on the reasoning so far.)\n'
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0
  --host 127.0.0.1 --port 8081
)
if [ "$profile" = gemma ]; then
  # Gemma uses an external MTP draft model, mirroring start-gemma4.sh.
  args+=(
    --spec-type draft-mtp
    --spec-draft-model "$draft"
    --spec-draft-n-max 4 --spec-draft-ngl 99
  )
else
  args+=(--spec-type draft-mtp,ngram-simple)
fi
if [ "$profile" = qwen38 ]; then
  args+=(
    --image-max-tokens 1024
    --chat-template-file "$agent_dir/chat-template.jinja"
    --tools all --mcp-servers-config "$agent_dir/mcp-servers.json"
    --ui-mcp-proxy --webui-config-file "$agent_dir/webui-config.json"
  )
fi

echo "hanare-llama: starting effort-proxy (8080) -> llama-server (8081), model=$model_name ctx=$ctx profile=$profile"

if [ -f "$agent_dir/effort-proxy.py" ]; then
  "$python" "$agent_dir/effort-proxy.py" --listen-port 8080 --upstream http://127.0.0.1:8081 \
    >> "$LOG_DIR/effort-proxy.log" 2>&1 &
else
  echo "hanare-llama: no effort-proxy at $agent_dir; llama-server only (8081)"
fi

exec "$server" "${args[@]}" >> "$LOG_DIR/llama-server.log" 2>&1
