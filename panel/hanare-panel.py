#!/usr/bin/env python3
"""HANARE panel: a small native window for the HANARE status and controls.

Design: B (wa-modern) x C (cards). Reads the same runtime files as the
topbar extension and the web dashboard (runtime/last-status.json,
runtime/events.jsonl, models/models.tsv, runtime/current-model) and acts
through the same fixed routes: systemctl --user for the services in the
registry (services/services.tsv, which is the single source of truth
for service name -> unit/display/exec), systemd-run --user for apps,
scripts/hanare-model.sh for model selection. No shell is ever invoked.
The settings card at the bottom edits that registry (services and new
models) and regenerates units via scripts/hanare-service-gen.sh.
Its form can be prefilled from a desktop launcher (.desktop) picked
in the settings card; the launcher helpers are pure and are also
exposed in the --dump output as "launchers".
Apps listed in the apps card can be dragged onto the services card;
the drop only prefills the settings form (app_to_service_prefill)
and nothing is registered until the user presses save.

Usage:
  hanare-panel.py           open the window
  hanare-panel.py --dump    print the data model as JSON and exit
"""

import json
import os
import re
import shlex
import subprocess
import sys
import threading
import urllib.parse

REPO_ROOT = os.environ.get(
    "HANARE_REPO",
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
)
RUNTIME_DIR = os.path.join(REPO_ROOT, "runtime")
STATUS_FILE = os.path.join(RUNTIME_DIR, "last-status.json")
EVENTS_FILE = os.path.join(RUNTIME_DIR, "events.jsonl")
MODELS_TSV = os.path.join(REPO_ROOT, "models", "models.tsv")
CURRENT_MODEL_FILE = os.path.join(RUNTIME_DIR, "current-model")

SYSTEMCTL = os.environ.get("HANARE_SYSTEMCTL", "systemctl")
SYSTEMD_RUN = os.environ.get("HANARE_SYSTEMD_RUN", "systemd-run")
MODEL_CLI = os.environ.get(
    "HANARE_MODEL_CLI", os.path.join(REPO_ROOT, "scripts", "hanare-model.sh")
)
SERVICE_CLI = os.environ.get(
    "HANARE_SERVICE_CLI", os.path.join(REPO_ROOT, "scripts", "hanare-service.sh")
)
CAPTURE_CLI = os.environ.get(
    "HANARE_CAPTURE_CLI", os.path.join(REPO_ROOT, "feed", "capture.sh")
)
ACTION_TIMEOUT = 15

SERVICES_TSV = os.path.join(REPO_ROOT, "services", "services.tsv")
SERVICE_GEN = os.environ.get(
    "HANARE_SERVICE_GEN", os.path.join(REPO_ROOT, "scripts", "hanare-service-gen.sh")
)
UNIT_DIR = os.path.expanduser(
    os.environ.get("HANARE_UNIT_DIR", "~/.config/systemd/user")
)
# Fallback for snapshots/registries from before the registry carried
# unit names; services/services.tsv is the source of truth and wins.
FALLBACK_SERVICES = {
    "comfyui": "hanare-comfyui.service",
    "llama-server": "hanare-llama.service",
}
SERVICE_ACTIONS = ("start", "stop", "restart")
# hanare-service.sh stop-external has its own fixed allowlist.
STOP_EXTERNAL_SERVICES = ("llama-server", "comfyui", "strata")

STATE_COLORS = {
    "running": "#58a34c",
    "stopped": "#8a8578",
    "degraded": "#d9a441",
    "stuck-suspect": "#c73e2c",
}
STATE_ORDER = {"running": 0, "degraded": 1, "stuck-suspect": 2, "stopped": 3}

sys.path.insert(0, os.path.join(REPO_ROOT, "dashboard"))
try:
    from discovery import discover  # noqa: E402
except Exception:  # pragma: no cover - panel still works without apps
    discover = None


def apps_dirs():
    apps_dir = os.environ.get(
        "HANARE_APPS_DIR", os.path.join(REPO_ROOT, "apps.d")
    )
    drop_dir = os.path.expanduser(
        os.environ.get("HANARE_APPS_DROP_DIR", "~/hanare-apps")
    )
    desktop_dirs = []
    if os.environ.get("HANARE_DESKTOP_SCAN") == "1":
        desktop_dirs = [
            os.path.expanduser(d.strip())
            for d in os.environ.get(
                "HANARE_DESKTOP_DIRS",
                "~/デスクトップ:~/.local/share/applications",
            ).split(":")
            if d.strip()
        ]
    return apps_dir, drop_dir, desktop_dirs


LAUNCHER_FIELD_CODE_RE = re.compile(r"%[fFuUdDnNickVm]|%")
LAUNCHER_SLUG_RE = re.compile(r"[^a-z0-9]+")
LAUNCHER_WRAPPER_NAMES = (
    "gnome-terminal", "gnome-terminal.real", "xdg-open", "nohup", "steam",
)


def launcher_dirs():
    """Desktop launcher folders scanned by the settings-card picker."""
    raw = os.environ.get("HANARE_LAUNCHER_DIRS") or os.environ.get(
        "HANARE_DESKTOP_DIRS"
    )
    if raw:
        return [
            os.path.expanduser(d.strip()) for d in raw.split(":") if d.strip()
        ]
    return [
        os.path.expanduser("~/Desktop"),
        os.path.expanduser("~/\u30c7\u30b9\u30af\u30c8\u30c3\u30d7"),
        os.path.expanduser("~/.local/share/applications"),
    ]


def launcher_id_suggestion(stem):
    """Slug for a service name from a .desktop file name stem."""
    return LAUNCHER_SLUG_RE.sub("-", stem.lower()).strip("-")


def _systemd_quote(arg):
    if arg == "":
        return '\"\"'
    if re.search(r"[\s\"'\\$`]", arg):
        return '"' + arg.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return arg


def launcher_exec_argv(exec_value):
    """Strip .desktop field codes and split an Exec value with shlex."""
    cleaned = LAUNCHER_FIELD_CODE_RE.sub("", exec_value or "")
    try:
        argv = shlex.split(cleaned)
    except ValueError:
        return None
    return argv or None


def launcher_wrapper_token(argv):
    """Return the wrapper program name found in argv, or None."""
    for token in argv or []:
        base = os.path.basename(token)
        if base in LAUNCHER_WRAPPER_NAMES:
            return base
    return None



APP_ID_SLUG_RE = re.compile(r"[^a-z0-9]+")


def service_id_from_app_id(raw):
    """Normalize an app id into a registry service name (or '')."""
    slug = APP_ID_SLUG_RE.sub("-", (raw or "").lower()).strip("-")
    return slug if SERVICE_ID_RE.match(slug) else ""


def port_from_url(url):
    """Extract the port from a URL like http://127.0.0.1:8765/ (or None)."""
    if not url or url == "-":
        return None
    try:
        port = urllib.parse.urlparse(url).port
    except ValueError:
        return None
    return port if port and 1 <= port <= 65535 else None


def auto_url_for_port(port):
    """Default service URL for a port: http://127.0.0.1:<port>/ (or '')."""
    try:
        pnum = int(str(port).strip())
    except (TypeError, ValueError):
        return ""
    if 1 <= pnum <= 65535:
        return "http://127.0.0.1:%d/" % pnum
    return ""


def app_to_service_prefill(app, registry_names=None):
    """Map a discovered app dict to a service-form prefill dict.

    Pure: registry_names may be passed in for collision checks; when
    omitted the on-disk registry is read. Nothing is written here:
    the user still reviews the form and presses save.
    """
    name = service_id_from_app_id(app.get("id") or "")
    argv = app.get("exec_argv") or []
    if not argv and app.get("exec"):
        argv = launcher_exec_argv(app["exec"]) or []
    exec_text = app.get("exec") or " ".join(_systemd_quote(a) for a in argv)
    url = app.get("url") or ""
    port = port_from_url(url)
    if registry_names is None:
        registry_names = {row["name"] for row in load_service_registry()}
    return {
        "name": name,
        "display": app.get("name") or name,
        "port": str(port) if port else "",
        "exec": exec_text,
        "workdir": app.get("workdir") or "",
        "url": "" if url == "-" else url,
        "conflict": bool(name) and name in registry_names,
        "wrapper": launcher_wrapper_token(argv),
    }


def parse_desktop_file(path):
    """Parse one .desktop launcher into a settings-form dict (or None)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return None
    values = {}
    section = None
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if section != "Desktop Entry" or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key not in values:
            values[key] = value.strip()
    type_value = values.get("Type")
    if type_value is not None and type_value != "Application":
        return None
    name = values.get("Name")
    exec_value = values.get("Exec")
    if not name or not exec_value:
        return None
    if values.get("Hidden", "").lower() == "true":
        return None
    if values.get("NoDisplay", "").lower() == "true":
        return None
    argv = launcher_exec_argv(exec_value)
    if not argv:
        return None
    stem = os.path.splitext(os.path.basename(str(path)))[0]
    return {
        "name": name,
        "exec": " ".join(_systemd_quote(a) for a in argv),
        "exec_argv": argv,
        "workdir": values.get("Path") or "",
        "file": str(path),
        "id_suggestion": launcher_id_suggestion(stem),
        "wrapper": launcher_wrapper_token(argv),
    }


def scan_launchers(dirs=None):
    """Scan launcher folders; the first file with a given name wins."""
    if dirs is None:
        dirs = launcher_dirs()
    results = []
    seen = set()
    for folder in dirs:
        try:
            names = sorted(os.listdir(folder))
        except OSError:
            continue
        for fname in names:
            if not fname.endswith(".desktop") or fname in seen:
                continue
            seen.add(fname)
            item = parse_desktop_file(os.path.join(folder, fname))
            if item is not None:
                results.append(item)
    return results


def load_snapshot():
    try:
        with open(STATUS_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def load_events(limit=6):
    events = []
    try:
        with open(EVENTS_FILE, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return events
    for line in lines[-64:]:
        line = line.strip()
        if not line:
            continue
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict):
            events.append(item)
    return events[-limit:][::-1]


def load_models():
    models = []
    try:
        with open(MODELS_TSV, encoding="utf-8") as fh:
            rows = fh.readlines()
    except OSError:
        return models
    for row in rows:
        row = row.rstrip("\n")
        if not row or row.startswith("#"):
            continue
        parts = row.split("\t")
        if len(parts) < 4 or parts[0] == "name":
            continue
        try:
            ctx = int(parts[3])
        except ValueError:
            ctx = 0
        models.append({"name": parts[0], "ctx": ctx})
    return models


def current_model():
    try:
        with open(CURRENT_MODEL_FILE, encoding="utf-8") as fh:
            value = fh.read().strip()
        return value or None
    except OSError:
        return None


def app_unit(app_id):
    return "hanare-app-%s" % app_id


REGISTRY_COLUMNS = (
    "name", "port", "gpu_keyword", "display", "unit", "exec", "workdir", "url",
)
REGISTRY_HEADER = (
    "# HANARE service registry - one row per service, tab-separated.\n"
    "# Columns: name<TAB>port<TAB>gpu_keyword<TAB>display<TAB>unit<TAB>exec<TAB>workdir<TAB>url\n"
    "# exec \"-\" means a hand-managed unit: no unit file is auto-generated for it.\n"
    "# Trailing columns may be omitted (empty). See services/README.md.\n"
)
SERVICE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
UNIT_NAME_RE = re.compile(r"^[A-Za-z0-9_@.\-]+$")


def load_service_registry():
    """Parse services/services.tsv into a list of row dicts."""
    rows = []
    try:
        with open(SERVICES_TSV, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return rows
    for line in lines:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        try:
            port = int(parts[1])
        except ValueError:
            continue
        row = {col: "" for col in REGISTRY_COLUMNS}
        for i, col in enumerate(REGISTRY_COLUMNS):
            if i < len(parts):
                row[col] = parts[i].strip()
        row["port"] = port
        rows.append(row)
    return rows


def service_units():
    """{service name: unit-with-.service} from the registry + fallback."""
    units = {}
    for row in load_service_registry():
        unit = row.get("unit") or ""
        if unit and unit != "-":
            if not unit.endswith(".service"):
                unit += ".service"
            units[row["name"]] = unit
    for name, unit in FALLBACK_SERVICES.items():
        units.setdefault(name, unit)
    return units


def snapshot_unit(svc, units):
    unit = svc.get("unit") or ""
    if unit:
        return unit if unit.endswith(".service") else unit + ".service"
    return units.get(svc.get("name"))


def save_service_registry(rows):
    lines = [REGISTRY_HEADER]
    for row in rows:
        values = []
        for col in REGISTRY_COLUMNS:
            value = row.get(col, "")
            values.append(str(value))
        lines.append("\t".join(values) + "\n")
    tmp = SERVICES_TSV + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    os.replace(tmp, SERVICES_TSV)


def regenerate_units():
    """Generate units for exec-managed rows + daemon-reload (via the gen script)."""
    try:
        proc = subprocess.run(
            ["bash", SERVICE_GEN],
            capture_output=True,
            text=True,
            timeout=60,
        )
        return proc.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def upsert_service(form):
    """Validate a settings-form dict and insert/update its registry row.

    Returns (ok, message). On success the registry is saved and units
    are regenerated (which also daemon-reloads).
    """
    name = (form.get("name") or "").strip()
    display = (form.get("display") or "").strip() or name
    exec_cmd = (form.get("exec") or "").strip() or "-"
    workdir = (form.get("workdir") or "").strip() or "-"
    url = (form.get("url") or "").strip() or "-"
    gpu_keyword = (form.get("gpu_keyword") or "").strip() or "-"
    if not SERVICE_ID_RE.match(name):
        return False, "サービス名は半角小文字・数字・ハイフン（先頭は英数字）で入力してください"
    try:
        port = int(form.get("port") or "")
    except (TypeError, ValueError):
        return False, "ポートは数値で入力してください"
    if not (1 <= port <= 65535):
        return False, "ポートは 1〜65535 で入力してください"
    if url == "-":
        url = auto_url_for_port(port) or "-"
    for value in (display, exec_cmd, workdir, url):
        if "\t" in value or "\n" in value:
            return False, "タブや改行は使えません"
    if exec_cmd != "-":
        unit = "hanare-%s" % name
    else:
        unit = (form.get("unit") or "").strip() or ("hanare-%s" % name)
    if not UNIT_NAME_RE.match(unit):
        return False, "ユニット名に使えない文字があります"
    rows = load_service_registry()
    new_row = {
        "name": name,
        "port": port,
        "gpu_keyword": gpu_keyword,
        "display": display,
        "unit": unit,
        "exec": exec_cmd,
        "workdir": workdir,
        "url": url,
    }
    for i, row in enumerate(rows):
        if row["name"] == name:
            rows[i] = new_row
            break
    else:
        rows.append(new_row)
    try:
        save_service_registry(rows)
    except OSError as exc:
        return False, "レジストリの保存に失敗しました: %s" % exc
    if not regenerate_units():
        return False, "保存はできましたがユニット生成に失敗しました"
    return True, "サービス「%s」を保存しました" % name


def remove_service(name):
    """Remove a registry row; also remove its unit file if we generated it."""
    rows = load_service_registry()
    target = None
    kept = []
    for row in rows:
        if row["name"] == name:
            target = row
        else:
            kept.append(row)
    if target is None:
        return False, "サービスが見つかりません: %s" % name
    try:
        save_service_registry(kept)
    except OSError as exc:
        return False, "レジストリの保存に失敗しました: %s" % exc
    unit = target.get("unit") or ""
    if target.get("exec") not in ("", "-") and unit:
        path = os.path.join(UNIT_DIR, unit + ".service")
        try:
            with open(path, encoding="utf-8") as fh:
                generated = "hanare-service-gen" in fh.read(300)
        except OSError:
            generated = False
        if generated:
            try:
                os.remove(path)
            except OSError:
                pass
    regenerate_units()
    return True, "サービス「%s」を削除しました" % name


def demote_service_to_app(name):
    """Move a registry service back to an app.

    Writes apps.d/<name>.app (unless one already exists) from the
    registry row, then removes the registry row (which also removes
    the generated unit). Hand-managed services (exec "-") have no
    command to run as an app and are refused. Returns (ok, message).
    """
    rows = load_service_registry()
    target = None
    for row in rows:
        if row["name"] == name:
            target = row
            break
    if target is None:
        return False, "サービスが見つかりません: %s" % name
    exec_cmd = (target.get("exec") or "").strip()
    if exec_cmd in ("", "-"):
        return False, (
            "サービス「%s」は起動コマンドを持たない（手管理ユニット）ため、"
            "アプリへ下ろせません" % name
        )
    apps_dir, _drop_dir, _desktop_dirs = apps_dirs()
    app_path = os.path.join(apps_dir, name + ".app")
    wrote = False
    if not os.path.exists(app_path):
        lines = [
            "name=%s" % (target.get("display") or name),
            "exec=%s" % exec_cmd,
        ]
        workdir = (target.get("workdir") or "").strip()
        if workdir and workdir != "-":
            lines.append("workdir=%s" % workdir)
        url = (target.get("url") or "").strip()
        if url and url != "-":
            lines.append("url=%s" % url)
        lines.append("note=サービスから下ろしたアプリ")
        try:
            os.makedirs(apps_dir, exist_ok=True)
            with open(app_path, "w", encoding="utf-8") as fh:
                fh.write("\n".join(lines) + "\n")
            wrote = True
        except OSError as exc:
            return False, "アプリ定義の保存に失敗しました: %s" % exc
    ok, _msg = remove_service(name)
    if not ok:
        return False, "サービス登録の解除に失敗しました（アプリ定義は作成済みです）"
    if wrote:
        return True, "サービス「%s」をアプリへ下ろしました" % name
    return True, "サービス「%s」を解除しました（アプリ定義は既存のものを使います）" % name


def add_model(form):
    """Append one row to models/models.tsv. Returns (ok, message)."""
    name = (form.get("name") or "").strip()
    gguf = (form.get("gguf") or "").strip()
    mmproj = (form.get("mmproj") or "").strip() or "-"
    profile = (form.get("profile") or "").strip() or "generic"
    note = (form.get("note") or "").strip()
    if not name or "\t" in name or "\n" in name or " " in name:
        return False, "モデル名は空白なしで入力してください"
    if not gguf or not os.path.isfile(gguf):
        return False, "GGUFファイルが見つかりません: %s" % gguf
    try:
        ctx = int(form.get("ctx") or "")
    except (TypeError, ValueError):
        return False, "ctxは数値で入力してください"
    if ctx <= 0:
        return False, "ctxは正の数で入力してください"
    for model in load_models():
        if model["name"] == name:
            return False, "同名のモデルが既にあります: %s" % name
    row = "\t".join([name, gguf, mmproj, str(ctx), profile, note, "-"]) + "\n"
    try:
        with open(MODELS_TSV, "a", encoding="utf-8") as fh:
            fh.write(row)
    except OSError as exc:
        return False, "モデル登録の保存に失敗しました: %s" % exc
    return True, "モデル「%s」を追加しました" % name


def run_cmd(argv, timeout=ACTION_TIMEOUT):
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout
        )
        return proc.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def unit_is_active(unit):
    try:
        proc = subprocess.run(
            [SYSTEMCTL, "--user", "is-active", unit],
            capture_output=True,
            text=True,
            timeout=ACTION_TIMEOUT,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.stdout.strip() == "active"


def app_listener_pids(port):
    """PIDs listening on a TCP port (via ss), best effort."""
    try:
        proc = subprocess.run(
            ["ss", "-tlnp"], capture_output=True, text=True, timeout=ACTION_TIMEOUT
        )
    except (OSError, subprocess.SubprocessError):
        return []
    pids = []
    for line in proc.stdout.splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        local = fields[3]
        if not local.rsplit(":", 1)[-1].isdigit():
            continue
        if int(local.rsplit(":", 1)[-1]) != port:
            continue
        for match in re.findall(r"pid=(\d+)", line):
            pid = int(match)
            if pid not in pids:
                pids.append(pid)
    return pids


def pid_matches_app(pid, app):
    """Read-only identity check: is this PID the app's own process?

    Same rules as hanare-service.sh stop-app-external: owned by the
    current user, and either its working directory is the app's
    workdir, or its command line contains the workdir or the app's
    exec path. Never signals anything.
    """
    try:
        if os.stat("/proc/%d" % pid).st_uid != os.getuid():
            return False
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            cmdline = fh.read().replace(b"\0", b" ").decode("utf-8", "replace")
        cwd = os.readlink("/proc/%d/cwd" % pid)
    except OSError:
        return False
    workdir = app.get("workdir") or ""
    if workdir and cwd == workdir:
        return True
    if workdir and workdir in cmdline:
        return True
    argv = app.get("exec_argv") or []
    if argv and os.path.isabs(argv[0]) and argv[0] in cmdline:
        return True
    return False


def app_external_pid(app):
    """PID of the app's externally-started instance, or None.

    An instance is external when its hanare-app unit is not active
    (callers check that) but a process matching the app's identity
    listens on the app's URL port -- e.g. the app was launched from
    a desktop icon in a terminal, where `systemctl stop` cannot
    see it.
    """
    port = port_from_url(app.get("url"))
    if not port:
        return None
    for pid in app_listener_pids(port):
        if pid_matches_app(pid, app):
            return pid
    return None


def scan_apps():
    if discover is None:
        return []
    apps_dir, drop_dir, desktop_dirs = apps_dirs()
    try:
        os.makedirs(drop_dir, exist_ok=True)
    except OSError:
        pass
    try:
        found = discover(apps_dir, drop_dir, desktop_dirs)
    except Exception:
        return []
    result = []
    for app in found:
        item = dict(app)
        item["active"] = unit_is_active(app_unit(app["id"]))
        item["external"] = (
            not item["active"] and app_external_pid(item) is not None
        )
        result.append(item)
    return result


def collect_model():
    snap = load_snapshot()
    units = service_units()
    services = []
    for svc in snap.get("services") or []:
        if not isinstance(svc, dict):
            continue
        unit = snapshot_unit(svc, units)
        if unit is None:
            continue
        item = dict(svc)
        item["unit"] = unit
        item["external"] = bool(
            item.get("state") in ("running", "degraded", "stuck-suspect")
            and item.get("pid")
            and not unit_is_active(unit)
        )
        services.append(item)
    return {
        "timestamp": snap.get("timestamp"),
        "gpus": snap.get("gpus") or [],
        "memory": snap.get("memory") or {},
        "services": services,
        "registry": load_service_registry(),
        "launchers": scan_launchers(),
        "models": load_models(),
        "current_model": current_model(),
        "apps": scan_apps(),
        "events": load_events(),
    }


def format_ctx(ctx):
    if not ctx:
        return ""
    if ctx % 1024 == 0:
        return "%dK" % (ctx // 1024)
    return str(ctx)


def format_elapsed(sec):
    if sec is None:
        return ""
    sec = int(sec)
    if sec < 60:
        return "%d秒" % sec
    if sec < 3600:
        return "%d分" % (sec // 60)
    if sec < 86400:
        return "%d時間%d分" % (sec // 3600, (sec % 3600) // 60)
    return "%d日" % (sec // 86400)


def worst_state(services):
    worst = None
    for svc in services:
        state = svc.get("state")
        if state in STATE_ORDER and (
            worst is None or STATE_ORDER[state] > STATE_ORDER[worst]
        ):
            worst = state
    return worst


def event_summary(event):
    kind = event.get("kind", "")
    name = event.get("name", "")
    detail = event.get("detail") or {}
    if kind == "metric":
        vram = detail.get("vram_mib")
        ram = detail.get("ram_used_mib")
        bits = []
        if vram is not None:
            bits.append("VRAM %s MiB" % vram)
        if ram is not None:
            bits.append("RAM %s MiB" % ram)
        return " · ".join(bits)
    if isinstance(detail, dict):
        for key in ("state", "to", "message"):
            if detail.get(key):
                return str(detail[key])
    return ""


def do_service_action(name, action):
    unit = service_units().get(name)
    if unit is None or action not in SERVICE_ACTIONS:
        return False
    ok = run_cmd([SYSTEMCTL, "--user", action, unit])
    if ok and action == "stop" and name in STOP_EXTERNAL_SERVICES:
        # Also reap a same-service process started outside the unit:
        # a unit stop alone cannot see it (it keeps the port and VRAM).
        run_cmd([SERVICE_CLI, "stop-external", name])
    return ok


def do_app_action(app, action):
    unit = app_unit(app["id"])
    if action == "start":
        if unit_is_active(unit):
            return True
        cmd = [SYSTEMD_RUN, "--user", "--unit=" + unit]
        if app.get("workdir"):
            cmd.append("--working-directory=" + app["workdir"])
        cmd.append("--")
        cmd.extend(app.get("exec_argv") or [])
        return run_cmd(cmd)
    if action == "stop":
        if unit_is_active(unit):
            run_cmd([SYSTEMCTL, "--user", "stop", unit])
        # An instance started outside the unit (terminal/desktop)
        # is invisible to systemctl; reap it through the helper,
        # which only ever TERMs a listener on the app's own port
        # whose cwd/cmdline matches the app. Exit 3 (none found)
        # is the normal case for unit-managed apps.
        run_cmd([SERVICE_CLI, "stop-app-external", app["id"]], timeout=40)
        return not unit_is_active(unit)
    return False


def do_model_select(name):
    if not run_cmd([MODEL_CLI, "use", name]):
        return False
    unit = service_units().get("llama-server")
    if unit is None:
        return False
    return run_cmd([SYSTEMCTL, "--user", "restart", unit])


CSS = """
window, .root {
    background-color: #f5f0e6;
    color: #2b2b28;
    font-family: "Noto Sans CJK JP", sans-serif;
}
.header {
    padding: 14px 18px 6px 18px;
}
.title {
    font-family: "Noto Serif CJK JP", serif;
    font-size: 22px;
    font-weight: bold;
    letter-spacing: 3px;
}
.subtitle {
    color: #6f6a5c;
    font-size: 11px;
}
.card {
    background-color: #fffdf8;
    border: 1px solid #ddd3bd;
    border-radius: 10px;
    padding: 12px 14px;
    margin: 6px 14px;
}
.card-title {
    font-family: "Noto Serif CJK JP", serif;
    font-size: 13px;
    font-weight: bold;
    color: #574f3d;
    letter-spacing: 2px;
    margin-bottom: 6px;
}
.row {
    padding: 5px 2px;
}
.name {
    font-size: 13px;
    font-weight: bold;
}
.meta {
    color: #6f6a5c;
    font-size: 11px;
}
button {
    background-image: none;
    background-color: #efe8d8;
    border: 1px solid #cfc3a6;
    border-radius: 6px;
    color: #2b2b28;
    padding: 3px 10px;
    font-size: 12px;
}
button:hover {
    background-color: #e6dcc4;
}
button:disabled {
    color: #a39c8a;
    background-color: #f3eee1;
}
button.accent {
    background-color: #b54434;
    border-color: #9c382a;
    color: #fffdf8;
}
button.accent:hover {
    background-color: #c55040;
}
.card.drop-active {
    border: 2px solid #b54434;
    background-color: #fdf3ec;
}
.dnd-wrap {
    background: transparent;
}
.drag-hint {
    color: #a39c8a;
    font-size: 13px;
}
.sep {
    background-color: #e3dac4;
    min-height: 1px;
    margin: 4px 0;
}
"""


def build_window(app):
    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import Gdk, GLib, Gtk

    win = Gtk.ApplicationWindow(application=app)
    win.set_title("HANARE")
    win.set_default_size(920, 680)

    # Update policy: the snapshot is refreshed by the 60 s capture
    # timer in the background, and this window re-reads it every
    # 60 s. On top of that, opening the panel and every user action
    # run one capture pass immediately (in a thread, so the UI never
    # freezes) and refresh as soon as it lands. capture.sh itself
    # flock-serializes passes, and the flags below coalesce bursts.
    capture_state = {"running": False, "pending": False}

    def capture_now_async():
        if capture_state["running"]:
            capture_state["pending"] = True
            return
        capture_state["running"] = True

        def _work():
            try:
                subprocess.run(
                    ["/usr/bin/bash", CAPTURE_CLI],
                    capture_output=True,
                    timeout=60,
                )
            except (OSError, subprocess.SubprocessError):
                pass
            capture_state["running"] = False
            again = capture_state["pending"]
            capture_state["pending"] = False
            GLib.idle_add(refresh)
            if again:
                GLib.idle_add(capture_now_async)

        threading.Thread(target=_work, daemon=True).start()

    win.capture_now_async = capture_now_async

    provider = Gtk.CssProvider()
    provider.load_from_data(CSS.encode("utf-8"))
    Gtk.StyleContext.add_provider_for_screen(
        win.get_screen(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )

    root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    root.get_style_context().add_class("root")
    win.add(root)

    header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
    header.get_style_context().add_class("header")
    title = Gtk.Label(label="HANARE")
    title.get_style_context().add_class("title")
    header.pack_start(title, False, False, 0)
    header_dot = Gtk.Label(label="●")
    header.pack_start(header_dot, False, False, 0)
    header_meta = Gtk.Label(label="")
    header_meta.get_style_context().add_class("subtitle")
    header.pack_end(header_meta, False, False, 0)
    root.pack_start(header, False, False, 0)

    scroller = Gtk.ScrolledWindow()
    scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    root.pack_start(scroller, True, True, 0)
    content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    scroller.add(content)
    dynamic = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    content.pack_start(dynamic, False, False, 0)

    def clear(box):
        for child in box.get_children():
            box.remove(child)

    def make_card(heading):
        frame = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        frame.get_style_context().add_class("card")
        label = Gtk.Label(label=heading, xalign=0)
        label.get_style_context().add_class("card-title")
        frame.pack_start(label, False, False, 0)
        dynamic.pack_start(frame, False, False, 0)
        return frame

    def dot_label(state):
        label = Gtk.Label()
        color = STATE_COLORS.get(state, "#8a8578")
        label.set_markup('<span foreground="%s">●</span>' % color)
        return label

    def action_button(text, sensitive, callback, accent=False):
        button = Gtk.Button(label=text)
        button.set_sensitive(sensitive)
        if accent:
            button.get_style_context().add_class("accent")
        button.connect("clicked", callback)
        return button


    # ---- settings card (static shell; only its service list refreshes) --
    settings_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    settings_card.get_style_context().add_class("card")
    settings_title = Gtk.Label(label="サービス設定（レジストリ）", xalign=0)
    settings_title.get_style_context().add_class("card-title")
    settings_card.pack_start(settings_title, False, False, 0)
    settings_hint = Gtk.Label(
        label="services/services.tsv が唯一の定義場所です。保存するとユニット生成と daemon-reload まで行います（起動コマンドが空欄のサービスは手管理ユニット扱い）。",
        xalign=0,
    )
    settings_hint.get_style_context().add_class("meta")
    settings_card.pack_start(settings_hint, False, False, 0)
    content.pack_start(settings_card, False, False, 0)

    settings_list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    settings_card.pack_start(settings_list, False, False, 0)

    def labeled_entry(label_text, parent):
        row_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        row_box.get_style_context().add_class("row")
        lab = Gtk.Label(label=label_text, xalign=0)
        lab.set_size_request(110, -1)
        lab.get_style_context().add_class("meta")
        entry = Gtk.Entry()
        row_box.pack_start(lab, False, False, 0)
        row_box.pack_start(entry, True, True, 0)
        parent.pack_start(row_box, False, False, 0)
        return entry

    launcher_items = scan_launchers()
    launcher_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    launcher_row.get_style_context().add_class("row")
    launcher_lab = Gtk.Label(label="アイコンから選ぶ", xalign=0)
    launcher_lab.set_size_request(110, -1)
    launcher_lab.get_style_context().add_class("meta")
    launcher_row.pack_start(launcher_lab, False, False, 0)
    launcher_combo = Gtk.ComboBoxText()
    launcher_combo.append("", "（デスクトップのアイコン）")
    for _i, _item in enumerate(launcher_items):
        launcher_combo.append(str(_i), _item["name"])
    launcher_combo.set_active(0)
    launcher_row.pack_start(launcher_combo, True, True, 0)
    launcher_warn = Gtk.Label(label="", xalign=0)
    launcher_warn.set_line_wrap(True)
    launcher_warn.get_style_context().add_class("meta")

    def on_load_launcher(_button):
        active_id = launcher_combo.get_active_id()
        if not active_id:
            settings_status.set_text("先にアイコンを選んでください")
            return
        item = launcher_items[int(active_id)]
        svc_entries["display"].set_text(item["name"])
        svc_entries["exec"].set_text(item["exec"])
        svc_entries["workdir"].set_text(item["workdir"] or "")
        if not svc_entries["name"].get_text().strip() and item["id_suggestion"]:
            svc_entries["name"].set_text(item["id_suggestion"])
        if item["wrapper"]:
            launcher_warn.set_text(
                "注意: 起動コマンドに %s が含まれます。人間用ラッパー（端末やブラウザを開く係）の可能性があります。サービス本体のコマンドか確認してください。"
                % item["wrapper"]
            )
        else:
            launcher_warn.set_text("")
        settings_status.set_text(
            "アイコン「%s」を読み込みました（ポートとURLは手入力です）"
            % item["name"]
        )

    launcher_btn = Gtk.Button(label="読み込む")
    launcher_btn.connect("clicked", on_load_launcher)
    launcher_row.pack_start(launcher_btn, False, False, 0)
    settings_card.pack_start(launcher_row, False, False, 0)
    settings_card.pack_start(launcher_warn, False, False, 0)

    svc_entries = {
        "name": labeled_entry("サービス名（英小文字）", settings_card),
        "display": labeled_entry("表示名", settings_card),
        "port": labeled_entry("ポート", settings_card),
        "exec": labeled_entry("起動コマンド", settings_card),
        "workdir": labeled_entry("作業フォルダ", settings_card),
        "url": labeled_entry("URL", settings_card),
    }
    svc_entries["exec"].set_placeholder_text(
        "例: python3 -m http.server 8899 --bind 127.0.0.1（空欄 = 手管理ユニット）"
    )
    svc_entries["url"].set_placeholder_text(
        "空欄ならポートから自動入力（例: http://127.0.0.1:8765/）"
    )
    url_auto_state = {"last": ""}

    def on_port_changed(_entry):
        current_url = svc_entries["url"].get_text()
        if current_url == "" or current_url == url_auto_state["last"]:
            new_url = auto_url_for_port(svc_entries["port"].get_text())
            url_auto_state["last"] = new_url
            if current_url != new_url:
                svc_entries["url"].set_text(new_url)

    svc_entries["port"].connect("changed", on_port_changed)
    settings_status = Gtk.Label(label="", xalign=0)
    settings_status.get_style_context().add_class("meta")

    drag_state = {"active": False, "pressed": False}
    demote_state = {"text": ""}

    def scroll_to_settings():
        def _do():
            try:
                coords = settings_card.translate_coordinates(content, 0, 0)
                if coords is not None:
                    adj = scroller.get_vadjustment()
                    target = coords[1] - 8
                    upper = adj.get_upper() - adj.get_page_size()
                    adj.set_value(max(0.0, min(target, max(upper, 0.0))))
            except Exception:
                pass
            return False

        GLib.idle_add(_do)

    def apply_app_prefill(app_item):
        pre = app_to_service_prefill(app_item)
        svc_entries["name"].set_text(pre["name"])
        svc_entries["display"].set_text(pre["display"])
        svc_entries["port"].set_text(pre["port"])
        svc_entries["exec"].set_text(pre["exec"])
        svc_entries["workdir"].set_text(pre["workdir"])
        svc_entries["url"].set_text(pre["url"])
        if pre["wrapper"]:
            launcher_warn.set_text(
                "注意: 起動コマンドに %s が含まれます。人間用ラッパー（端末やブラウザを開く係）の可能性があります。サービス本体のコマンドか確認してください。"
                % pre["wrapper"]
            )
        else:
            launcher_warn.set_text("")
        if pre["conflict"]:
            settings_status.set_text(
                "アプリ「%s」を取り込みました。サービス名「%s」は既に登録済みのため編集として扱います。内容を確認して保存してください"
                % (pre["display"], pre["name"])
            )
        else:
            settings_status.set_text(
                "アプリ「%s」を取り込みました。内容を確認して保存してください"
                % pre["display"]
            )
        scroll_to_settings()

    def fill_service_form(row):
        svc_entries["name"].set_text(row.get("name") or "")
        svc_entries["display"].set_text(row.get("display") or "")
        svc_entries["port"].set_text(str(row.get("port") or ""))
        exec_val = row.get("exec") or ""
        svc_entries["exec"].set_text("" if exec_val == "-" else exec_val)
        wd_val = row.get("workdir") or ""
        svc_entries["workdir"].set_text("" if wd_val == "-" else wd_val)
        url_val = row.get("url") or ""
        svc_entries["url"].set_text("" if url_val == "-" else url_val)

    def on_save_service(_button):
        form = {key: entry.get_text() for key, entry in svc_entries.items()}
        if not form["exec"].strip():
            form["exec"] = "-"
            form["unit"] = "hanare-%s" % form["name"].strip()
        _ok, message = upsert_service(form)
        settings_status.set_text(message)
        refresh()

    def on_remove_service(_button, svc_name):
        _ok, message = remove_service(svc_name)
        settings_status.set_text(message)
        refresh()

    save_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    save_btn = Gtk.Button(label="サービスを保存")
    save_btn.get_style_context().add_class("accent")
    save_btn.connect("clicked", on_save_service)
    save_row.pack_start(save_btn, False, False, 0)
    save_row.pack_start(settings_status, True, True, 0)
    settings_card.pack_start(save_row, False, False, 0)

    model_title = Gtk.Label(label="モデル追加", xalign=0)
    model_title.get_style_context().add_class("card-title")
    settings_card.pack_start(model_title, False, False, 0)
    model_entries = {
        "name": labeled_entry("モデル名", settings_card),
        "gguf": labeled_entry("GGUFパス", settings_card),
        "ctx": labeled_entry("ctx", settings_card),
        "mmproj": labeled_entry("mmproj（任意）", settings_card),
    }

    def on_add_model(_button):
        form = {key: entry.get_text() for key, entry in model_entries.items()}
        ok, message = add_model(form)
        settings_status.set_text(message)
        if ok:
            for entry in model_entries.values():
                entry.set_text("")
        refresh()

    model_btn = Gtk.Button(label="モデルを追加")
    model_btn.connect("clicked", on_add_model)
    model_btn_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    model_btn_row.pack_start(model_btn, False, False, 0)
    settings_card.pack_start(model_btn_row, False, False, 0)

    def rebuild_settings_list(rows):
        clear(settings_list)
        for row in rows:
            line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            line.get_style_context().add_class("row")
            text = "%s · %s · :%s · %s" % (
                row.get("name"),
                row.get("display") or row.get("name"),
                row.get("port"),
                row.get("unit"),
            )
            if (row.get("exec") or "-") == "-":
                text += " · 手管理ユニット"
            lab = Gtk.Label(label=text, xalign=0)
            lab.get_style_context().add_class("meta")
            line.pack_start(lab, True, True, 0)
            line.pack_end(
                action_button(
                    "削除", True,
                    lambda _b, n=row.get("name"): on_remove_service(_b, n),
                ),
                False, False, 0,
            )
            line.pack_end(
                action_button(
                    "編集", True,
                    lambda _b, r=dict(row): fill_service_form(r),
                ),
                False, False, 0,
            )
            settings_list.pack_start(line, False, False, 0)
        settings_list.show_all()

    def refresh(*_args):
        if drag_state["active"] or drag_state.get("pressed"):
            # A press/drag is in flight: rebuilding now would destroy
            # the drag source mid-gesture. Skip this cycle only.
            return True
        data = collect_model()
        worst = worst_state(data["services"])
        header_dot.set_markup(
            '<span foreground="%s">●</span>'
            % STATE_COLORS.get(worst, "#8a8578")
        )
        mem = data["memory"]
        gpu_bits = []
        for gpu in data["gpus"]:
            gpu_bits.append(
                "%s %s/%s MiB"
                % (
                    "V100" if "V100" in (gpu.get("name") or "") else "GPU",
                    gpu.get("memory_used_mib"),
                    gpu.get("memory_total_mib"),
                )
            )
        if mem:
            gpu_bits.append(
                "RAM %s/%s MiB" % (mem.get("ram_used_mib"), mem.get("ram_total_mib"))
            )
        stamp = (data["timestamp"] or "")[11:16]
        header_meta.set_text(" · ".join(gpu_bits + ([stamp] if stamp else [])))

        clear(dynamic)

        reg_map = {r["name"]: r for r in load_service_registry()}
        svc_card = make_card("サービス")
        svc_eb = Gtk.EventBox()
        svc_eb.get_style_context().add_class("dnd-wrap")
        svc_eb.set_visible_window(True)
        _svc_parent = svc_card.get_parent()
        _svc_parent.remove(svc_card)
        svc_eb.add(svc_card)
        _svc_parent.pack_start(svc_eb, False, False, 0)
        _svc_parent.reorder_child(svc_eb, 0)
        svc_eb.drag_dest_set(
            Gtk.DestDefaults.ALL,
            [Gtk.TargetEntry.new("text/plain", Gtk.TargetFlags.SAME_APP, 0)],
            Gdk.DragAction.COPY,
        )

        def on_svc_drag_motion(widget, context, _x, _y, time):
            svc_card.get_style_context().add_class("drop-active")
            Gdk.drag_status(context, Gdk.DragAction.COPY, time)
            return True

        def on_svc_drag_leave(widget, _context, _time):
            svc_card.get_style_context().remove_class("drop-active")

        def on_svc_drag_data_received(
            widget, context, _x, _y, selection, _info, time
        ):
            svc_card.get_style_context().remove_class("drop-active")
            payload = (selection.get_text() or "").strip()
            if payload.startswith("svc:"):
                Gtk.drag_finish(context, False, False, time)
                return
            app_id = payload[4:] if payload.startswith("app:") else payload
            found = None
            for candidate in data["apps"]:
                if candidate.get("id") == app_id:
                    found = candidate
                    break
            if found is not None:
                apply_app_prefill(found)
            Gtk.drag_finish(context, found is not None, False, time)

        svc_eb.connect("drag-motion", on_svc_drag_motion)
        svc_eb.connect("drag-leave", on_svc_drag_leave)
        svc_eb.connect("drag-data-received", on_svc_drag_data_received)
        svc_hint = Gtk.Label(
            label="ヒント: 下の「アプリ」の行をここへドラッグ（またはアプリの行をクリック）すると、サービス登録フォームに取り込めます。サービスの行は下の「アプリ」へドラッグすると下ろせます",
            xalign=0,
        )
        svc_hint.get_style_context().add_class("meta")
        svc_card.pack_start(svc_hint, False, False, 0)
        for svc in data["services"]:
            name = svc["name"]
            state = svc.get("state") or "stopped"
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            row.get_style_context().add_class("row")
            _reg_row = reg_map.get(name) or {}
            demotable = (_reg_row.get("exec") or "-") != "-"
            if demotable:
                hint = Gtk.Label(label="\u2261")
                hint.get_style_context().add_class("drag-hint")
                row.pack_start(hint, False, False, 0)
            row.pack_start(dot_label(state), False, False, 0)
            texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            name_label = Gtk.Label(label=name, xalign=0)
            name_label.get_style_context().add_class("name")
            texts.pack_start(name_label, False, False, 0)
            meta_bits = [state]
            if svc.get("external"):
                meta_bits.append("管理外")
            elapsed = format_elapsed(svc.get("elapsed_sec"))
            if state == "running" and elapsed:
                meta_bits.append("稼働 %s" % elapsed)
            if svc.get("port"):
                meta_bits.append(":%s" % svc["port"])
            if name == "llama-server" and data["current_model"]:
                meta_bits.append(data["current_model"])
            meta = Gtk.Label(label=" · ".join(meta_bits), xalign=0)
            meta.get_style_context().add_class("meta")
            texts.pack_start(meta, False, False, 0)
            row.pack_start(texts, True, True, 0)
            running = state in ("running", "degraded", "stuck-suspect")
            row.pack_end(
                action_button(
                    "再起動",
                    True,
                    lambda _b, n=name: (do_service_action(n, "restart"), capture_now_async()),
                ),
                False, False, 0,
            )
            if running:
                row.pack_end(
                    action_button(
                        "停止",
                        True,
                        lambda _b, n=name: (do_service_action(n, "stop"), capture_now_async()),
                    ),
                    False, False, 0,
                )
            else:
                row.pack_end(
                    action_button(
                        "起動",
                        True,
                        lambda _b, n=name: (do_service_action(n, "start"), capture_now_async()),
                        accent=True,
                    ),
                    False, False, 0,
                )
            if demotable:
                seb = Gtk.EventBox()
                seb.get_style_context().add_class("dnd-wrap")
                seb.set_visible_window(True)
                seb.set_tooltip_text(
                    "下の「アプリ」カードへドラッグすると、サービス登録を解除してアプリへ下ろせます（稼働中は不可）"
                )
                seb.drag_source_set(
                    Gdk.ModifierType.BUTTON1_MASK,
                    [Gtk.TargetEntry.new("text/plain", Gtk.TargetFlags.SAME_APP, 0)],
                    Gdk.DragAction.COPY,
                )

                def on_svc_drag_begin(_w, _c):
                    drag_state["active"] = True

                def on_svc_drag_data_get(_w, _c, selection, _i, _t, _n=name):
                    selection.set_text("svc:" + _n, -1)

                def on_svc_drag_end(_w, _c):
                    drag_state["active"] = False
                    drag_state["pressed"] = False

                seb.connect("drag-begin", on_svc_drag_begin)
                seb.connect("drag-data-get", on_svc_drag_data_get)
                seb.connect("drag-end", on_svc_drag_end)
                seb.add(row)
                svc_card.pack_start(seb, False, False, 0)
            else:
                svc_card.pack_start(row, False, False, 0)

        model_card = make_card("モデル（選択すると llama が再起動します）")
        for model in data["models"]:
            is_current = model["name"] == data["current_model"]
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            row.get_style_context().add_class("row")
            marker = Gtk.Label()
            if is_current:
                marker.set_markup('<span foreground="#58a34c">●</span>')
            else:
                marker.set_text("○")
            row.pack_start(marker, False, False, 0)
            label = Gtk.Label(
                label="%s · %s" % (model["name"], format_ctx(model["ctx"])),
                xalign=0,
            )
            label.get_style_context().add_class("name" if is_current else "meta")
            row.pack_start(label, True, True, 0)
            if not is_current:
                row.pack_end(
                    action_button(
                        "選択",
                        True,
                        lambda _b, n=model["name"]: (do_model_select(n), capture_now_async()),
                    ),
                    False, False, 0,
                )
            model_card.pack_start(row, False, False, 0)
        if not data["models"]:
            empty = Gtk.Label(label="モデル一覧なし", xalign=0)
            empty.get_style_context().add_class("meta")
            model_card.pack_start(empty, False, False, 0)

        app_card = make_card("アプリ")
        app_eb = Gtk.EventBox()
        app_eb.get_style_context().add_class("dnd-wrap")
        app_eb.set_visible_window(True)
        _app_parent = app_card.get_parent()
        _app_parent.remove(app_card)
        app_eb.add(app_card)
        _app_parent.pack_start(app_eb, False, False, 0)
        app_eb.drag_dest_set(
            Gtk.DestDefaults.ALL,
            [Gtk.TargetEntry.new("text/plain", Gtk.TargetFlags.SAME_APP, 0)],
            Gdk.DragAction.COPY,
        )

        def on_app_dest_motion(widget, context, _x, _y, time):
            app_card.get_style_context().add_class("drop-active")
            Gdk.drag_status(context, Gdk.DragAction.COPY, time)
            return True

        def on_app_dest_leave(widget, _context, _time):
            app_card.get_style_context().remove_class("drop-active")

        def on_app_dest_data_received(
            widget, context, _x, _y, selection, _info, time
        ):
            app_card.get_style_context().remove_class("drop-active")
            payload = (selection.get_text() or "").strip()
            ok = False
            if payload.startswith("svc:"):
                svc_name = payload[4:]
                svc_entry = None
                for cand in data["services"]:
                    if cand.get("name") == svc_name:
                        svc_entry = cand
                        break
                if svc_entry is not None:
                    svc_state = svc_entry.get("state") or "stopped"
                    if svc_state in ("running", "degraded", "stuck-suspect"):
                        demote_state["text"] = (
                            "サービス「%s」は稼働中のため下ろせません。先に停止してください"
                            % svc_name
                        )
                    else:
                        ok, demote_state["text"] = demote_service_to_app(svc_name)
            Gtk.drag_finish(context, ok, False, time)
            refresh()

        app_eb.connect("drag-motion", on_app_dest_motion)
        app_eb.connect("drag-leave", on_app_dest_leave)
        app_eb.connect("drag-data-received", on_app_dest_data_received)
        if demote_state.get("text"):
            demote_label = Gtk.Label(label=demote_state["text"], xalign=0)
            demote_label.get_style_context().add_class("meta")
            app_card.pack_start(demote_label, False, False, 0)
        for app_item in data["apps"]:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            row.get_style_context().add_class("row")
            hint = Gtk.Label(label="\u2261")
            hint.get_style_context().add_class("drag-hint")
            row.pack_start(hint, False, False, 0)
            row.pack_start(
                dot_label(
                    "running"
                    if app_item["active"] or app_item.get("external")
                    else "stopped"
                ),
                False, False, 0,
            )
            texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            name_label = Gtk.Label(
                label="%s" % (app_item.get("name") or app_item["id"]), xalign=0
            )
            name_label.get_style_context().add_class("name")
            texts.pack_start(name_label, False, False, 0)
            if app_item["active"]:
                app_state_text = "起動中"
            elif app_item.get("external"):
                app_state_text = "起動中 · 管理外"
            else:
                app_state_text = "停止中"
            meta = Gtk.Label(
                label="%s · %s" % (app_item.get("source", ""), app_state_text),
                xalign=0,
            )
            meta.get_style_context().add_class("meta")
            texts.pack_start(meta, False, False, 0)
            row.pack_start(texts, True, True, 0)
            # Gtk.Box has no GdkWindow, so it cannot receive the X11
            # press events a drag starts from. Wrap the row in an
            # EventBox (own window) and make THAT the drag source.
            eb = Gtk.EventBox()
            eb.get_style_context().add_class("dnd-wrap")
            eb.set_visible_window(True)
            eb.set_tooltip_text(
                "「サービス」カードへドラッグ（またはクリック）すると、サービス登録フォームに取り込めます"
            )
            eb.drag_source_set(
                Gdk.ModifierType.BUTTON1_MASK,
                [Gtk.TargetEntry.new("text/plain", Gtk.TargetFlags.SAME_APP, 0)],
                Gdk.DragAction.COPY,
            )

            def _over_button(ev, _row=row):
                for child in _row.get_children():
                    if isinstance(child, Gtk.Button):
                        alloc = child.get_allocation()
                        if (
                            alloc.x <= ev.x <= alloc.x + alloc.width
                            and alloc.y <= ev.y <= alloc.y + alloc.height
                        ):
                            return True
                return False

            def on_app_press(_widget, event):
                if not _over_button(event):
                    drag_state["pressed"] = True
                return False

            def on_app_release(_widget, event, _item=app_item):
                was_pressed = drag_state.get("pressed")
                drag_state["pressed"] = False
                # Plain click (no drag happened): same import as a drop.
                if was_pressed and not drag_state["active"] and not _over_button(event):
                    apply_app_prefill(_item)
                return False

            def on_app_drag_begin(_widget, _context, _aid=app_item["id"]):
                drag_state["active"] = True

            def on_app_drag_data_get(
                _widget, _context, selection, _info, _time,
                _aid=app_item["id"],
            ):
                selection.set_text("app:" + _aid, -1)

            def on_app_drag_end(_widget, _context):
                drag_state["active"] = False
                drag_state["pressed"] = False

            eb.connect("button-press-event", on_app_press)
            eb.connect("button-release-event", on_app_release)
            eb.connect("drag-begin", on_app_drag_begin)
            eb.connect("drag-data-get", on_app_drag_data_get)
            eb.connect("drag-end", on_app_drag_end)
            eb.add(row)
            if app_item["active"] or app_item.get("external"):
                row.pack_end(
                    action_button(
                        "停止",
                        True,
                        lambda _b, a=app_item: (do_app_action(a, "stop"), capture_now_async()),
                    ),
                    False, False, 0,
                )
            else:
                row.pack_end(
                    action_button(
                        "起動",
                        True,
                        lambda _b, a=app_item: (do_app_action(a, "start"), capture_now_async()),
                        accent=True,
                    ),
                    False, False, 0,
                )
            app_card.pack_start(eb, False, False, 0)
        if not data["apps"]:
            empty = Gtk.Label(label="アプリなし（~/hanare-apps/ に置くと出ます）", xalign=0)
            empty.get_style_context().add_class("meta")
            app_card.pack_start(empty, False, False, 0)

        ev_card = make_card("最新の動き")
        for event in data["events"]:
            ts = (event.get("ts") or "")[11:16]
            text = "%s  %s · %s · %s" % (
                ts,
                event.get("kind", ""),
                event.get("actor", ""),
                event.get("name", ""),
            )
            summary = event_summary(event)
            if summary:
                text += " — " + summary
            label = Gtk.Label(label=text, xalign=0)
            label.get_style_context().add_class("meta")
            ev_card.pack_start(label, False, False, 0)
        if not data["events"]:
            empty = Gtk.Label(label="イベントなし", xalign=0)
            empty.get_style_context().add_class("meta")
            ev_card.pack_start(empty, False, False, 0)

        rebuild_settings_list(data["registry"])
        content.show_all()
        return True

    refresh()
    capture_now_async()
    GLib.timeout_add_seconds(60, refresh)
    win.show_all()
    return win


def main():
    if "--dump" in sys.argv:
        print(json.dumps(collect_model(), ensure_ascii=False, indent=1))
        return 0
    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import Gio, Gtk

    class PanelApp(Gtk.Application):
        def __init__(self):
            super().__init__(
                application_id="org.hanare.panel",
                flags=Gio.ApplicationFlags.FLAGS_NONE,
            )

        def do_activate(self):
            win = self.get_active_window()
            if win is None:
                win = build_window(self)
            else:
                capture_now = getattr(win, "capture_now_async", None)
                if capture_now is not None:
                    capture_now()
            win.present()

    return PanelApp().run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
