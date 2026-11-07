# services/services.tsv — the HANARE service registry

This file is the **single source of truth** for managed services.
The status collector, top bar, panel and dashboard all read service
definitions from here (directly or via the status snapshot). Adding a
service is one row here plus — for a panel-managed one — nothing else:
the panel's settings card (サービス設定) writes rows and regenerates
units for you.

## Format

Tab-separated, one row per service. Lines starting with `#` and blank
lines are ignored. Columns:

| # | column      | meaning |
|---|-------------|---------|
| 1 | name        | Service id: lowercase letters, digits, hyphens (`llama-server`). Used everywhere as the key. |
| 2 | port        | TCP port on 127.0.0.1 that status.sh probes for liveness. |
| 3 | gpu_keyword | GPU name keyword for display/grouping (e.g. `Tesla V100`); `-` if none. |
| 4 | display     | Human display name for buttons (`ComfyUI`). Defaults to name. |
| 5 | unit        | systemd user unit base name (`hanare-comfyui`). |
| 6 | exec        | Start command for auto-generated units, or `-` for a hand-managed unit whose file lives in `systemd/` and is installed by `setup/13-install-services.sh`. |
| 7 | workdir     | Working directory for generated units; `-` for none. |
| 8 | url         | Web UI URL for the service; `-` for none. |

Trailing columns may be omitted; old 3-column rows keep working
(the original two services have built-in fallbacks for unit/display).

## Unit generation

`scripts/hanare-service-gen.sh [name]` (re)writes
`~/.config/systemd/user/<unit>.service` for every row with
exec != `-` and runs `systemctl --user daemon-reload`. Generated units
have no `[Install]` section, `Restart=on-failure`,
`RestartSec=10s`, `TimeoutStopSec=60`, matching the hand-written ones.
Never edit a generated unit file; edit the registry row instead.

## stop-external

Reaping a same-service process that was started outside its unit is
*not* registry-driven: `scripts/hanare-service.sh stop-external` keeps
its own fixed allowlist (llama-server / comfyui / strata) on purpose.
