# apps.d — user app registry

Drop a `<id>.app` file into this directory to make an app launchable from
the HANARE dashboard. The dashboard rescans this directory on every page
render and action, so no restart is needed.

## App sources

The dashboard discovers apps from three sources, in this priority order.
Entries that duplicate an already-found id, exec command line, or display
name are shown only once. Each app on the dashboard carries its source tag
（登録 / 自動検出 / ランチャー） next to its name.

1. **登録** — `<id>.app` files in this directory (documented below).
2. **自動検出** — anything placed in the drop folder
   (`$HANARE_APPS_DROP_DIR`, default `~/hanare-apps`, created if missing):
   - a **folder** containing `run.sh` or `start.sh` (or `start-*.sh`) —
     run with the folder as working directory; or containing `app.py` /
     `main.py` — run with the folder's `.venv/bin/python` when present,
     otherwise `python3`;
   - a **`.desktop` file** (parsed like a launcher, `%` field codes
     stripped from `Exec`);
   - an **executable file** — run directly, with the drop folder as
     working directory.
3. **ランチャー** — `.desktop` launchers in the desktop directories
   (`$HANARE_DESKTOP_DIRS`, colon-separated list, default
   `~/デスクトップ:~/.local/share/applications`). Entries with
   `Hidden=true` or `NoDisplay=true` are skipped; `%` field codes (e.g.
   `%U`) are stripped from `Exec`; `Path` is used as the working
   directory.

Apps from all three sources are started/stopped the same way (transient
`hanare-app-<id>` user units; the id is a slug of the file/folder/launcher
name).

- The app id is the filename without the `.app` extension and must match
  `[a-z0-9][a-z0-9-]*` (lowercase letters, digits, hyphens; no leading
  hyphen).
- Each file is plain text, one `key=value` per line. Lines starting with
  `#` and blank lines are ignored.
- Files that fail to parse, or that lack a `name` or `exec`, are skipped
  (the dashboard never crashes on a bad file).

## Keys

| key       | required | meaning                                                    |
|-----------|----------|------------------------------------------------------------|
| `name`    | yes      | Display name shown on the dashboard.                       |
| `exec`    | yes      | Command line to run (parsed with shell quoting rules).     |
| `workdir` | no       | Working directory for the command.                         |
| `url`     | no       | Web UI URL; the dashboard shows an 開く link when set.     |
| `note`    | no       | One-line description shown next to the name.               |

The command must run in the foreground (block until it exits) so the
dashboard can track it. Avoid wrappers that detach with `setsid`/`nohup`.

## Lifecycle

- 起動 runs `systemd-run --user --unit=hanare-app-<id> -- <exec>` (plus
  `--working-directory=<workdir>` when set), so the app runs as a
  transient user systemd unit.
- 停止 runs `systemctl --user stop hanare-app-<id>`.
- The state (起動中 / 停止中) comes from
  `systemctl --user is-active hanare-app-<id>`.

## Example

`apps.d/my-tool.app`:

```
name=My Tool
exec=/home/you/tools/my-tool/bin/run.sh --serve
workdir=/home/you/tools/my-tool
url=http://127.0.0.1:8800/
note=My tool web UI
```
