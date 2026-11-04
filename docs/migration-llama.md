# Migrating llama from the manual script to the hanare-llama unit

The `hanare-llama` user unit runs the same two core processes as
`~/llama.cpp/start-qwen38-agent.sh`:

- `effort-proxy.py` on 127.0.0.1:8080 (the port everything talks to)
- `llama-server` on 127.0.0.1:8081 (upstream of the proxy)

Model, context, and profile come from `models/models.tsv`. Selection
precedence: env `HANARE_MODEL` > `runtime/current-model` (set by
`scripts/hanare-model.sh use <name>`) > default `qwen3.8-27b`.

The desktop/browser MCP helpers (ports 8766/8767) are NOT part of this
unit; start those manually if needed.

## Preconditions

- No Qwen/OpenCode tasks running against 127.0.0.1:8080.
- No other chat/UI using 8080 or 8081.
- VRAM: `qwen3.8-27b` at ctx 131072 needs ~25GB on the V100. Unload
  ComfyUI models first if ComfyUI is loaded.

## Steps

1. Stop the manual stack:
   `~/llama.cpp/start-qwen38-agent.sh --stop`
   (or close its terminal / Ctrl+C).
2. Confirm the ports are free:
   `ss -ltnp | grep -E ':(8080|8081)\b'`
3. Install the units (if not already installed):
   `bash setup/13-install-services.sh`
4. Start the unit:
   `systemctl --user start hanare-llama`
5. Verify:
   - `curl -s http://127.0.0.1:8080/health` and `curl -s http://127.0.0.1:8081/health`
   - one chat completion through 8080
   - `nvidia-smi` shows the model loaded (~25GB used)
   - logs: `runtime/logs/llama-server.log`, `runtime/logs/effort-proxy.log`

## Switching models

```
scripts/hanare-model.sh list
scripts/hanare-model.sh use gemma4
systemctl --user restart hanare-llama
scripts/hanare-model.sh current
```

## Rollback

- `systemctl --user stop hanare-llama`
- run `~/llama.cpp/start-qwen38-agent.sh`
