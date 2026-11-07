#!/usr/bin/env bash
# Task 014 test: service registry unification + unit generation + settings.
# - status.sh carries display/unit/url from the registry into the snapshot
# - old 3-column rows still work
# - hanare-service-gen.sh generates units only for exec-managed rows
# - topbar reads unit/display from the snapshot (fallback table only)
# - panel registry helpers (upsert/remove/add_model) round-trip on a temp repo
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD=""
cleanup() {
  [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }

TMPD="$(mktemp -d)" || fail "mktemp"

# --- registry + status.sh ---------------------------------------------
cat > "$TMPD/services.tsv" <<'TSV'
# comment line must be skipped
llama-server	8080	Tesla V100	llama	hanare-llama	-	-	-
dummy	18996	-	Dummy Svc	hanare-dummy	python3 -m http.server 18996	/tmp	http://127.0.0.1:18996/
oldstyle	18995	None
TSV
out="$(HANARE_SERVICES_TSV="$TMPD/services.tsv" bash "$ROOT/status/status.sh" --json 2>/dev/null)" || fail "status.sh failed"
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
svc = {s["name"]: s for s in d["services"]}
assert svc["dummy"]["display"] == "Dummy Svc", svc["dummy"]
assert svc["dummy"]["unit"] == "hanare-dummy", svc["dummy"]
assert svc["dummy"]["url"] == "http://127.0.0.1:18996/", svc["dummy"]
assert svc["llama-server"]["unit"] == "hanare-llama", svc["llama-server"]
assert svc["llama-server"]["url"] == "", svc["llama-server"]
assert svc["oldstyle"]["state"] in ("stopped", "running", "degraded"), svc["oldstyle"]
' || fail "snapshot lacks registry fields"

# --- unit generation ----------------------------------------------------
cat > "$TMPD/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$TMPD/systemctl"
HANARE_SERVICES_TSV="$TMPD/services.tsv" HANARE_UNIT_DIR="$TMPD/units" \
HANARE_SYSTEMCTL="$TMPD/systemctl" \
  bash "$ROOT/scripts/hanare-service-gen.sh" >"$TMPD/gen.log" 2>&1 || fail "gen failed: $(cat "$TMPD/gen.log")"
[ -f "$TMPD/units/hanare-dummy.service" ] || fail "dummy unit not generated"
grep -qF 'ExecStart=python3 -m http.server 18996' "$TMPD/units/hanare-dummy.service" || fail "generated unit lacks ExecStart"
grep -qF 'WorkingDirectory=/tmp' "$TMPD/units/hanare-dummy.service" || fail "generated unit lacks WorkingDirectory"
grep -qF 'TimeoutStopSec=60' "$TMPD/units/hanare-dummy.service" || fail "generated unit lacks TimeoutStopSec"
if grep -qxF "[Install]" "$TMPD/units/hanare-dummy.service"; then fail "generated unit must not have [Install]"; fi
[ ! -e "$TMPD/units/hanare-llama.service" ] || fail "hand-managed llama unit must not be generated"

# --- topbar: snapshot-driven, no per-service hardcode beyond fallback ----
grep -qF 'hanareSvcUnit' "$ROOT/topbar/extension.js" || fail "topbar lacks hanareSvcUnit"
grep -qF 'svc.unit' "$ROOT/topbar/extension.js" || fail "topbar does not read svc.unit"
if grep -qF "strata: 'hanare-strata'" "$ROOT/topbar/extension.js"; then
  fail "topbar still hardcodes strata unit"
fi

# --- panel helpers round-trip on a temp repo ----------------------------
mkdir -p "$TMPD/repo/services" "$TMPD/repo/models" "$TMPD/repo/runtime" "$TMPD/repo/apps" "$TMPD/repo/drop"
ln -s "$ROOT/dashboard" "$TMPD/repo/dashboard"
cp "$TMPD/services.tsv" "$TMPD/repo/services/services.tsv"
printf 'name\tgguf_path\tmmproj_path\tctx\tprofile\tnote\tdraft_path\n' > "$TMPD/repo/models/models.tsv"
echo "dummy gguf bytes" > "$TMPD/repo/fake.gguf"
cat > "$TMPD/panel_test.py" <<'PYEOF'
import importlib.util, os, sys
repo = os.environ["TMP_REPO"]
spec = importlib.util.spec_from_file_location("panel", os.path.join(repo, "panel.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
units = m.service_units()
assert units["dummy"] == "hanare-dummy.service", units
assert units["llama-server"] == "hanare-llama.service", units
ok, msg = m.upsert_service({"name": "extra", "display": "Extra", "port": "18994",
                            "exec": "python3 -m http.server 18994", "workdir": "", "url": ""})
assert ok, msg
assert m.service_units()["extra"] == "hanare-extra.service"
ok, msg = m.add_model({"name": "fake-model", "gguf": os.path.join(repo, "fake.gguf"),
                       "ctx": "4096", "mmproj": ""})
assert ok, msg
assert [x["name"] for x in m.load_models()] == ["fake-model"]
ok, msg = m.add_model({"name": "fake-model", "gguf": os.path.join(repo, "fake.gguf"),
                       "ctx": "4096", "mmproj": ""})
assert not ok, "duplicate model must be refused"
ok, msg = m.remove_service("extra")
assert ok, msg
assert "extra" not in m.service_units()
print("panel helpers OK")
PYEOF
cp "$ROOT/panel/hanare-panel.py" "$TMPD/repo/panel.py"
TMP_REPO="$TMPD/repo" \
HANARE_REPO="$TMPD/repo" \
HANARE_UNIT_DIR="$TMPD/units" \
HANARE_SERVICES_TSV="$TMPD/repo/services/services.tsv" \
HANARE_SERVICE_GEN="$ROOT/scripts/hanare-service-gen.sh" \
HANARE_SYSTEMCTL="$TMPD/systemctl" \
  python3 "$TMPD/panel_test.py" || fail "panel helper round-trip failed"

echo "PASS"
exit 0
