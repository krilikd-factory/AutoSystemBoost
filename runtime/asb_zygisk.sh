#!/system/bin/sh
# Opt-in Zygisk observer administration. No application, Zygisk or LSPosed control.
# Optional lifecycle hints are native, bounded refresh requests to the existing governor;
# this helper never writes a hardware/policy node and is not a native trust boundary.

MODDIR="${ASB_ZYGISK_MODDIR:-/data/adb/modules/AutoSystemBoost}"
ZDIR="${ASB_ZYGISK_DIR:-/data/adb/asb/zygisk_observer}"
CONF="$MODDIR/config/governor.conf"
LIST="$ZDIR/packages.list"
DISABLE="$ZDIR/disable"
POLICY="${ASB_ZYGISK_POLICY:-$MODDIR/zygisk/policy}"
AUTO="$ZDIR/auto"
AUTO_BACKUP="$ZDIR/packages.before_auto"
AUTO_RUN="${ASB_ZYGISK_RUN_DIR:-/dev/.asb/zygisk}"
AUTO_COUNT="${ASB_ZYGISK_AOT_COUNT:-${ZDIR%/*}/zygisk_aot_count}"

_zygisk_prepare() {
  mkdir -p "$ZDIR" 2>/dev/null || return 1
  chmod 700 "$ZDIR" 2>/dev/null || true
  [ -f "$LIST" ] || true > "$LIST" || return 1
  chmod 600 "$LIST" 2>/dev/null || true
}

# Prints 0 for an ordinary application package, 1 for malformed or protected names.
_zygisk_package_invalid() {
  _p="$1"
  case "$_p" in
    *[!A-Za-z0-9_.]*|.*|*.|*..*|*:*|'') return 1 ;;
  esac
  [ "${#_p}" -ge 3 ] && [ "${#_p}" -le 127 ] || return 1
  case "$_p" in *.*) : ;; *) return 1 ;; esac
  case "$_p" in
    system_server|zygote|zygote32|zygote64|com.android.systemui|com.android.packageinstaller|\
    com.android.permissioncontroller|com.android.settings|com.android.phone|\
    com.android.providers.media|com.android.providers.downloads|com.android.shell*|\
    me.weishu.kernelsu|com.rifsxd.ksunext|com.topjohnwu.magisk|io.github.vvb2060.magisk|\
    org.lsposed.manager|com.tsng.hidemyapplist|android.*|com.qualcomm.*|com.qti.*|vendor.*|\
    com.oplus.safecenter*|com.coloros.safecenter*|com.heytap.safecenter*) return 1 ;;
  esac
  return 0
}

_zygisk_set_conf() {
  _key="$1"; _value="$2"
  [ -f "$CONF" ] || return 1
  _tmp="$CONF.zygisk.tmp"
  if grep -q "^[[:space:]]*$_key=" "$CONF" 2>/dev/null; then
    sed "s|^[[:space:]]*$_key=.*|$_key=$_value|" "$CONF" > "$_tmp" || return 1
  else
    cat "$CONF" > "$_tmp" && printf '%s=%s\n' "$_key" "$_value" >> "$_tmp" || return 1
  fi
  chmod 600 "$_tmp" 2>/dev/null || true
  mv -f "$_tmp" "$CONF"
}

_zygisk_list() {
  [ -r "$LIST" ] || return 0
  sed 's/[[:space:]]//g' "$LIST" 2>/dev/null | while IFS= read -r _p; do
    case "$_p" in ''|\#*) continue ;; esac
    _zygisk_package_invalid "$_p" && printf '%s\n' "$_p"
  done
}

_zygisk_set_packages() {
  _zygisk_prepare || return 1
  [ "$#" -le 64 ] || { echo 'At most 64 packages are allowed' >&2; return 2; }
  _tmp="$LIST.tmp"
  true > "$_tmp" || return 1
  for _p in "$@"; do
    if ! _zygisk_package_invalid "$_p"; then
      rm -f "$_tmp"
      echo "Invalid, malformed or protected package: $_p" >&2
      return 2
    fi
    if grep -Fxq "$_p" "$_tmp" 2>/dev/null; then
      rm -f "$_tmp"; echo "Duplicate package: $_p" >&2; return 2
    fi
    printf '%s\n' "$_p" >> "$_tmp" || return 1
  done
  chmod 600 "$_tmp" 2>/dev/null || true
  mv -f "$_tmp" "$LIST"
}

_zygisk_cfg() {
  sed -n "s/^[[:space:]]*$1=//p" "$CONF" 2>/dev/null | tail -n 1 | tr -d ' \r'
}

_zygisk_sync() {
  _s_en="$(_zygisk_cfg zygisk_enabled)"
  _s_mode="$(_zygisk_cfg zygisk_mode)"
  _s_hints="$(_zygisk_cfg zygisk_hints)"
  _s_launch="$(_zygisk_cfg zygisk_launch)"
  _s_ledger="$(_zygisk_cfg zygisk_ledger)"
  [ "$_s_hints" = 1 ] || _s_hints=0
  [ "$_s_launch" = 1 ] || _s_launch=0
  [ "$_s_ledger" = 1 ] || _s_ledger=0
  _s_pkgs="$(_zygisk_list)"
  _s_obs=0
  [ -n "$_s_pkgs" ] && _s_obs=1
  if [ "$_s_en" != 1 ] || [ -e "$DISABLE" ] || { [ -n "$_s_mode" ] && [ "$_s_mode" != observer ]; } || \
     { [ "$_s_obs" = 0 ] && [ "$_s_launch" = 0 ] && [ "$_s_ledger" = 0 ]; }; then
    rm -f "$POLICY" "$POLICY.tmp" 2>/dev/null
    echo 'policy=absent'
    return 0
  fi
  [ -d "${POLICY%/*}" ] || { echo 'policy=unavailable'; return 1; }
  _s_gen="$(date +%s 2>/dev/null)"
  case "$_s_gen" in ''|*[!0-9]*) _s_gen=1 ;; esac
  {
    printf 'v=2\ngen=%s\nobserver=%s\nhints=%s\nlaunch=%s\nledger=%s\n' \
      "$_s_gen" "$_s_obs" "$_s_hints" "$_s_launch" "$_s_ledger"
    printf '%s\n' "$_s_pkgs" | while IFS= read -r _s_p; do
      if [ -n "$_s_p" ]; then printf 'pkg=%s\n' "$_s_p"; fi
    done
  } > "$POLICY.tmp" 2>/dev/null || { rm -f "$POLICY.tmp" 2>/dev/null; echo 'policy=write_failed'; return 1; }
  chmod 644 "$POLICY.tmp" 2>/dev/null || true
  chcon u:object_r:system_file:s0 "$POLICY.tmp" 2>/dev/null || true
  mv -f "$POLICY.tmp" "$POLICY" 2>/dev/null || { rm -f "$POLICY.tmp" 2>/dev/null; echo 'policy=write_failed'; return 1; }
  echo "policy=written gen=$_s_gen observer=$_s_obs hints=$_s_hints launch=$_s_launch ledger=$_s_ledger"
}

# Automatic setup for non-experts (fix284). Only user-installed packages are candidates for
# observation. Usage history decides priority when more than 64 apps are installed; it never
# decides an AppOps restriction. The existing evidence-gated guard remains the only automatic
# background writer, with its own protected classes, read-back and exact restore ledger.
_zygisk_auto_candidates() {
  _zygisk_prepare || return 1
  _au="$ZDIR/auto-usage.tmp"
  {
    [ -r "$AUTO_COUNT" ] && sed -n 's/^\([A-Za-z0-9_.][A-Za-z0-9_.]*\) \([0-9][0-9]*\) [0-9][0-9]*$/\1 \2/p' "$AUTO_COUNT"
    cat "$AUTO_RUN"/state.*.tsv 2>/dev/null | awk -F '\t' '$1 == "L" && $2 ~ /^[A-Za-z0-9_.]+$/ && $5 ~ /^[0-9]+$/ { print $2, $5 }'
  } | awk 'NF == 2 { n[$1] += $2 + 0 } END { for (p in n) print n[p] "|" p }' > "$_au" 2>/dev/null || return 1
  # Keep NR==FNR unambiguous even when no usage history exists yet.
  printf '0|\n' >> "$_au" || return 1
  pm list packages -3 2>/dev/null | sed -n 's/^package:\([A-Za-z0-9_.]*\).*/\1/p' | while IFS= read -r _ap; do
    _zygisk_package_invalid "$_ap" && printf '%s\n' "$_ap"
  done | awk -F'|' 'NR == FNR { score[$2] = $1 + 0; next } NF { print score[$1] + 0 "|" $1 }' "$_au" - \
    | sort -t '|' -k1,1nr -k2,2 | head -n 64 | cut -d '|' -f2
}

_zygisk_auto_apply_list() {
  _zygisk_prepare || return 1
  _an="$ZDIR/packages.auto.tmp"
  _zygisk_auto_candidates > "$_an" || { rm -f "$_an"; return 1; }
  # Package Manager can be unavailable during an early service pass. Empty output is unknown,
  # not evidence that no apps are installed: keep the last good automatic selection.
  if [ ! -s "$_an" ]; then
    rm -f "$_an"
    [ -f "$LIST" ] || true > "$LIST"
    echo 'packages=unchanged'
    return 0
  fi
  if cmp -s "$_an" "$LIST" 2>/dev/null; then
    rm -f "$_an"; echo 'packages=unchanged'; return 0
  fi
  chmod 600 "$_an" 2>/dev/null || true
  mv -f "$_an" "$LIST" || { rm -f "$_an"; return 1; }
  echo 'packages=updated'
}

_zygisk_auto_config() {
  _ac="$MODDIR/runtime/asb_config_safe.sh"
  [ -f "$_ac" ] || return 1
  MODDIR="$MODDIR" ASB_CONFIG_STATE="${ASB_ZYGISK_CONFIG_STATE:-${ZDIR%/*}}" sh "$_ac" set-many --snapshot "${ASB_ZYGISK_SNAPSHOT:-${ZDIR%/*}/governor.conf.snapshot}" \
    zygisk_enabled "$1" zygisk_hints "$2" zygisk_launch "$3" zygisk_ledger "$4"
}

_zygisk_auto_enable() {
  [ ! -e "$DISABLE" ] || { echo 'result=safe_mode'; return 3; }
  [ -f "$MODDIR/runtime/asb_zygisk_guard.sh" ] && [ -f "$MODDIR/runtime/asb_zygisk_aot.sh" ] || { echo 'result=unavailable'; return 1; }
  _zygisk_prepare || { echo 'result=failed'; return 1; }
  if [ ! -e "$AUTO" ] && [ ! -e "$AUTO_BACKUP" ]; then
    [ -f "$LIST" ] || true > "$LIST"
    cp "$LIST" "$AUTO_BACKUP" 2>/dev/null || { echo 'result=failed'; return 1; }
    chmod 600 "$AUTO_BACKUP" 2>/dev/null || true
  fi
  _zygisk_auto_apply_list || { echo 'result=failed'; return 1; }
  _zygisk_auto_config 1 1 1 1 >/dev/null 2>&1 || { echo 'result=config_refused'; return 1; }
  _zygisk_sync >/dev/null 2>&1 || { echo 'result=policy_failed'; return 1; }
  MODDIR="$MODDIR" ASB_ZG_DIR="${ASB_ZG_DIR:-${ZDIR%/*}}" ASB_ZYGISK_RUN_DIR="$AUTO_RUN" sh "$MODDIR/runtime/asb_zygisk_guard.sh" enable wakers >/dev/null 2>&1 || { echo 'result=guard_failed'; return 1; }
  MODDIR="$MODDIR" ASB_ZA_DIR="${ASB_ZA_DIR:-${ZDIR%/*}}" ASB_ZYGISK_RUN_DIR="$AUTO_RUN" sh "$MODDIR/runtime/asb_zygisk_aot.sh" enable >/dev/null 2>&1 || { echo 'result=aot_failed'; return 1; }
  { echo 'version=1'; _at="$(date +%s 2>/dev/null)"; case "$_at" in ''|*[!0-9]*) _at=0 ;; esac; echo "updated=$_at"; } > "$AUTO.tmp" 2>/dev/null && mv -f "$AUTO.tmp" "$AUTO" || { echo 'result=failed'; return 1; }
  chmod 600 "$AUTO" 2>/dev/null || true
  echo 'result=enabled'
  echo "packages=$(_zygisk_list | wc -l | tr -d ' ')"
}

_zygisk_auto_refresh() {
  [ -e "$AUTO" ] || { echo 'result=not_automatic'; return 0; }
  _ar="$(_zygisk_auto_apply_list)" || { echo 'result=failed'; return 1; }
  # An unchanged hourly pass must not rewrite flash or advance the policy generation.
  if [ "$_ar" = packages=updated ] || [ ! -s "$POLICY" ]; then
    _zygisk_sync >/dev/null 2>&1 || { echo 'result=policy_failed'; return 1; }
  fi
  echo 'result=refreshed'
  echo "packages=$(_zygisk_list | wc -l | tr -d ' ')"
}

_zygisk_auto_disable() {
  [ -f "$MODDIR/runtime/asb_zygisk_guard.sh" ] && MODDIR="$MODDIR" ASB_ZG_DIR="${ASB_ZG_DIR:-${ZDIR%/*}}" ASB_ZYGISK_RUN_DIR="$AUTO_RUN" sh "$MODDIR/runtime/asb_zygisk_guard.sh" disable >/dev/null 2>&1
  [ -f "$MODDIR/runtime/asb_zygisk_aot.sh" ] && MODDIR="$MODDIR" ASB_ZA_DIR="${ASB_ZA_DIR:-${ZDIR%/*}}" ASB_ZYGISK_RUN_DIR="$AUTO_RUN" sh "$MODDIR/runtime/asb_zygisk_aot.sh" disable >/dev/null 2>&1
  _zygisk_prepare || return 1
  set --
  if [ -r "$AUTO_BACKUP" ]; then
    while IFS= read -r _rp; do
      [ -n "$_rp" ] && set -- "$@" "$_rp"
    done < "$AUTO_BACKUP"
  fi
  _zygisk_set_packages "$@" || { echo 'result=restore_failed'; return 1; }
  _zygisk_auto_config 0 0 0 0 >/dev/null 2>&1 || { echo 'result=config_refused'; return 1; }
  _zygisk_sync >/dev/null 2>&1 || true
  rm -f "$AUTO" "$AUTO.tmp" "$AUTO_BACKUP" "$ZDIR/auto-usage.tmp" "$ZDIR/packages.auto.tmp" 2>/dev/null
  echo 'result=disabled'
}

case "${1:-}" in
  sync)
    _zygisk_sync
    ;;
  auto-enable)
    _zygisk_auto_enable
    ;;
  auto-refresh)
    _zygisk_auto_refresh
    ;;
  auto-disable)
    _zygisk_auto_disable
    ;;
  list)
    _zygisk_list
    ;;
  set-packages)
    shift
    _zygisk_set_packages "$@" || exit $?
    _zygisk_sync >/dev/null 2>&1 || true
    ;;
  enable)
    [ ! -e "$DISABLE" ] || { echo 'Safe mode is active; clear it explicitly first' >&2; exit 3; }
    _zygisk_prepare && _zygisk_set_conf zygisk_enabled 1 && _zygisk_set_conf zygisk_mode observer || exit 1
    _zygisk_sync >/dev/null 2>&1 || true
    ;;
  disable)
    _zygisk_set_conf zygisk_enabled 0 || exit 1
    _zygisk_sync >/dev/null 2>&1 || true
    ;;
  safe-mode)
    case "${2:-on}" in
      on)
        _zygisk_prepare && true > "$DISABLE" && chmod 600 "$DISABLE" && _zygisk_set_conf zygisk_enabled 0 || exit 1
        _zygisk_sync >/dev/null 2>&1 || true
        ;;
      off)
        rm -f "$DISABLE" 2>/dev/null
        _zygisk_sync >/dev/null 2>&1 || true
        ;;
      *) echo 'Usage: safe-mode on|off' >&2; exit 2 ;;
    esac
    ;;
  link-status)
    # Small on-demand evidence snapshot for the shared WebUI header and unified card.
    # Reuse the exact read-only diagnostics collector; configuration and installed ABI
    # files alone never become connection evidence. No sync, writer or worker is started.
    PROC="${ASB_ZYGISK_PROC:-/proc}"
    DATA="${ASB_ZYGISK_DATA:-/data}"
    _read() { [ -r "$1" ] && cat "$1" 2>/dev/null; }
    _emit() { printf 'D\t%s\t%s\t%s\n' "$1" "$2" "$3"; }
    [ -r "$MODDIR/runtime/asb_zygisk_info.sh" ] || exit 1
    . "$MODDIR/runtime/asb_zygisk_info.sh" || exit 1
    _asb_zygisk_info
    ;;
  status)
    printf 'enabled=%s\n' "$(sed -n 's/^zygisk_enabled=//p' "$CONF" 2>/dev/null | head -n 1)"
    printf 'mode=%s\n' "$(sed -n 's/^zygisk_mode=//p' "$CONF" 2>/dev/null | head -n 1)"
    printf 'lifecycle_hints=%s\n' "$(sed -n 's/^zygisk_hints=//p' "$CONF" 2>/dev/null | head -n 1)"
    printf 'cold_start_lift=%s\n' "$(_zygisk_cfg zygisk_launch)"
    printf 'process_ledger=%s\n' "$(_zygisk_cfg zygisk_ledger)"
    printf 'policy=%s\n' "$([ -s "$POLICY" ] && sed -n 's/^gen=//p' "$POLICY" | head -n 1 || echo absent)"
    printf 'safe_mode=%s\n' "$([ -e "$DISABLE" ] && echo on || echo off)"
    printf 'automatic=%s\n' "$([ -e "$AUTO" ] && echo on || echo off)"
    printf 'packages=%s\n' "$(_zygisk_list | wc -l | tr -d ' ')"
    ;;
  *)
    echo 'Usage: asb_zygisk.sh sync|list|set-packages [pkg ...]|auto-enable|auto-refresh|auto-disable|enable|disable|safe-mode on|off|status|link-status' >&2
    exit 2
    ;;
esac
