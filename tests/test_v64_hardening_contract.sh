#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WRITER="$ROOT_DIR/runtime/asb_config_safe.sh"
BACKUP="$ROOT_DIR/tools/asb_config_backup.sh"
WEBUI="$ROOT_DIR/webroot/index.html"
DEBUG_WF="$ROOT_DIR/.github/workflows/build-debug.yml"
RELEASE_WF="$ROOT_DIR/.github/workflows/build-release.yml"
MODULE_PROP="$ROOT_DIR/module.prop"
INSTALL="$ROOT_DIR/common/install.sh"
DIAG="$ROOT_DIR/tools/asb_diag.sh"
LINT="$ROOT_DIR/tools/asb_lint.sh"
REFERENCE_MODEL="$ROOT_DIR/docs/reference_models/asb_allocator_reference_model.py"
REFERENCE_DOC="$ROOT_DIR/docs/reference_models.md"
PROFILE_CORE="$ROOT_DIR/runtime/profile_core.sh"
BLUR_APPLY="$ROOT_DIR/runtime/asb_blur_apply.sh"
SERVICE="$ROOT_DIR/service.sh"
need() { grep -Fq -- "$2" "$1" || { echo "FAIL: $1 missing [$2]" >&2; exit 1; }; }
absent() { ! grep -Fq -- "$2" "$1" || { echo "FAIL: $1 still contains [$2]" >&2; exit 1; }; }

# Lock evidence and recovery must use the same canonical directory the writer acquires.
need "$WRITER" 'LOCK="$STATE/config.lock"'
need "$WRITER" 'LOCK_WAIT_TICKS="${ASB_CONFIG_LOCK_WAIT_TICKS:-100}"'
need "$WRITER" 'LOCK_STALE_S="${ASB_CONFIG_LOCK_STALE_S:-30}"'
need "$WRITER" '_lock_reclaim_stale()'
need "$WRITER" 'mv "$LOCK" "$_old"'
need "$WRITER" 'lock_path=config.lock'
need "$WRITER" 'lock_recovered=$_LOCK_RECOVERED'
absent "$WRITER" '$STATE/lock/pid'

# Profile manager is closed-name, checksum-protected and always restores through writer import.
need "$BACKUP" '_profile_ok()'
need "$BACKUP" 'config_profiles'
need "$BACKUP" 'profile checksum mismatch or absent'
# Exact writer call prevents a future direct sed/echo restore implementation.
need "$BACKUP" 'sh "$WRITER" import "$_in" "$SNAPSHOT" "$@"'
need "$BACKUP" 'list|create|replace|preview|restore|delete'
need "$BACKUP" 'ASB_SMART_PROFILE_SCHEMA=3'
need "$BACKUP" "'# ASB_SMART_PROFILE_SCHEMA=1'|'# ASB_SMART_PROFILE_SCHEMA=2'|'# ASB_SMART_PROFILE_SCHEMA=3'"
need "$BACKUP" '_smart_file_ok()'
need "$BACKUP" 'buckets.bin.bak'
need "$BACKUP" 'smart_mode_enabled'
need "$BACKUP" 'session_history.jsonl'
need "$BACKUP" 'session_stats.json'
need "$BACKUP" 'pstats_battery.json'
need "$BACKUP" '_smart_max_bytes()'
need "$BACKUP" 'smart_restore()'
need "$BACKUP" '.smart_restore.stage.$$'
need "$BACKUP" 'smart_learning=restored'
need "$BACKUP" 'smart_learning_files=$_n'
need "$BACKUP" 'smart_learning_bytes=$_total'
need "$BACKUP" '_migrate_legacy_external()'
need "$BACKUP" 'asb_settings_backup.conf'

# UI must use the helper and object result handling; the former one-file /sdcard flow is gone.
need "$WEBUI" "const CFG_PROFILE_HELPER = MD + '/tools/asb_config_backup.sh';"
need "$WEBUI" 'data-i18n="cfg_profile_save_short"'
need "$WEBUI" 'data-i18n="cfg_profile_load_short"'
absent "$WEBUI" 'data-i18n="cfg_profile_storage_hint"'
need "$WEBUI" 'function cfgProfileNameOK(name)'
need "$WEBUI" ' cfgProfileArgs()'
need "$WEBUI" "' restore '"
need "$WEBUI" 'function cfgProfilePaintYield()'
need "$WEBUI" '_cfgProfile.busy = true;'
need "$WEBUI" 'await cfgProfilePaintYield();'
need "$WEBUI" "T('cfg_profile_apply_wait','Please wait while ASB restores every saved setting. Do not close this window.')"
absent "$WEBUI" 'cfgProfilePreview'
absent "$WEBUI" 'cfg_profile_prepare_apply'
need "$WEBUI" 'r.errno !== 0'
absent "$WEBUI" 'CFG_BACKUP_PATH'
need "$WEBUI" 'cfg_profile_smart_saved'
need "$WEBUI" 'smart_learning=restored'
# night_modem_idle is read after governor config reload, so it must never fall through to
# the generic reboot-only metadata path.
need "$WEBUI" 'night_modem_idle:APPLY_LIVE'
need "$WEBUI" "'night_quiet_enable','night_modem_idle'"
need "$LINT" 'cards missing APPLY_MODE'
need "$LINT" 'locales missing global WebUI strings'

# `disable_blur=0` is a true user-owned stock/no-touch display state.  In particular, no
# post-boot WindowManager transaction may re-resolve a vendor screen-scale/density override.
# Explicit blur-off and an explicit WebUI return-to-stock action remain supported.
need "$PROFILE_CORE" '0) : ;;  # stock mode does not touch WindowManager or display configuration'
absent "$PROFILE_CORE" '0) asb_settings_put global disable_window_blurs 0'
need "$BLUR_APPLY" 'ASB_BLUR_BOOT_SYNC=0'
need "$BLUR_APPLY" '[ "${1:-}" = "--boot" ] && ASB_BLUR_BOOT_SYNC=1'
need "$BLUR_APPLY" 'elif [ "$ASB_BLUR_BOOT_SYNC" != "1" ]; then'
need "$BLUR_APPLY" 'wm disable-blur false >/dev/null 2>&1 || true'
need "$SERVICE" 'sh "$MODDIR/runtime/asb_blur_apply.sh" --boot >/dev/null 2>&1'
need "$SERVICE" 'elif [ "$_asb_blur_want" = "1" ]; then'
absent "$SERVICE" 'Re-assert BOTH directions, not just "off".'

# The former pytest file was a standalone reference implementation, not coverage of ASB C
# code. Keep it explicitly documented outside tests rather than pretending an unused Python
# dependency validates governor behaviour.
[ -f "$REFERENCE_MODEL" ] || { echo "FAIL: missing allocator reference model" >&2; exit 1; }
[ -f "$REFERENCE_DOC" ] || { echo "FAIL: missing reference-model boundary documentation" >&2; exit 1; }
need "$REFERENCE_DOC" '**not** executable tests of the AutoSystemBoost production implementation'
need "$REFERENCE_DOC" 'must be a host C harness'
if find "$ROOT_DIR/tests" -maxdepth 1 -type f -name '*invariant_asb_governor*' | grep -q .; then
  echo "FAIL: pytest reference model remains under tests" >&2; exit 1
fi
if grep -RIlE '^[[:space:]]*import[[:space:]]+pytest([[:space:]]|$)' "$ROOT_DIR/tests" 2>/dev/null | grep -q .; then
  echo "FAIL: pytest-dependent reference material remains under tests" >&2; exit 1
fi

# Debug identity changes only after rsync in package staging. It keeps the public
# versionCode so V64-debug1 can be manually flashed over V64; public source/OTA stay V64/640.
need "$DEBUG_WF" 'debug_sequence:'
need "$DEBUG_WF" 'Positive debug sequence after this public release'
need "$DEBUG_WF" 'DEBUG_SEQ_INPUT: ${{ inputs.debug_sequence }}'
need "$DEBUG_WF" 'DEBUG_SEQ="${DEBUG_SEQ_INPUT:-}"'
need "$DEBUG_WF" 'DEBUG_CODE="$BASE_CODE"'
need "$DEBUG_WF" 'ASB_VER="${BASE_VER}-debug${DEBUG_SEQ}"'
need "$DEBUG_WF" 'sed -i "s/^version=.*/version=${ASB_VER}/" "$PKG_DBG/module.prop"'
need "$DEBUG_WF" 'grep -qx "versionCode=${BASE_CODE}" "$PKG_DBG/module.prop"'
absent "$DEBUG_WF" 'DEBUG_CODE=$((BASE_CODE + DEBUG_SEQ))'
absent "$DEBUG_WF" 'one integer from 1 to 9'
need "$DEBUG_WF" 'name: ASB-${{ env.ASB_VER }}'

# Execute the workflow's real validation fragment: debug suffixes are local identifiers,
# therefore every positive decimal integer is valid (including debug10 and numbers larger
# than a single digit), but ambiguous/unsafe spellings must never become filenames or shell
# input. `exit 1` runs inside the subshell only.
TMP_DEBUG_GATE="$(mktemp -d)"
trap 'rm -rf "$TMP_DEBUG_GATE"' EXIT HUP INT TERM
sed -n '/^          DEBUG_SEQ="${DEBUG_SEQ_INPUT:-}"$/,/^          DEBUG_CODE="$BASE_CODE"$/p' "$DEBUG_WF" > "$TMP_DEBUG_GATE/gate.sh"
[ -s "$TMP_DEBUG_GATE/gate.sh" ] || { echo 'FAIL: debug workflow validation fragment missing' >&2; exit 1; }
debug_sequence_valid() (
  BASE_CODE=640 DEBUG_SEQ_INPUT="$1"
  . "$TMP_DEBUG_GATE/gate.sh"
  [ "$DEBUG_SEQ" = "$1" ]
)
for _valid_seq in 1 9 10 42 999999999; do
  debug_sequence_valid "$_valid_seq" || { echo "FAIL: valid debug sequence rejected: $_valid_seq" >&2; exit 1; }
done
for _invalid_seq in '' 0 00 01 -1 +1 1.0 debug10 '10 '; do
  # The real gate deliberately writes a GitHub `::error::` for invalid manual input.
  # This is a negative host fixture, not a failed CI build; capture that expected text so
  # a passing test cannot manufacture red workflow annotations in the parent job.
  if debug_sequence_valid "$_invalid_seq" >"$TMP_DEBUG_GATE/invalid.out" 2>&1; then
    echo "FAIL: invalid debug sequence accepted: $_invalid_seq" >&2
    exit 1
  fi
done
if ( BASE_CODE=64x DEBUG_SEQ_INPUT=10 . "$TMP_DEBUG_GATE/gate.sh" ) >"$TMP_DEBUG_GATE/invalid-base-code.out" 2>&1; then
  echo 'FAIL: non-decimal module versionCode accepted by debug gate' >&2
  exit 1
fi

# Public module identity is build-critical. OTA metadata and GitHub-facing changelog are
# deliberately outside build-time contracts: both are publication documents that may be updated
# only after the first V64 asset is available, so neither can block debug or release compilation.
need "$MODULE_PROP" 'version=V64'
need "$MODULE_PROP" 'versionCode=640'

# Release publication must validate the immutable public identity rather than patching it from
# an arbitrary GitHub tag. Exercise the literal workflow fragment under safe subshell fixtures.
need "$RELEASE_WF" '- name: Validate release tag'
need "$RELEASE_WF" 'GITHUB_EVENT_NAME'
need "$RELEASE_WF" 'GITHUB_REF_TYPE'
need "$RELEASE_WF" 'does not match module version'
absent "$RELEASE_WF" 'sed -i "s/^version=.*/version=${TAG}/" module.prop'
TMP_RELEASE_GATE="$(mktemp -d)"
trap 'rm -rf "$TMP_DEBUG_GATE" "$TMP_RELEASE_GATE"' EXIT HUP INT TERM
sed -n '/^          TAG="${GITHUB_REF_NAME:-}"$/,/^          fi$/p' "$RELEASE_WF" | sed 's/^          //' > "$TMP_RELEASE_GATE/gate.sh"
[ -s "$TMP_RELEASE_GATE/gate.sh" ] || { echo 'FAIL: release workflow identity gate missing' >&2; exit 1; }
release_identity_valid() (
  cd "$ROOT_DIR"
  GITHUB_REF_NAME="$1" GITHUB_EVENT_NAME="$2" GITHUB_REF_TYPE="$3"
  . "$TMP_RELEASE_GATE/gate.sh"
)
# workflow_dispatch uses the selected branch as ref name; it must not be treated as a
# release tag and therefore must pass for main or any other branch.
for _manual_ref in '' main develop maintenance/V64; do
  release_identity_valid "$_manual_ref" workflow_dispatch branch || { echo "FAIL: manual branch build rejected: $_manual_ref" >&2; exit 1; }
done
# GitHub Release and tag-ref runs may publish an asset, so only spellings for V64 are valid.
for _valid_tag in V64 v64 64; do
  release_identity_valid "$_valid_tag" release tag || { echo "FAIL: accepted release tag rejected: $_valid_tag" >&2; exit 1; }
  release_identity_valid "$_valid_tag" push tag || { echo "FAIL: accepted tag ref rejected: $_valid_tag" >&2; exit 1; }
done
for _invalid_tag in '' main V63 v63 63 V65 v65 65 debug10 'V64 '; do
  if release_identity_valid "$_invalid_tag" release tag >"$TMP_RELEASE_GATE/invalid-tag.out" 2>&1; then
    echo "FAIL: mismatched release tag accepted: $_invalid_tag" >&2
    exit 1
  fi
done

# Installer and diagnostics expose, but do not alter, the actual config migration result.
need "$INSTALL" 'ASB_CONFIG_MIGRATION_MODE=unknown'
need "$INSTALL" 'ASB_CONFIG_MIGRATION_MODE=fresh'
need "$INSTALL" 'ASB_CONFIG_MIGRATION_MODE=preserved'
need "$INSTALL" 'last_install_state'
need "$INSTALL" 'asb_prepare_webui_first_install()'
need "$INSTALL" 'Full component set prepared; optional tweaks remain at stock.'
absent "$INSTALL" 'All components are prepared. Optional tweaks stay stock until you choose them in WebUI.'
need "$INSTALL" 'ASB_DSP_REGISTRATION_DONE'
need "$INSTALL" 'ASB_SEC_AUDIO:-AUDIO} · ${ASB_SEC_DSP:-DSP ENGINE}'
need "$INSTALL" 'ASB_AUDIO_CLONE_DEFER=1'
need "$INSTALL" 'ASB_L_MIRROR_AUDIO_TOTAL'
need "$INSTALL" 'asb_neutralise_fresh_install'
absent "$INSTALL" 'asb_choose_cat AUDIO'
need "$DIAG" 'last install: config='

for f in "$ROOT_DIR"/webroot/i18n/*.json; do
  need "$f" '"cfg_profile_name"'
  need "$f" '"cfg_profile_restored"'
  need "$f" '"cfg_profile_save"'
  need "$f" '"cfg_profile_load"'
  need "$f" '"cfg_profile_save_short"'
  need "$f" '"cfg_profile_load_short"'
  # EN/RU carry the dedicated Smart strings; other locales fall back to English through T().
done
cmp -s "$ROOT_DIR/tools/asb_diag.sh" "$ROOT_DIR/system/bin/asbdiag" || { echo 'FAIL: asbdiag copies differ' >&2; exit 1; }
echo 'PASS V64 hardening contract'
