#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "missing $2 in ${1#$ROOT/}"; }

INSTALL="$ROOT/common/install.sh"
SERVICE="$ROOT/service.sh"
WEB="$ROOT/webroot/index.html"

# A manager that removes the old modules/<id> directory before customize.sh must still
# accept ASB's durable, module-specific snapshot. A true uninstall clears that state.
need "$INSTALL" 'if [ -z "$_src" ] && [ -f "$_snap_conf" ]; then'
need "$INSTALL" 'Root managers do not agree on update ordering'
need "$INSTALL" 'update_snapshot_state'
need "$INSTALL" 'named_profiles=$(find /data/adb/asb/config_profiles'
need "$INSTALL" "-name '*.conf'"
need "$INSTALL" 'smart_learning='
need "$SERVICE" 'local _expected_schema=19'

# Watcher lifecycle is late-boot, exact-process scoped and restored at uninstall.
need "$SERVICE" 'asb_wifi_fallback.sh" reconcile'
need "$ROOT/uninstall.sh" 'asb_wifi_fallback.sh" stop'
need "$ROOT/action.sh" 'Wi-Fi fallback: active opt-in'
need "$ROOT/tools/asb_diag.sh" 'Wi-Fi fallback: active opt-in'

# Preference is decided before first paint and the same compact pair appears beside the
# version badge on all three surfaces.
need "$WEB" "localStorage.getItem('asb_theme')==='light'"
need "$WEB" 'asbPaintThemeControls()'
need "$WEB" 'data-theme-toggle="verBadge"'
need "$WEB" 'data-theme-toggle="liveVerBadge"'
need "$WEB" 'data-theme-toggle="cfgVerBadge"'
need "$WEB" 'data-theme-choice="dark"'
need "$WEB" 'data-theme-choice="light"'
need "$WEB" '--bg:#f3f7f6'

echo 'PASS: update continuity, active fallback and theme contract'
