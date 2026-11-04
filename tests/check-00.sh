#!/usr/bin/env bash
# Test for setup/00-check.sh
set -u

FAIL=0

bash setup/00-check.sh >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  FAIL=1
fi

if ! bash setup/00-check.sh --json | python3 -m json.tool >/dev/null 2>&1; then
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS"
  exit 0
else
  echo "FAIL"
  exit 1
fi
