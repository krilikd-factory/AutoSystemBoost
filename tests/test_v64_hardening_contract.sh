#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WRITER="$ROOT_DIR/runtime/asb_config_safe.sh"
BACKUP="$ROOT_DIR/tools/asb_config_backup.sh"
WEBUI="$ROOT_DIR/webroot/index.html"
DEBUG_WF="$ROOT_DIR/.github/workflows/build-debug.yml"
INSTALL="$ROOT_DIR/common/install.sh"
DIAG="$ROOT_DIR/tools/asb_diag.sh"
need() { grep -Fq "$2" "$1" || { echo "FAIL: $1 missing [$2]" >&2; exit 1; }; }
absent() { ! grep -Fq "$2" "$1" || { echo "FAIL: $1 still contains [$2]" >&2; exit 1; }; }

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
need "$BACKUP" 'ASB_SMART_PROFILE_SCHEMA=1'
need "$BACKUP" '_smart_file_ok()'
need "$BACKUP" 'smart_restore()'
need "$BACKUP" 'smart_learning=restored'

# UI must use the helper and object result handling; the former one-file /sdcard flow is gone.
need "$WEBUI" "const CFG_PROFILE_HELPER = MD + '/tools/asb_config_backup.sh';"
need "$WEBUI" 'data-i18n="cfg_profile_save_short"'
need "$WEBUI" 'data-i18n="cfg_profile_load_short"'
absent "$WEBUI" 'data-i18n="cfg_profile_storage_hint"'
need "$WEBUI" 'function cfgProfileNameOK(name)'
need "$WEBUI" ' cfgProfileArgs()'
need "$WEBUI" "' preview '"
need "$WEBUI" "' restore '"
need "$WEBUI" 'r.errno !== 0'
absent "$WEBUI" 'CFG_BACKUP_PATH'
need "$WEBUI" 'cfg_profile_smart_saved'
need "$WEBUI" 'smart_learning=restored'

# Debug identity changes only after rsync in package staging. It keeps the public
# versionCode so V64-debug1 can be manually flashed over V64; public source/OTA stay V64/640.
need "$DEBUG_WF" 'debug_sequence:'
need "$DEBUG_WF" 'DEBUG_CODE="$BASE_CODE"'
need "$DEBUG_WF" 'ASB_VER="${BASE_VER}-debug${DEBUG_SEQ}"'
need "$DEBUG_WF" 'sed -i "s/^version=.*/version=${ASB_VER}/" "$PKG_DBG/module.prop"'
need "$DEBUG_WF" 'grep -qx "versionCode=${BASE_CODE}" "$PKG_DBG/module.prop"'
absent "$DEBUG_WF" 'DEBUG_CODE=$((BASE_CODE + DEBUG_SEQ))'
need "$DEBUG_WF" 'name: ASB-${{ env.ASB_VER }}'

# Installer and diagnostics expose, but do not alter, the actual config migration result.
need "$INSTALL" 'ASB_CONFIG_MIGRATION_MODE=unknown'
need "$INSTALL" 'ASB_CONFIG_MIGRATION_MODE=fresh'
need "$INSTALL" 'ASB_CONFIG_MIGRATION_MODE=preserved'
need "$INSTALL" 'last_install_state'
need "$INSTALL" 'asb_prepare_webui_first_install()'
need "$INSTALL" 'Full component set prepared; optional tweaks remain at stock.'
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
