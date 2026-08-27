#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "missing $2 in ${1#$ROOT/}"; }
absent() { ! grep -Fq -- "$2" "$1" || fail "unexpected $2 in ${1#$ROOT/}"; }

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
need "$SERVICE" 'local _expected_schema=20'
need "$INSTALL" '"schema_version": 20'
need "$INSTALL" 'radio_policy_enable net_handover_fast net_handover_active'

# Watcher lifecycle is late-boot, exact-process scoped and restored at uninstall.
need "$SERVICE" 'asb_wifi_fallback.sh" reconcile'
need "$ROOT/uninstall.sh" 'asb_wifi_fallback.sh" stop'
need "$ROOT/action.sh" 'Wi-Fi fallback: active opt-in'
need "$ROOT/tools/asb_diag.sh" 'Wi-Fi fallback: active opt-in'
need "$ROOT/runtime/asb_lpm.sh" 'if ! _feat_on LPM || ! _radio_policy_enabled; then'
need "$ROOT/runtime/asb_wifi_fallback.sh" '_radio_policy_enabled && [ "$(_cfg net_handover_active)" = 1 ]'

# Preference is decided before first paint and the same compact pair appears beside the
# version badge on all three surfaces.
need "$WEB" "localStorage.getItem('asb_theme')==='light'"
need "$WEB" 'asbPaintThemeControls()'
need "$WEB" 'data-theme-toggle="verBadge"'
need "$WEB" 'data-theme-toggle="liveVerBadge"'
need "$WEB" 'data-theme-toggle="cfgVerBadge"'
need "$WEB" 'data-theme-choice="dark"'
need "$WEB" 'data-theme-choice="light"'
# CSS matches the literal value selector, so assigning/removing that literal must be immediate.
need "$WEB" "setAttribute('data-asb-theme', 'light')"
need "$WEB" "removeAttribute('data-asb-theme')"
absent "$WEB" "toggleAttribute('data-asb-theme'"
# Both buttons are independent compact chips, with a pale semantic tint rather than a full green fill.
need "$WEB" '.theme-choice { display:grid; place-items:center; width:34px; height:29px;'
need "$WEB" '<div class="badge badge-a" id="verBadge">V64</div>'
need "$WEB" '<div class="badge badge-a" id="liveVerBadge">V64</div>'
need "$WEB" '<div class="badge badge-a" id="cfgVerBadge">V64</div>'
need "$WEB" '.theme-choice.active { color:var(--accent); background:rgba(0,240,180,.09);'
absent "$WEB" '.theme-choice.active { color:#04120f; background:linear-gradient'
# These cover the previously unreadable dialog title/copy, Smart monitor telemetry and config small text.
need "$WEB" '--text-secondary:#465853; --text-tertiary:#61736d;'
need "$WEB" ':is(.cfg-profile-title,.cfg-reset-title,.debug-action-wait-title) { color:var(--text) !important; }'
need "$WEB" '.smart-banner-value { color:#006c56; }'
need "$WEB" '.cfg-desc { color:var(--text-secondary); opacity:1; }'
# Android WebView light controls: every control that had retained translucent light text has an explicit override.
need "$WEB" 'html[data-asb-theme="light"] .badge-a { background:linear-gradient(135deg,rgba(0,124,99,.14),rgba(0,111,155,.09)) !important;'
need "$WEB" 'html[data-asb-theme="light"] .cfg-sel-btn { color:var(--text) !important; background:#fff !important;'
need "$WEB" 'html[data-asb-theme="light"] .cfg-sel-pop button { color:var(--text-secondary) !important;'
need "$WEB" 'html[data-asb-theme="light"] .cfg-range input[type="range"] { height:6px; background:linear-gradient(90deg,#adc2bb,#e4eeeb) !important;'
need "$WEB" 'html[data-asb-theme="light"] .cfg-seg button.on { color:#063d32; background:linear-gradient(135deg,#b7f4e6,#b8edf2);'
need "$WEB" "key:'radio_policy_enable'"
# Radio master must be the first actual card after the Network heading, ahead of every dependent setting.
first_net_card=$(awk '/\/\/ ---- Network/{in_network=1; next} in_network && /\{ key:/{print; exit}' "$WEB")
[ "$first_net_card" = "  { key:'radio_policy_enable', type:'bool', def:'0', stock:'0', name:'Cellular / radio controls'," ] || fail 'radio policy master is not the first Network card'
need "$WEB" 'radio_policy_enable:APPLY_LIVE'
need "$WEB" '--bg:#f3f7f6'

echo 'PASS: update continuity, active fallback and theme contract'
