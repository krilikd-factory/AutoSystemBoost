#!/bin/sh
# Contract: named profiles must remain installed and user-visible. External kernel/UV evidence
# remains diagnostics-only (asbdiag/helper); it must not occupy a WebUI card or infer a result
# from ambiguous vendor properties.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UI="$ROOT/webroot/index.html"
REL="$ROOT/.github/workflows/build-release.yml"
DBG="$ROOT/.github/workflows/build-debug.yml"
HELPER="$ROOT/tools/asb_config_backup.sh"
UV="$ROOT/tools/asb_kernel_uv_coexist.sh"
INSTALL="$ROOT/common/install.sh"
fail() { echo "FAIL profile/UV package contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
absent() { ! grep -Fq "$2" "$1" || fail "unexpected [$2] in $1"; }
[ -f "$HELPER" ] || fail 'backup helper source missing'
[ -f "$UV" ] || fail 'UV helper source missing'
[ -f "$INSTALL" ] || fail 'installer source missing'

# Installer prune must retain both user-visible profile helper and diagnostics-only UV helper.
need "$INSTALL" '! -name "asb_config_backup.sh"'
need "$INSTALL" '! -name "asb_kernel_uv_coexist.sh"'
need "$INSTALL" 'chmod 0755 "$MODPATH/tools/asb_config_backup.sh"'
need "$INSTALL" 'chmod 0755 "$MODPATH/tools/asb_kernel_uv_coexist.sh"'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/tools"
cp "$HELPER" "$TMP/tools/asb_config_backup.sh"
cp "$UV" "$TMP/tools/asb_kernel_uv_coexist.sh"
printf '%s\n' '#!/system/bin/sh' > "$TMP/tools/unrelated_dev_tool.sh"
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

# Both workflows must preserve and verify the exact helpers in their flashable packages.
for WF in "$REL" "$DBG"; do
  need "$WF" 'tools/asb_config_backup.sh'
  need "$WF" 'tools/asb_kernel_uv_coexist.sh'
done

# Profile controls are explicit, readable and remain the only storage UI. There is no arbitrary
# filesystem picker: closed profile names/checksums and transactional restore remain mandatory.
need "$UI" "const CFG_PROFILE_HELPER = MD + '/tools/asb_config_backup.sh';"
need "$UI" 'data-i18n="cfg_profile_save_short"'
need "$UI" 'data-i18n="cfg_profile_load_short"'
need "$UI" 'data-i18n="cfg_profile_storage_hint"'
need "$UI" 'grid-template-columns: repeat(2, minmax(0, 1fr))'
need "$UI" '#cfgActionsRow .cfg-backup { min-width: 0; min-height: 44px; padding: 10px 8px; white-space: normal; overflow: visible; text-overflow: clip; }'
need "$UI" 'function cfgProfileNameOK(name)'
need "$UI" 'id="cfgProfileModal"'
need "$UI" 'function cfgProfileOpen(mode)'
need "$UI" 'function cfgProfileSuggestedName()'
need "$UI" "return 'asb-' + (p || 'settings');"
need "$UI" 'function cfgProfileSelect(name)'
need "$UI" 'cfg-profile-row'
need "$UI" "'list-external '"
need "$UI" "' import-external '"
need "$UI" "' export '"
need "$UI" "' preview '"
need "$UI" "' restore '"
absent "$UI" "prompt(T('cfg_profile_name'"
absent "$UI" "confirm(T('cfg_profile_replace_q'"
absent "$UI" "confirm(T('cfg_profile_preview'"
need "$HELPER" 'EXPORT_ROOT="${ASB_PROFILE_EXPORT_ROOT:-/sdcard}"'
need "$HELPER" '_export_dir()'
need "$HELPER" 'downloads)'
need "$HELPER" 'documents)'
need "$HELPER" 'list-external)'
need "$HELPER" 'import-external)'

# UV collector remains available to asbdiag but must not display ambiguous properties in WebUI.
need "$UV" 'asb_action" "diagnostics_only'
need "$UV" 'ASB does not own, write, validate, disable or revert external voltage policy'
absent "$UI" 'cfgUvCard'
absent "$UI" 'cfgLoadUvStatus'
absent "$UI" 'CFG_UV_HELPER'
absent "$UI" 'cfg_uv_'

# Profile labels remain localized in all supported UI locales. Removed UV card strings must not
# linger as dead UI surface translations.
python3 - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'webroot' / 'i18n'
keys = {'cfg_profile_save_short','cfg_profile_load_short','cfg_profile_storage_hint'}
manager_keys = {'cfg_profile_manager_title','cfg_profile_save_copy','cfg_profile_open_copy','cfg_profile_location','cfg_profile_store_asb','cfg_profile_store_downloads','cfg_profile_store_documents','cfg_profile_save_action','cfg_profile_replace','cfg_profile_name_hint','cfg_profile_replace_ready','cfg_profile_keys','cfg_profile_apply','cfg_profile_prepare_apply','cfg_profile_delete','cfg_profile_delete_confirm','cfg_profile_apply_hint','cfg_profile_export_err'}
files = sorted(root.glob('*.json'))
assert len(files) == 13, f'expected 13 locale files, got {len(files)}'
for p in files:
    data = json.loads(p.read_text(encoding='utf-8'))
    missing = sorted(k for k in keys if not isinstance(data.get(k), str) or not data[k].strip())
    assert not missing, f'{p.name}: missing {missing}'
    stale = sorted(k for k in data if k.startswith('cfg_uv_'))
    assert not stale, f'{p.name}: stale UV card keys {stale}'
    if p.stem in {'en', 'ru'}:
        missing_manager = sorted(k for k in manager_keys if not isinstance(data.get(k), str) or not data[k].strip())
        assert not missing_manager, f'{p.name}: missing manager keys {missing_manager}'
print('PASS profile locale keys and diagnostics-only UV boundary: 13 locales')
PY

echo 'PASS profile/UV package contract'
