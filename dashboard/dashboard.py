#!/usr/bin/env python3
"""HANARE dashboard.

Serves a single auto-refreshing HTML page on 127.0.0.1 that renders the
latest status snapshot and recent events, plus controls for starting,
stopping and restarting the comfyui / llama services and selecting the
llama model. Actions run through a fixed allowlist with argv arrays and
no shell.
"""

import html
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

DASH_DIR = os.path.dirname(os.path.abspath(__file__))
if DASH_DIR not in sys.path:
    sys.path.insert(0, DASH_DIR)
from discovery import discover  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SNAP_PATH = os.environ.get(
    "HANARE_STATUS_SNAP", os.path.join(REPO_ROOT, "runtime", "last-status.json")
)
EVENTS_PATH = os.environ.get(
    "HANARE_EVENT_LOG", os.path.join(REPO_ROOT, "runtime", "events.jsonl")
)
MODELS_TSV = os.path.join(REPO_ROOT, "models", "models.tsv")
CURRENT_MODEL_FILE = os.path.join(REPO_ROOT, "runtime", "current-model")
SYSTEMCTL = os.environ.get("HANARE_SYSTEMCTL", "systemctl")
SERVICE_CLI = os.environ.get(
    "HANARE_SERVICE_CLI", os.path.join(REPO_ROOT, "scripts", "hanare-service.sh")
)
SYSTEMD_RUN = os.environ.get("HANARE_SYSTEMD_RUN", "systemd-run")
MODEL_CLI = os.environ.get(
    "HANARE_MODEL_CLI", os.path.join(REPO_ROOT, "scripts", "hanare-model.sh")
)
APPS_DIR = os.environ.get("HANARE_APPS_DIR", os.path.join(REPO_ROOT, "apps.d"))
APPS_DROP_DIR = os.path.expanduser(
    os.environ.get("HANARE_APPS_DROP_DIR", "~/hanare-apps")
)
# Desktop launcher auto-import is opt-in (user decision 2026-11-03):
# by default only apps.d registrations and the ~/hanare-apps drop folder
# are listed. Set HANARE_DESKTOP_SCAN=1 to also scan .desktop launchers.
DESKTOP_DIRS = (
    [
        os.path.expanduser(d.strip())
        for d in os.environ.get(
            "HANARE_DESKTOP_DIRS", "~/デスクトップ:~/.local/share/applications"
        ).split(":")
        if d.strip()
    ]
    if os.environ.get("HANARE_DESKTOP_SCAN") == "1"
    else []
)
ACTION_TIMEOUT = 15
PORT = int(os.environ.get("HANARE_DASH_PORT", "8790"))
MAX_EVENTS = 30

SERVICE_UNITS = {
    "comfyui": "hanare-comfyui",
    "llama-server": "hanare-llama",
}
SERVICE_ACTIONS = ("start", "stop", "restart")

STATE_CLASSES = {
    "running": "st-running",
    "stopped": "st-stopped",
    "degraded": "st-degraded",
    "stuck-suspect": "st-stuck-suspect",
}


def unit_is_active(unit):
    try:
        st = subprocess.run(
            [SYSTEMCTL, "--user", "is-active", unit],
            capture_output=True,
            text=True,
            timeout=ACTION_TIMEOUT,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return st.stdout.strip() == "active"


def service_is_external(svc):
    """True when a snapshot service runs outside its systemd unit."""
    if not isinstance(svc, dict):
        return False
    unit = SERVICE_UNITS.get(svc.get("name"))
    if unit is None:
        return False
    if svc.get("state") not in ("running", "degraded", "stuck-suspect"):
        return False
    if not svc.get("pid"):
        return False
    return not unit_is_active(unit)


def run_stop_external(service):
    """Reap a same-service process that the unit stop cannot see."""
    try:
        proc = subprocess.run(
            [SERVICE_CLI, "stop-external", service],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return {"result": "error", "detail": "helper failed to run"}
    out = (proc.stdout or "").strip()
    if proc.returncode == 0:
        return {"result": "stopped", "detail": out}
    if proc.returncode == 3:
        return {"result": "none", "detail": out}
    if proc.returncode == 4:
        return {"result": "refused", "detail": out}
    return {"result": "still-running", "detail": out}


def esc(value):
    return html.escape(str(value), quote=True)


def js_str(value):
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


def load_snapshot():
    try:
        with open(SNAP_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return None
        return data
    except (OSError, ValueError):
        return None


def load_events():
    events = []
    try:
        with open(EVENTS_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return events
    for line in lines[-MAX_EVENTS:]:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict):
            events.append(ev)
    events.reverse()
    return events


def load_models():
    models = []
    try:
        with open(MODELS_TSV, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return models
    for line in lines[1:]:
        name = line.rstrip("\n").split("\t")[0].strip()
        if name:
            models.append(name)
    return models


def current_model():
    try:
        with open(CURRENT_MODEL_FILE, "r", encoding="utf-8") as f:
            name = f.read().strip()
        if name:
            return name
    except OSError:
        pass
    models = load_models()
    return models[0] if models else ""


def app_unit(app_id):
    return "hanare-app-%s" % app_id


def scan_apps():
    try:
        os.makedirs(APPS_DROP_DIR, exist_ok=True)
    except OSError:
        pass
    return discover(APPS_DIR, APPS_DROP_DIR, DESKTOP_DIRS)


def app_is_active(unit):
    try:
        st = subprocess.run(
            [SYSTEMCTL, "--user", "is-active", unit],
            capture_output=True,
            text=True,
            timeout=ACTION_TIMEOUT,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return st.stdout.strip() == "active"


def render_page():
    snap = load_snapshot()
    parts = []
    parts.append("<!DOCTYPE html>")
    parts.append('<html lang="en">')
    parts.append("<head>")
    parts.append('<meta charset="utf-8">')
    parts.append('<meta http-equiv="refresh" content="30">')
    parts.append("<title>HANARE Dashboard</title>")
    parts.append("<style>")
    parts.append("body { font-family: monospace; background: #111; color: #ddd; margin: 1.5em; }")
    parts.append("h1 { font-size: 1.4em; } h2 { font-size: 1.1em; margin-top: 1.5em; border-bottom: 1px solid #444; }")
    parts.append("table { border-collapse: collapse; }")
    parts.append("th, td { border: 1px solid #444; padding: 0.3em 0.8em; text-align: left; }")
    parts.append("th { background: #222; }")
    parts.append(".st-running { color: #4caf50; font-weight: bold; }")
    parts.append(".st-stopped { color: #888; }")
    parts.append(".st-degraded { color: #ff9800; font-weight: bold; }")
    parts.append(".st-stuck-suspect { color: #f44336; font-weight: bold; }")
    parts.append(".muted { color: #777; }")
    parts.append("button { font-family: monospace; background: #222; color: #ddd; border: 1px solid #555; padding: 0.2em 0.8em; margin: 0 0.3em 0.3em 0; cursor: pointer; }")
    parts.append("button:hover { background: #333; }")
    parts.append(".model-cur { color: #4caf50; font-weight: bold; border-color: #4caf50; }")
    parts.append("</style>")
    parts.append("</head>")
    parts.append("<body>")
    parts.append("<h1>HANARE Dashboard</h1>")

    parts.append("<h2>Controls</h2>")
    for svc, unit in SERVICE_UNITS.items():
        btns = "".join(
            '<button onclick="doAction(%s, %s)">%s</button>'
            % (js_str(svc), js_str(action), label)
            for action, label in (
                ("start", "起動"),
                ("stop", "停止"),
                ("restart", "再起動"),
            )
        )
        parts.append("<p>%s (%s): %s</p>" % (esc(svc), esc(unit), btns))

    apps = scan_apps()
    parts.append("<h2>アプリ</h2>")
    if apps:
        for app in apps:
            unit = app_unit(app["id"])
            active = app_is_active(unit)
            state = (
                '<span class="st-running">起動中</span>'
                if active
                else '<span class="st-stopped">停止中</span>'
            )
            btns = (
                '<button onclick="doApp(%s, %s)">起動</button>'
                % (js_str(app["id"]), js_str("start"))
            ) + (
                '<button onclick="doApp(%s, %s)">停止</button>'
                % (js_str(app["id"]), js_str("stop"))
            )
            link = ' <a href="%s">開く</a>' % esc(app["url"]) if app["url"] else ""
            note = " — %s" % esc(app["note"]) if app["note"] else ""
            source = "（%s）" % esc(app["source"]) if app.get("source") else ""
            parts.append(
                "<p>%s%s%s: %s %s%s</p>"
                % (esc(app["name"]), source, note, state, btns, link)
            )
    else:
        parts.append('<p class="muted">no apps registered</p>')

    cur = current_model()
    parts.append("<h2>モデル</h2>")
    parts.append('<p class="muted">llama 再起動後に反映</p>')
    models = load_models()
    if models:
        for name in models:
            cls = " model-cur" if name == cur else ""
            mark = "● " if name == cur else ""
            parts.append(
                '<button class="model-btn%s" onclick="doModel(%s)">%s%s</button>'
                % (cls, js_str(name), mark, esc(name))
            )
    else:
        parts.append('<p class="muted">no models registered</p>')

    parts.append("<script>")
    parts.append("function postJSON(url, payload) {")
    parts.append("  return fetch(url, {")
    parts.append("    method: 'POST',")
    parts.append("    headers: {'Content-Type': 'application/json'},")
    parts.append("    body: JSON.stringify(payload)")
    parts.append("  });")
    parts.append("}")
    parts.append("function doAction(service, action) {")
    parts.append("  postJSON('/action', {service: service, action: action})")
    parts.append("    .then(function (r) { return r.json().then(function (d) { return {status: r.status, d: d}; }); })")
    parts.append("    .then(function (x) { if (x.status !== 200 || !x.d.ok) alert('action failed: ' + (x.d.unit || service)); else if (x.d.external && x.d.external.result === 'stopped') alert('管理外のプロセスも停止しました: ' + x.d.external.detail); })")
    parts.append("    .catch(function (e) { alert('request failed: ' + e); })")
    parts.append("    .then(function () { setTimeout(function () { location.reload(); }, 1500); });")
    parts.append("}")
    parts.append("function doApp(id, action) {")
    parts.append("  postJSON('/app', {id: id, action: action})")
    parts.append("    .then(function (r) { return r.json().then(function (d) { return {status: r.status, d: d}; }); })")
    parts.append("    .then(function (x) { if (x.status !== 200 || !x.d.ok) alert('app action failed: ' + (x.d.unit || id)); })")
    parts.append("    .catch(function (e) { alert('request failed: ' + e); })")
    parts.append("    .then(function () { setTimeout(function () { location.reload(); }, 1500); });")
    parts.append("}")
    parts.append("function doModel(name) {")
    parts.append("  postJSON('/model', {name: name})")
    parts.append("    .then(function (r) { return r.json().then(function (d) { return {status: r.status, d: d}; }); })")
    parts.append("    .then(function (x) { if (x.status !== 200 || !x.d.ok) alert('model selection failed: ' + (x.d.error || name)); })")
    parts.append("    .catch(function (e) { alert('request failed: ' + e); })")
    parts.append("    .then(function () { setTimeout(function () { location.reload(); }, 1500); });")
    parts.append("}")
    parts.append("</script>")

    if snap is None:
        parts.append('<p class="muted">no snapshot yet</p>')
    else:
        ts = snap.get("timestamp")
        parts.append("<p>Snapshot: %s</p>" % (esc(ts) if ts is not None else "unknown"))

        services = snap.get("services") or []
        parts.append("<h2>Services</h2>")
        if services:
            parts.append("<table>")
            parts.append("<tr><th>name</th><th>port</th><th>state</th></tr>")
            for svc in services:
                if not isinstance(svc, dict):
                    continue
                name = svc.get("name", "?")
                port = svc.get("port", "?")
                state = str(svc.get("state", "unknown"))
                cls = STATE_CLASSES.get(state, "")
                state_cell = '<span class="%s">%s</span>' % (cls, esc(state)) if cls else esc(state)
                if service_is_external(svc):
                    state_cell += ' <span class="st-degraded">管理外</span>'
                parts.append(
                    "<tr><td>%s</td><td>%s</td><td>%s</td></tr>"
                    % (esc(name), esc(port), state_cell)
                )
            parts.append("</table>")
        else:
            parts.append('<p class="muted">no services in snapshot</p>')

        gpus = snap.get("gpus") or []
        parts.append("<h2>GPUs</h2>")
        if gpus:
            parts.append("<table>")
            parts.append("<tr><th>name</th><th>util %</th><th>VRAM used/total MiB</th></tr>")
            for gpu in gpus:
                if not isinstance(gpu, dict):
                    continue
                used = gpu.get("memory_used_mib")
                total = gpu.get("memory_total_mib")
                vram = "%s / %s" % (used if used is not None else "?", total if total is not None else "?")
                parts.append(
                    "<tr><td>%s</td><td>%s</td><td>%s</td></tr>"
                    % (esc(gpu.get("name", "?")), esc(gpu.get("utilization", "?")), esc(vram))
                )
            parts.append("</table>")
        else:
            parts.append('<p class="muted">no GPU data in snapshot</p>')

        procs = snap.get("gpu_processes") or []
        parts.append("<h2>GPU processes</h2>")
        if procs:
            parts.append("<table>")
            parts.append("<tr><th>pid</th><th>name</th><th>VRAM MiB</th></tr>")
            for p in procs:
                if not isinstance(p, dict):
                    continue
                parts.append(
                    "<tr><td>%s</td><td>%s</td><td>%s</td></tr>"
                    % (
                        esc(p.get("pid", "?")),
                        esc(p.get("name", "?")),
                        esc(p.get("memory_mib", "?")),
                    )
                )
            parts.append("</table>")
        else:
            parts.append('<p class="muted">no GPU processes in snapshot</p>')

        mem = snap.get("memory") or {}
        parts.append("<h2>Memory</h2>")
        if isinstance(mem, dict) and mem:
            ram = "%s / %s MiB" % (
                mem.get("ram_used_mib", "?"),
                mem.get("ram_total_mib", "?"),
            )
            swap = "%s / %s MiB" % (
                mem.get("swap_used_mib", "?"),
                mem.get("swap_total_mib", "?"),
            )
            parts.append("<p>RAM: %s</p>" % esc(ram))
            parts.append("<p>Swap: %s</p>" % esc(swap))
        else:
            parts.append('<p class="muted">no memory data in snapshot</p>')

    events = load_events()
    parts.append("<h2>Recent events</h2>")
    if events:
        parts.append("<table>")
        parts.append("<tr><th>ts</th><th>kind</th><th>actor</th><th>name</th><th>detail</th></tr>")
        for ev in events:
            detail = ev.get("detail", "")
            if isinstance(detail, (dict, list)):
                detail_text = json.dumps(detail, separators=(",", ":"), ensure_ascii=False)
            else:
                detail_text = str(detail)
            parts.append(
                "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>"
                % (
                    esc(ev.get("ts", "?")),
                    esc(ev.get("kind", "?")),
                    esc(ev.get("actor", "?")),
                    esc(ev.get("name", "?")),
                    esc(detail_text),
                )
            )
        parts.append("</table>")
    else:
        parts.append('<p class="muted">no events yet</p>')

    parts.append("</body>")
    parts.append("</html>")
    return "\n".join(parts)


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "HanareDash/1.0"

    def _send(self, code, body, content_type="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_error_page(self, code, message):
        self._send(code, "<h1>%d</h1><p>%s</p>" % (code, esc(message)))

    def _send_json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    def _read_json_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None
        if length <= 0:
            return None
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None
        return data if isinstance(data, dict) else None

    def _run_action(self, action, unit):
        try:
            proc = subprocess.run(
                [SYSTEMCTL, "--user", action, unit],
                capture_output=True,
                text=True,
                timeout=ACTION_TIMEOUT,
            )
        except (OSError, subprocess.SubprocessError):
            return False, "unknown"
        ok = proc.returncode == 0
        active = "unknown"
        try:
            st = subprocess.run(
                [SYSTEMCTL, "--user", "is-active", unit],
                capture_output=True,
                text=True,
                timeout=ACTION_TIMEOUT,
            )
            out = st.stdout.strip()
            if out:
                active = out
        except (OSError, subprocess.SubprocessError):
            pass
        return ok, active

    def _handle_action(self):
        data = self._read_json_body()
        if data is None:
            self._send_json(400, {"ok": False, "error": "invalid JSON body"})
            return
        service = data.get("service")
        action = data.get("action")
        if not isinstance(service, str) or service not in SERVICE_UNITS:
            self._send_json(
                400,
                {"ok": False, "error": "unknown service: %s" % esc(service)},
            )
            return
        if not isinstance(action, str) or action not in SERVICE_ACTIONS:
            self._send_json(
                400,
                {"ok": False, "error": "unknown action: %s" % esc(action)},
            )
            return
        unit = SERVICE_UNITS[service]
        ok, active = self._run_action(action, unit)
        payload = {"ok": ok, "unit": unit, "active": active}
        if action == "stop" and ok:
            payload["external"] = run_stop_external(service)
        self._send_json(200, payload)

    def _handle_app(self):
        data = self._read_json_body()
        if data is None:
            self._send_json(400, {"ok": False, "error": "invalid JSON body"})
            return
        app_id = data.get("id")
        action = data.get("action")
        if not isinstance(action, str) or action not in ("start", "stop"):
            self._send_json(
                400,
                {"ok": False, "error": "unknown action: %s" % esc(action)},
            )
            return
        app = None
        for candidate in scan_apps():
            if candidate["id"] == app_id:
                app = candidate
                break
        if app is None:
            self._send_json(
                400,
                {"ok": False, "error": "unknown app: %s" % esc(app_id)},
            )
            return
        unit = app_unit(app["id"])
        if action == "start":
            if app_is_active(unit):
                self._send_json(200, {"ok": True, "unit": unit, "already_running": True})
                return
            cmd = [SYSTEMD_RUN, "--user", "--unit=" + unit]
            if app["workdir"]:
                cmd.append("--working-directory=" + app["workdir"])
            cmd.append("--")
            cmd.extend(app["exec_argv"])
            try:
                proc = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=ACTION_TIMEOUT,
                )
            except (OSError, subprocess.SubprocessError):
                self._send_json(200, {"ok": False, "unit": unit, "error": "systemd-run failed"})
                return
            ok = proc.returncode == 0
            self._send_json(200, {"ok": ok, "unit": unit})
        else:
            ok, active = self._run_action("stop", unit)
            self._send_json(200, {"ok": ok, "unit": unit, "active": active})

    def _handle_model(self):
        data = self._read_json_body()
        if data is None:
            self._send_json(400, {"ok": False, "error": "invalid JSON body"})
            return
        name = data.get("name")
        if not isinstance(name, str) or not name.strip():
            self._send_json(400, {"ok": False, "error": "invalid model name"})
            return
        try:
            proc = subprocess.run(
                [MODEL_CLI, "use", name],
                capture_output=True,
                text=True,
                timeout=ACTION_TIMEOUT,
            )
        except (OSError, subprocess.SubprocessError) as e:
            self._send_json(200, {"ok": False, "error": "model CLI failed: %s" % e})
            return
        if proc.returncode == 0:
            self._send_json(200, {"ok": True, "current": name})
        else:
            err = (proc.stderr or proc.stdout or "").strip().splitlines()
            self._send_json(
                200,
                {"ok": False, "error": err[-1] if err else "model CLI failed"},
            )

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            self._send(200, render_page())
        elif path in ("/action", "/model", "/app"):
            self._send_error_page(405, "method not allowed")
        else:
            self._send_error_page(404, "not found")

    def _method_not_allowed(self):
        self._send_error_page(405, "method not allowed")

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/action":
            self._handle_action()
        elif path == "/model":
            self._handle_model()
        elif path == "/app":
            self._handle_app()
        else:
            self._send_error_page(404, "not found")

    def do_PUT(self):
        self._method_not_allowed()

    def do_DELETE(self):
        self._method_not_allowed()

    def do_PATCH(self):
        self._method_not_allowed()

    def do_HEAD(self):
        self._method_not_allowed()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), DashboardHandler)
    print("HANARE dashboard listening on http://127.0.0.1:%d" % PORT, file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
