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
WATCHDOG="$ROOT/runtime/asb_watchdog.sh"
RECONCILE="$ROOT/runtime/asb_reconcile.sh"
EFFECTIVE="$ROOT/tools/asb_effective_policy.sh"
fail() { echo "FAIL stock profile contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
need_count() { _n="$(grep -Fc "$2" "$1" || true)"; [ "$_n" = "$3" ] || fail "expected $3 occurrences of [$2] in $1, got $_n"; }

for f in "$UI" "$INSTALL" "$SERVICE" "$APPLY" "$CORE" "$UTILS" "$STOCK" "$WATCHDOG" "$RECONCILE" "$EFFECTIVE"; do
  [ -f "$f" ] || fail "missing source $f"
done
for f in "$INSTALL" "$SERVICE" "$APPLY" "$CORE" "$UTILS" "$STOCK" "$WATCHDOG" "$RECONCILE" "$EFFECTIVE"; do
  sh -n "$f" || fail "shell syntax $f"
done

# Backend: Stock stops/refrains from starting only ASB profile policy, releases ASB leases and
# does not ask the native daemon to interpret an unsupported profile:stock command.
need "$STOCK" 'asb_stock_enter()'
need "$STOCK" 'asb_stock_stop_governor'
need "$STOCK" 'asb_stock_release_profile_leases'
need "$STOCK" 'cpu_cap gpu_cap uclamp_max cpuset_fg'
need "$STOCK" 'A reboot restores the'
need "$APPLY" 'stock|performance|balanced|battery)'
need "$APPLY" 'if [ "$PROFILE" = "stock" ]; then'
need "$APPLY" 'asb_stock_enter'
need "$APPLY" 'asb_stock_start_governor'
! grep -Fq '"profile:$PROFILE"' "$APPLY" || true
need "$CORE" 'stock)'
need "$CORE" 'ASB_STOCK_PROFILE=1'
need "$CORE" '[ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0'
need "$UTILS" 'asb_stock_profile_active'
need "$UTILS" 'return 2'
need "$SERVICE" 'stock|battery|balanced|performance|smart)'
need "$SERVICE" 'asb_stock_enter'
need "$SERVICE" '[ "${ASB_STOCK_PROFILE:-0}" = "1" ] && return 0'
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
need "$UI" '<div class="pico">📴</div>'
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
need "$UI" "T('t_stock_applied'"
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
    for key in ('prof_stock', 'prof_stock_sub', 't_stock_applied', 'dbg_diag_wait', 'dbg_log_wait'):
        assert isinstance(data.get(key), str) and data[key].strip(), f'{p.name}: missing {key}'
print('PASS Stock profile and immediate debug action locale coverage: 13 locales')
PY

echo 'PASS stock profile contract'
