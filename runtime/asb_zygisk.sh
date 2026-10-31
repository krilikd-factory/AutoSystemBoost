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

case "${1:-}" in
  sync)
    _zygisk_sync
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
    printf 'packages=%s\n' "$(_zygisk_list | wc -l | tr -d ' ')"
    ;;
  *)
    echo 'Usage: asb_zygisk.sh sync|list|set-packages [pkg ...]|enable|disable|safe-mode on|off|status|link-status' >&2
    exit 2
    ;;
esac
