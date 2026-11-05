#!/usr/bin/env python3
"""HANARE panel: a small native window for the HANARE status and controls.

Design: B (wa-modern) x C (cards). Reads the same runtime files as the
topbar extension and the web dashboard (runtime/last-status.json,
runtime/events.jsonl, models/models.tsv, runtime/current-model) and acts
through the same fixed routes: systemctl --user for the two managed
services, systemd-run --user for apps, scripts/hanare-model.sh for model
selection. No shell is ever invoked.

Usage:
  hanare-panel.py           open the window
  hanare-panel.py --dump    print the data model as JSON and exit
"""

import json
import os
import subprocess
import sys

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
ACTION_TIMEOUT = 15

SERVICES = {
    "comfyui": "hanare-comfyui.service",
    "llama-server": "hanare-llama.service",
}
SERVICE_ACTIONS = ("start", "stop", "restart")

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


def run_cmd(argv):
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=ACTION_TIMEOUT
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
        result.append(item)
    return result


def collect_model():
    snap = load_snapshot()
    services = []
    for svc in snap.get("services") or []:
        if isinstance(svc, dict) and svc.get("name") in SERVICES:
            item = dict(svc)
            item["external"] = bool(
                item.get("state") in ("running", "degraded", "stuck-suspect")
                and item.get("pid")
                and not unit_is_active(SERVICES[item["name"]])
            )
            services.append(item)
    return {
        "timestamp": snap.get("timestamp"),
        "gpus": snap.get("gpus") or [],
        "memory": snap.get("memory") or {},
        "services": services,
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
    unit = SERVICES.get(name)
    if unit is None or action not in SERVICE_ACTIONS:
        return False
    ok = run_cmd([SYSTEMCTL, "--user", action, unit])
    if ok and action == "stop":
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
        return run_cmd([SYSTEMCTL, "--user", "stop", unit])
    return False


def do_model_select(name):
    if not run_cmd([MODEL_CLI, "use", name]):
        return False
    return run_cmd([SYSTEMCTL, "--user", "restart", SERVICES["llama-server"]])


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
.sep {
    background-color: #e3dac4;
    min-height: 1px;
    margin: 4px 0;
}
"""


def build_window(app):
    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import GLib, Gtk

    win = Gtk.ApplicationWindow(application=app)
    win.set_title("HANARE")
    win.set_default_size(920, 680)

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

    def clear(box):
        for child in box.get_children():
            box.remove(child)

    def make_card(heading):
        frame = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        frame.get_style_context().add_class("card")
        label = Gtk.Label(label=heading, xalign=0)
        label.get_style_context().add_class("card-title")
        frame.pack_start(label, False, False, 0)
        content.pack_start(frame, False, False, 0)
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

    def refresh(*_args):
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

        clear(content)

        svc_card = make_card("サービス")
        for svc in data["services"]:
            name = svc["name"]
            state = svc.get("state") or "stopped"
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            row.get_style_context().add_class("row")
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
                    lambda _b, n=name: (do_service_action(n, "restart"), refresh()),
                ),
                False, False, 0,
            )
            if running:
                row.pack_end(
                    action_button(
                        "停止",
                        True,
                        lambda _b, n=name: (do_service_action(n, "stop"), refresh()),
                    ),
                    False, False, 0,
                )
            else:
                row.pack_end(
                    action_button(
                        "起動",
                        True,
                        lambda _b, n=name: (do_service_action(n, "start"), refresh()),
                        accent=True,
                    ),
                    False, False, 0,
                )
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
                        lambda _b, n=model["name"]: (do_model_select(n), refresh()),
                    ),
                    False, False, 0,
                )
            model_card.pack_start(row, False, False, 0)
        if not data["models"]:
            empty = Gtk.Label(label="モデル一覧なし", xalign=0)
            empty.get_style_context().add_class("meta")
            model_card.pack_start(empty, False, False, 0)

        app_card = make_card("アプリ")
        for app_item in data["apps"]:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            row.get_style_context().add_class("row")
            row.pack_start(
                dot_label("running" if app_item["active"] else "stopped"),
                False, False, 0,
            )
            texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            name_label = Gtk.Label(
                label="%s" % (app_item.get("name") or app_item["id"]), xalign=0
            )
            name_label.get_style_context().add_class("name")
            texts.pack_start(name_label, False, False, 0)
            meta = Gtk.Label(
                label="%s · %s"
                % (
                    app_item.get("source", ""),
                    "起動中" if app_item["active"] else "停止中",
                ),
                xalign=0,
            )
            meta.get_style_context().add_class("meta")
            texts.pack_start(meta, False, False, 0)
            row.pack_start(texts, True, True, 0)
            if app_item["active"]:
                row.pack_end(
                    action_button(
                        "停止",
                        True,
                        lambda _b, a=app_item: (do_app_action(a, "stop"), refresh()),
                    ),
                    False, False, 0,
                )
            else:
                row.pack_end(
                    action_button(
                        "起動",
                        True,
                        lambda _b, a=app_item: (do_app_action(a, "start"), refresh()),
                        accent=True,
                    ),
                    False, False, 0,
                )
            app_card.pack_start(row, False, False, 0)
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

        content.show_all()
        return True

    refresh()
    GLib.timeout_add_seconds(5, refresh)
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
            win.present()

    return PanelApp().run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
