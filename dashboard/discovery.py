"""App discovery: scan registered apps, the drop dir, and desktop launchers."""

import os
import re
import shlex
from pathlib import Path

_FIELD_CODE_RE = re.compile(r"%[fFuUdDnNickVm]|%")
_NON_SLUG_RE = re.compile(r"[^a-z0-9]+")


def _slug(name):
    return _NON_SLUG_RE.sub("-", name.lower()).strip("-")


def _clean_exec(value):
    value = _FIELD_CODE_RE.sub("", value)
    try:
        argv = shlex.split(value)
    except ValueError:
        return None
    return argv or None


def _parse_app_file(path):
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    data = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip().lower()
        if key in ("name", "exec", "workdir", "url", "note"):
            data[key] = value.strip()
    if not data.get("exec"):
        return None
    argv = _clean_exec(data["exec"])
    if not argv:
        return None
    return {
        "name": data.get("name") or path.stem,
        "exec_argv": argv,
        "workdir": data.get("workdir") or None,
        "url": data.get("url") or None,
        "note": data.get("note") or "",
    }


def _parse_desktop_file(path):
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
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
    if values.get("Type") != "Application":
        return None
    name = values.get("Name")
    exec_value = values.get("Exec")
    if not name or not exec_value:
        return None
    if values.get("Hidden", "").lower() == "true":
        return None
    if values.get("NoDisplay", "").lower() == "true":
        return None
    argv = _clean_exec(exec_value)
    if not argv:
        return None
    return {
        "name": name,
        "exec_argv": argv,
        "workdir": values.get("Path") or None,
        "url": None,
        "note": "",
    }


def _folder_entry(folder):
    for candidate in ("run.sh", "start.sh"):
        path = folder / candidate
        if path.is_file():
            return [str(path)], str(folder)
    starts = sorted(p for p in folder.glob("start-*.sh") if p.is_file())
    if starts:
        return [str(starts[0])], str(folder)
    for candidate in ("app.py", "main.py"):
        path = folder / candidate
        if path.is_file():
            venv_python = folder / ".venv" / "bin" / "python"
            python = str(venv_python) if venv_python.is_file() else "python3"
            return [python, str(path)], str(folder)
    return None


def discover(apps_dir, drop_dir, desktop_dirs):
    try:
        return _discover(apps_dir, drop_dir, desktop_dirs)
    except Exception:
        return []


def _discover(apps_dir, drop_dir, desktop_dirs):
    results = []
    seen_ids = set()
    seen_exec = set()
    seen_names = set()

    def add(entry, source, id_source):
        entry_id = _slug(id_source)
        if not entry_id:
            return
        name = entry["name"]
        exec_key = " ".join(entry["exec_argv"])
        if (
            entry_id in seen_ids
            or exec_key in seen_exec
            or name.lower() in seen_names
        ):
            return
        seen_ids.add(entry_id)
        seen_exec.add(exec_key)
        seen_names.add(name.lower())
        results.append(
            {
                "id": entry_id,
                "name": name,
                "exec_argv": entry["exec_argv"],
                "workdir": entry["workdir"],
                "url": entry["url"],
                "note": entry["note"],
                "source": source,
            }
        )

    apps = Path(apps_dir) if apps_dir else None
    if apps is not None and apps.is_dir():
        for path in sorted(apps.glob("*.app")):
            try:
                if not path.is_file():
                    continue
                entry = _parse_app_file(path)
            except OSError:
                continue
            if entry is None:
                continue
            add(entry, "登録", path.stem)

    drop = Path(drop_dir) if drop_dir else None
    if drop is not None and drop.is_dir():
        try:
            entries = sorted(drop.iterdir(), key=lambda p: p.name)
        except OSError:
            entries = []
        for path in entries:
            try:
                if path.is_dir():
                    found = _folder_entry(path)
                    if found is None:
                        continue
                    argv, workdir = found
                    add(
                        {
                            "name": path.name,
                            "exec_argv": argv,
                            "workdir": workdir,
                            "url": None,
                            "note": "",
                        },
                        "自動検出",
                        path.name,
                    )
                elif path.suffix == ".desktop" and path.is_file():
                    entry = _parse_desktop_file(path)
                    if entry is None:
                        continue
                    add(entry, "自動検出", path.stem)
                elif path.is_file() and os.access(path, os.X_OK):
                    add(
                        {
                            "name": path.name,
                            "exec_argv": [str(path)],
                            "workdir": str(path.parent),
                            "url": None,
                            "note": "",
                        },
                        "自動検出",
                        path.name,
                    )
            except OSError:
                continue

    for d in desktop_dirs or []:
        dd = Path(d)
        if not dd.is_dir():
            continue
        try:
            paths = sorted(dd.glob("*.desktop"), key=lambda p: p.name)
        except OSError:
            continue
        for path in paths:
            try:
                if not path.is_file():
                    continue
                entry = _parse_desktop_file(path)
            except OSError:
                continue
            if entry is None:
                continue
            add(entry, "ランチャー", path.stem)

    return results
