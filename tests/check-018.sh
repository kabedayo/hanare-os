#!/usr/bin/env bash
# Task 018 test: DnD must sit on EventBox widgets (Gtk.Box has no
# GdkWindow and cannot start/receive X11 drags), with a click fallback.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
P="$ROOT/panel/hanare-panel.py"
grep -qF 'eb.drag_source_set' "$P" || fail "app drag source is not on an EventBox"
grep -qF 'svc_eb.drag_dest_set' "$P" || fail "service drop dest is not on an EventBox"
grep -qF 'Gtk.EventBox()' "$P" || fail "no EventBox in panel"
grep -qF 'button-release-event' "$P" || fail "no click fallback"
grep -qF '"pressed"' "$P" || fail "no press guard state"
grep -qF 'apply_app_prefill(_item)' "$P" || fail "click fallback does not prefill"
echo PASS
