#!/usr/bin/env bash
# Task 004 test: systemd user timer for capture (static checks only,
# nothing is enabled on the host).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD=""

cleanup() {
  if [ -n "$TMPD" ] && [ -d "$TMPD" ]; then
    rm -rf "$TMPD"
  fi
}
trap cleanup EXIT

fail() {
  echo "FAIL"
  exit 1
}

SVC="$ROOT/systemd/hanare-capture.service"
TMR="$ROOT/systemd/hanare-capture.timer"
SETUP="$ROOT/setup/10-install-capture.sh"

# 1. Unit files exist and contain the required keys
[ -f "$SVC" ] || fail
[ -f "$TMR" ] || fail

grep -q '^Type=oneshot' "$SVC" || fail
grep -q '^ExecStart=.*feed/capture\.sh' "$SVC" || fail

grep -q '^OnUnitActiveSec=60s' "$TMR" || fail
grep -q '^Unit=hanare-capture\.service' "$TMR" || fail
grep -q '^WantedBy=timers\.target' "$TMR" || fail

# 2. systemd-analyze verify (if available)
if command -v systemd-analyze >/dev/null 2>&1; then
  TMPD="$(mktemp -d)" || fail
  cp "$SVC" "$TMPD/hanare-capture.service" || fail
  cp "$TMR" "$TMPD/hanare-capture.timer" || fail
  if ! systemd-analyze verify "$TMPD/hanare-capture.service" \
      "$TMPD/hanare-capture.timer" >"$TMPD/verify.out" 2>&1; then
    cat "$TMPD/verify.out" >&2
    fail
  fi
else
  echo "NOTE: systemd-analyze not available; skipping unit verification"
fi

# 3. Setup script: uses systemctl --user, never sudo
[ -f "$SETUP" ] || fail
grep -q 'systemctl --user' "$SETUP" || fail
if grep -q 'sudo' "$SETUP"; then
  fail
fi

echo "PASS"
exit 0
