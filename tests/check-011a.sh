#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PY="$TMP/test_011a.py"
cat > "$PY" <<'EOF'
import os
import sys
from pathlib import Path

root = Path(os.environ["ROOT"])
sys.path.insert(0, str(root))
from dashboard.discovery import discover

tmp = Path(os.environ["TMP_011A"])
apps = tmp / "apps"
drop = tmp / "drop"
desk = tmp / "desktop"
for d in (apps, drop, desk):
    d.mkdir(parents=True)

# 1. apps_dir: story.app (Task 010 format)
(apps / "story.app").write_text(
    "name=Local Story Studio\n"
    "exec=/opt/story/run.sh --flag\n"
    "workdir=/opt/story\n"
    "url=http://127.0.0.1:8765/\n"
    "note=note\n",
    encoding="utf-8",
)

# 2. drop: folder with run.sh
f1 = drop / "mytool"
f1.mkdir()
run = f1 / "run.sh"
run.write_text("#!/bin/sh\n")
run.chmod(0o755)

# 2. drop: folder with only app.py
f2 = drop / "pyapp"
f2.mkdir()
(f2 / "app.py").write_text("print(1)\n")

# 2. drop: .desktop file
(drop / "deskapp.desktop").write_text(
    "[Desktop Entry]\n"
    "Type=Application\n"
    "Name=Desk App\n"
    "Exec=/usr/bin/deskapp --open\n",
    encoding="utf-8",
)

# 2. drop: executable file
exe = drop / "toolbin"
exe.write_text("#!/bin/sh\n")
exe.chmod(0o755)

# 3. desktop dir: normal .desktop with %U field code
(desk / "browser.desktop").write_text(
    "[Desktop Entry]\n"
    "Type=Application\n"
    "Name=Web Browser\n"
    "Exec=/usr/bin/browser %U\n"
    "Path=/opt/browser\n",
    encoding="utf-8",
)

# 3. desktop dir: NoDisplay=true -> absent
(desk / "hidden.desktop").write_text(
    "[Desktop Entry]\n"
    "Type=Application\n"
    "Name=Hidden App\n"
    "Exec=/usr/bin/hidden\n"
    "NoDisplay=true\n",
    encoding="utf-8",
)

# 3. desktop dir: name duplicate of apps_dir entry -> absent
(desk / "dup.desktop").write_text(
    "[Desktop Entry]\n"
    "Type=Application\n"
    "Name=local story studio\n"
    "Exec=/usr/bin/dup\n",
    encoding="utf-8",
)

results = discover(str(apps), str(drop), [str(desk)])
by_id = {r["id"]: r for r in results}

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


s = by_id.get("story")
check(s is not None, "story.app present")
if s:
    check(s["source"] == "登録", "story source is 登録")
    check(s["name"] == "Local Story Studio", "story name")
    check(s["exec_argv"] == ["/opt/story/run.sh", "--flag"], "story exec_argv shlex")
    check(s["workdir"] == "/opt/story", "story workdir")
    check(s["url"] == "http://127.0.0.1:8765/", "story url")

t = by_id.get("mytool")
check(t is not None, "drop folder run.sh present")
if t:
    check(t["source"] == "自動検出", "mytool source is 自動検出")
    check(
        t["exec_argv"] and t["exec_argv"][-1].endswith("run.sh"),
        "mytool exec_argv ends with run.sh",
    )
    check(t["workdir"] == str(f1), "mytool workdir is folder")

p = by_id.get("pyapp")
check(p is not None, "drop folder app.py present")
if p:
    check(
        len(p["exec_argv"]) >= 2
        and (
            p["exec_argv"][0].endswith("python3")
            or ".venv/bin/python" in p["exec_argv"][0]
        ),
        "pyapp exec_argv[0] is python",
    )
    check(p["exec_argv"][1].endswith("app.py"), "pyapp exec_argv[1] ends with app.py")

d = by_id.get("deskapp")
check(d is not None, "drop .desktop present")
if d:
    check(d["source"] == "自動検出", "deskapp source is 自動検出")
    check(d["exec_argv"] == ["/usr/bin/deskapp", "--open"], "deskapp exec_argv")

b = by_id.get("toolbin")
check(b is not None, "drop executable file present")
if b:
    check(b["exec_argv"] == [str(exe)], "toolbin exec_argv is [path]")
    check(b["workdir"] == str(drop), "toolbin workdir is its directory")

w = by_id.get("browser")
check(w is not None, "desktop dir .desktop present")
if w:
    check(w["source"] == "ランチャー", "browser source is ランチャー")
    check(w["exec_argv"] == ["/usr/bin/browser"], "browser argv has no %U")
    check(all("%" not in a for a in w["exec_argv"]), "browser argv has no %")
    check(w["workdir"] == "/opt/browser", "browser workdir from Path key")

check("hidden" not in by_id, "NoDisplay=true absent")
check("dup" not in by_id, "name duplicate absent (dedupe vs apps_dir)")

if failures:
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("ok")
EOF

if TMP_011A="$TMP" ROOT="$ROOT" python3 "$PY"; then
    echo "PASS"
    exit 0
else
    echo "FAIL"
    exit 1
fi
