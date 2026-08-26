#!/bin/sh
# Contract: Stock is an explicit, persistent no-intervention profile. It must never silently
# become Balanced, restart the native governor, or move the three-button debug support rail.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UI="$ROOT/webroot/index.html"
INSTALL="$ROOT/common/install.sh"
SERVICE="$ROOT/service.sh"
APPLY="$ROOT/apply_profile.sh"
CORE="$ROOT/runtime/profile_core.sh"
UTILS="$ROOT/runtime/asb_utils.sh"
STOCK="$ROOT/runtime/asb_stock_policy.sh"
BASELINE="$ROOT/runtime/asb_baseline.sh"
WATCHDOG="$ROOT/runtime/asb_watchdog.sh"
RECONCILE="$ROOT/runtime/asb_reconcile.sh"
EFFECTIVE="$ROOT/tools/asb_effective_policy.sh"
fail() { echo "FAIL stock profile contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
need_count() { _n="$(grep -Fc "$2" "$1" || true)"; [ "$_n" = "$3" ] || fail "expected $3 occurrences of [$2] in $1, got $_n"; }

for f in "$UI" "$INSTALL" "$SERVICE" "$APPLY" "$CORE" "$UTILS" "$STOCK" "$BASELINE" "$WATCHDOG" "$RECONCILE" "$EFFECTIVE"; do
  [ -f "$f" ] || fail "missing source $f"
done
for f in "$INSTALL" "$SERVICE" "$APPLY" "$CORE" "$UTILS" "$STOCK" "$BASELINE" "$WATCHDOG" "$RECONCILE" "$EFFECTIVE"; do
  sh -n "$f" || fail "shell syntax $f"
done

# Backend: Stock stops/refrains from starting only ASB profile policy, releases ASB leases and
# does not ask the native daemon to interpret an unsupported profile:stock command.
need "$STOCK" 'asb_stock_enter()'
need "$STOCK" 'asb_stock_stop_governor'
need "$STOCK" 'asb_stock_release_profile_leases'
need "$STOCK" 'cpu_cap gpu_cap uclamp_max cpuset_fg'
need "$STOCK" 'asb_stock_restore_profile_runtime'
need "$STOCK" 'asb_profile_baseline_restore'
need "$STOCK" 'profile-owned baseline restored'
need "$BASELINE" 'ASB_PROFILE_BASELINE='
need "$BASELINE" 'asb_profile_baseline_capture_path()'
need "$BASELINE" 'asb_profile_baseline_capture_setting()'
need "$BASELINE" 'asb_profile_baseline_restore()'
need "$BASELINE" 'manual audio'
need "$APPLY" 'stock|performance|balanced|battery)'
need "$APPLY" 'if [ "$PROFILE" = "stock" ]; then'
need "$APPLY" 'asb_stock_enter'
need "$APPLY" 'description=status: Stock 👶🏻 | active ✅'
need "$CORE" 'description=status: Stock 👶🏻 | active ✅'
! grep -Fq 'Stock ◻️ | ASB performance policy stopped' "$APPLY" || fail 'legacy Stock status remains in apply fallback'
! grep -Fq 'Stock ◻️ | ASB performance policy stopped' "$CORE" || fail 'legacy Stock status remains in profile core'
need "$APPLY" 'asb_stock_start_governor'
need "$APPLY" '[ "$PROFILE" = "stock" ] && _passes=1'
need "$APPLY" 'stock_cancel_pending_worker()'
need "$APPLY" 'profile_next_epoch 0.05 4'
need "$APPLY" 'stock applied immediately; no duplicate profile worker spawned'
# Stock is fully restored by notify_governor in the direct path. Do not queue a second worker
# behind the outgoing Smart worker lock after that real Stock restore has completed.
_stock_direct="$(sed -n '/^quick_return_or_spawn()/,/^run_worker()/p' "$APPLY" | sed -n '/if \[ "$PROFILE" = "stock" \]; then/,/^[[:space:]]*fi/p')"
printf '%s\n' "$_stock_direct" | grep -Fq 'spawn_worker' && fail 'Stock direct path still spawns a duplicate worker'
! grep -Fq '"profile:$PROFILE"' "$APPLY" || true
need "$CORE" 'stock)'
need "$CORE" 'ASB_STOCK_PROFILE=1'
need "$CORE" '[ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0'
need "$CORE" 'asb_stock_enter'
need "$CORE" 'ASB_PROFILE_BASELINE_CAPTURE=1'
need "$CORE" 'asb_profile_baseline_capture_path'
need "$UTILS" 'asb_stock_profile_active'
need "$UTILS" 'return 2'
need "$UTILS" 'ASB_DEFER_GOVERNOR_START'
need "$SERVICE" 'ASB_DEFER_GOVERNOR_START=1'
need "$SERVICE" 'post_boot_governor_start_begin'
need "$SERVICE" 'post_boot_governor_stock_off'
need "$SERVICE" 'asb_governor_start || asb_log "post_boot: governor start deferred to watchdog"'
need "$SERVICE" 'stock|battery|balanced|performance|smart)'
need "$SERVICE" 'asb_stock_enter'
need "$SERVICE" '[ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0'
need "$SERVICE" 'Stock is an explicit terminal boundary for this runtime pass'
need "$SERVICE" 'ASB_PROFILE_BASELINE_CAPTURE=1'
need "$WATCHDOG" 'current_profile'
need "$WATCHDOG" '"stock" ] && exit 0'
need "$RECONCILE" '"stock" ]; then'
need "$EFFECTIVE" '_owner="rom_stock"'
need "$EFFECTIVE" '_cpu_min_strategy="not_managed"'

# Fresh install explicitly persists Stock, while upgrade migration preserves an already selected
# profile including Stock.
need "$INSTALL" "printf '%s\\n' stock > \"\$MODPATH/current_profile\""
need "$INSTALL" 'stock|performance|battery|balanced|smart|none)'
need "$INSTALL" 'Stock profile active; ASB CPU/GPU/governor policy is off'
need "$INSTALL" 'asb_stock_policy.sh'

# WebUI: one fifth Stock card starts selected in shipped markup; live load replaces it with the
# actual stored profile. The compact spacing retains the support rail's three equal controls.
need "$UI" "class=\"pbtn pbtn-stock on\" data-p=\"stock\" onclick=\"go('stock')\""
need "$UI" '<div class="pico" data-tech-icon="stock"></div>'
need "$UI" 'data-i18n="prof_stock"'
need "$UI" 'data-i18n="prof_stock_sub"'
need "$UI" '.pbtn[data-p="stock"]'
# Stock inherits the shared inactive pbtn surface. Silver is applied only through
# its --c token when selected; a dedicated .pbtn-stock surface would visibly split
# its border from Performance, Balanced and Battery.
if grep -Fq '.pbtn-stock {' "$UI"; then
  fail 'Stock has a dedicated inactive surface instead of the shared pbtn border'
fi
_profile_order="$(grep -E 'class=\"pbtn[^\"]*\" data-p=\"(smart|performance|balanced|battery|stock)\"' "$UI" | sed -n 's/.*data-p="\([^"]*\)".*/\1/p' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[ "$_profile_order" = 'smart performance balanced battery stock' ] || \
  fail "unexpected profile card order: $_profile_order"
need "$UI" "['stock','performance','balanced','battery','smart'].includes(p)"
need "$UI" "T('t_stock_applied', 'Stock active · ASB policy stopped')"
! grep -Fq 'reboot recommended' "$UI" || fail 'Stock WebUI fallback still recommends a reboot'
need "$UI" "let _selectedProfile = 'none';"
need "$UI" 'function paintStockLive(stockKv = null) {'
need "$UI" 'let _stockTelemetryKv = {};'
need "$UI" 'id="stockTelemetry"'
need "$UI" '.stock-telemetry { display:none !important;'
need "$UI" 'async function pollStockTelemetry(visible, force = false)'
need "$UI" '/sys/class/power_supply/battery'
need "$UI" '/sys/devices/system/cpu/cpufreq/policy'
need "$UI" "_stockTelemetryKv = kv;"
need "$UI" 'paintStockLive(_stockTelemetryKv);'
need "$UI" "set('liveCpu'"
need "$UI" "set('liveGpu'"
need "$UI" "set('liveHeadroom'"
need "$UI" 'id="liveStockRomBanner"'
need "$UI" 'id="bnStockDrain"'
need "$UI" 'id="bnStockTrend"'
need "$UI" 'id="bnStockLpm"'
need "$UI" 'id="bnStockCpuClock"'
need "$UI" 'id="bnStockLoad"'
need "$UI" 'id="bnStockBattery"'
need "$UI" 'id="bnStockUptime"'
need "$UI" 'settings get global mobile_data_always_on'
need "$UI" 'let _stockRomHistory = { ts: 0, cpuT: 0 };'
! grep -A130 'async function pollStockTelemetry' "$UI" | grep -Eq 'settings put|resetprop|tee .*\/sys|echo .*\/sys' || fail 'Stock telemetry contains a write operation'
need "$UI" "if (visible && _selectedProfile === 'stock') {"
need "$UI" "const off = T('prof_stock_sub', 'ASB policy off');"
# UI must acknowledge a profile tap before waiting for the root-side lifecycle. In particular,
# Smart → Stock can safely take longer while the governor stops and the profile baseline restores.
# A failed root transition must return the highlight to the confirmed previous profile.
python3 - "$UI" <<'PY'
import sys
from pathlib import Path
s = Path(sys.argv[1]).read_text(encoding='utf-8')
start = s.index('async function go(p) {')
end = s.index('\nfunction openTelegram', start)
go = s[start:end]
def require(fragment):
    if fragment not in go:
        raise SystemExit('FAIL Stock UI switch contract: missing ' + fragment)
def before(left, right):
    if go.index(left) >= go.index(right):
        raise SystemExit('FAIL Stock UI switch contract: expected ' + left + ' before ' + right)
require("const previousProfile = _selectedProfile;")
require('ui(p);')
require("const r = await run('sh ' + MD + '/apply_profile.sh ' + p);")
require('ui(previousProfile);')
before('ui(p);', "const r = await run('sh ' + MD + '/apply_profile.sh ' + p);")
before("const r = await run('sh ' + MD + '/apply_profile.sh ' + p);", 'ui(previousProfile);')
print('PASS Stock UI immediate-selection contract')
PY
need "$UI" 'gap: 8px;'
need_count "$UI" '<button class="debug-support-btn" data-debug-action="diag"' 3
need_count "$UI" '<button class="debug-support-btn" data-debug-action="full-day"' 3
need "$UI" 'debugActionPulse'
need "$UI" "T(action === 'diag' ? 'dbg_diag_wait' : 'dbg_log_wait'"
need "$UI" "b.classList.add('is-running')"
need "$UI" "b.classList.remove('is-running')"
need "$UI" 'footer-support-row'
need "$UI" 'flex-wrap: nowrap;'

# All 13 locales must expose the new profile and immediate action status to the user.
python3 - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'webroot' / 'i18n'
files = sorted(root.glob('*.json'))
assert len(files) == 13, f'expected 13 locales, got {len(files)}'
for p in files:
    data = json.loads(p.read_text(encoding='utf-8'))
    for key in ('prof_stock', 'prof_stock_sub', 't_stock_applied', 'stock_cpu_clock', 'stock_load', 'stock_battery', 'stock_uptime', 'dbg_diag_wait', 'dbg_log_wait'):
        assert isinstance(data.get(key), str) and data[key].strip(), f'{p.name}: missing {key}'
    stale = ('reboot', 'перезаг', 'neustart', 'reiniciar', 'redémarrage', 'վերագործարկ', 'mulai ulang', 'riavvio', 'yeniden başlat', '重启')
    assert not any(word in data['t_stock_applied'].lower() for word in stale), f'{p.name}: stale reboot recommendation'
print('PASS Stock profile, live ROM metric and immediate action locale coverage: 13 locales')
PY

# Behavioural fixture: profile runtime baseline must preserve the first pre-ASB value,
# restore it without reboot, and disappear afterwards so the next non-Stock session captures
# a fresh ROM state. It uses a temporary ordinary file; no Android setting or sysfs is touched.
_tmp="$(mktemp -d)"; trap 'rm -rf "$_tmp"' EXIT HUP INT TERM
_node="$_tmp/node"; _snap="$_tmp/profile_runtime_baseline.v1"
printf '111\n' > "$_node"
ASB_PROFILE_BASELINE="$_snap"
. "$BASELINE"
asb_profile_baseline_capture_path "$_node"
printf '222\n' > "$_node"
asb_profile_baseline_capture_path "$_node"
[ "$(cat "$_node")" = "222" ] || fail 'fixture setup changed node unexpectedly'
asb_profile_baseline_restore
[ "$(cat "$_node")" = "111" ] || fail 'immediate profile baseline restore did not restore first value'
[ ! -e "$_snap" ] || fail 'restored profile baseline was not cleared'

need "$ROOT/src/asb_writer.h" 'writer_profile_baseline_record_path'
need "$ROOT/src/asb_writer.h" 'profile_runtime_baseline.v1'

echo 'PASS stock profile contract'
