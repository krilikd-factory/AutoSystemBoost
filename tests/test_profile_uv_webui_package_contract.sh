#!/bin/sh
# Contract: named profile UI must ship its helper, and external kernel/UV evidence must be
# visible in WebUI as diagnostics-only information rather than a hidden asbdiag-only feature.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UI="$ROOT/webroot/index.html"
REL="$ROOT/.github/workflows/build-release.yml"
DBG="$ROOT/.github/workflows/build-debug.yml"
HELPER="$ROOT/tools/asb_config_backup.sh"
UV="$ROOT/tools/asb_kernel_uv_coexist.sh"
INSTALL="$ROOT/common/install.sh"
fail() { echo "FAIL profile/UV WebUI package: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
[ -f "$HELPER" ] || fail 'backup helper source missing'
[ -f "$UV" ] || fail 'UV helper source missing'
[ -f "$INSTALL" ] || fail 'installer source missing'
need "$INSTALL" '! -name "asb_config_backup.sh"'
need "$INSTALL" '! -name "asb_kernel_uv_coexist.sh"'
need "$INSTALL" 'chmod 0755 "$MODPATH/tools/asb_config_backup.sh"'
need "$INSTALL" 'chmod 0755 "$MODPATH/tools/asb_kernel_uv_coexist.sh"'

# Reproduce the installer top-level tool prune in a temporary module tree. Static greps alone
# would not catch a typo that keeps an obsolete broad delete rule after the allowlist.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/tools"
cp "$HELPER" "$TMP/tools/asb_config_backup.sh"
cp "$UV" "$TMP/tools/asb_kernel_uv_coexist.sh"
printf '%s\\n' '#!/system/bin/sh' > "$TMP/tools/unrelated_dev_tool.sh"
find "$TMP/tools" -maxdepth 1 -type f \
  ! -name "asb_state_sampler.sh" \
  ! -name "asb_drain_analyzer.sh" \
  ! -name "asb_doctor.sh" \
  ! -name "asb_lint.sh" \
  ! -name "asb_session_report.py" \
  ! -name "asb_compare_sessions.py" \
  ! -name "asb_analyze.py" \
  ! -name "asb_camera_repair.sh" \
  ! -name "asb_sysui_watch.sh" \
  ! -name "asb_diag.sh" \
  ! -name "asb_recents_probe.sh" \
  ! -name "asb_config_backup.sh" \
  ! -name "asb_kernel_uv_coexist.sh" \
  -delete
[ -f "$TMP/tools/asb_config_backup.sh" ] || fail 'installer prune deletes profile helper'
[ -f "$TMP/tools/asb_kernel_uv_coexist.sh" ] || fail 'installer prune deletes UV helper'
[ ! -e "$TMP/tools/unrelated_dev_tool.sh" ] || fail 'installer prune no longer removes unrelated tool'

# The exact helper called by WebUI must survive both package workflows and be validated in
# the corresponding ZIP. This closes the on-device No such file failure, not just source lint.
for WF in "$REL" "$DBG"; do
  need "$WF" 'tools/asb_config_backup.sh'
  need "$WF" 'tools/asb_kernel_uv_coexist.sh'
done
need "$UI" "const CFG_PROFILE_HELPER = MD + '/tools/asb_config_backup.sh';"
need "$UI" "const CFG_UV_HELPER = MD + '/tools/asb_kernel_uv_coexist.sh';"
need "$UI" 'function cfgLoadUvStatus()'
need "$UI" "sh ' + shQuote(CFG_UV_HELPER) + ' 2>/dev/null'"
need "$UI" 'id="cfgUvCard"'
need "$UI" 'data-i18n="cfg_profile_save_short"'
need "$UI" 'data-i18n="cfg_profile_load_short"'
need "$UI" 'data-i18n="cfg_profile_storage_hint"'
need "$UI" 'grid-template-columns: repeat(2, minmax(0, 1fr))'
need "$UI" '#cfgActionsRow .cfg-backup { min-width: 0; min-height: 44px; padding: 10px 8px; white-space: normal; overflow: visible; text-overflow: clip; }'
# No UI command may write into the UV helper or any voltage sysfs/property surface.
if grep -E 'CFG_UV_HELPER.*(setprop|settings put|/sys/)|asb_kernel_uv_coexist\\.sh.*(setprop|settings put|/sys/)' "$UI" >/dev/null; then
  fail 'WebUI appears to mutate UV policy'
fi
need "$UV" 'asb_action" "diagnostics_only'
need "$UV" 'ASB does not own, write, validate, disable or revert external voltage policy'

# Keep the 13 existing interface locales complete for all static/dynamic strings in the card.
python3 - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'webroot' / 'i18n'
keys = {
  'cfg_profile_save_short','cfg_profile_load_short','cfg_profile_storage_hint',
  'cfg_uv_title','cfg_uv_surface','cfg_uv_hint','cfg_uv_none','cfg_uv_none_detail',
  'cfg_uv_detail_unavailable','cfg_uv_evidence','cfg_uv_unavailable','cfg_uv_owner',
}
files = sorted(root.glob('*.json'))
assert len(files) == 13, f'expected 13 locale files, got {len(files)}'
for p in files:
    data = json.loads(p.read_text(encoding='utf-8'))
    missing = sorted(k for k in keys if not isinstance(data.get(k), str) or not data[k].strip())
    assert not missing, f'{p.name}: missing {missing}'
print('PASS profile/UV locale keys: 13 locales')
PY

echo 'PASS profile/UV WebUI package contract'
