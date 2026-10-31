#!/system/bin/sh
# Opt-in Zygisk observer administration. No application, Zygisk or LSPosed control.
# Optional lifecycle hints are native, bounded refresh requests to the existing governor;
# this helper never writes a hardware/policy node and is not a native trust boundary.

MODDIR="${ASB_ZYGISK_MODDIR:-/data/adb/modules/AutoSystemBoost}"
ZDIR="${ASB_ZYGISK_DIR:-/data/adb/asb/zygisk_observer}"
CONF="$MODDIR/config/governor.conf"
LIST="$ZDIR/packages.list"
DISABLE="$ZDIR/disable"

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
    com.android.providers.media|com.android.providers.downloads|com.android.shell|\
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

case "${1:-}" in
  list)
    _zygisk_list
    ;;
  set-packages)
    shift
    _zygisk_set_packages "$@"
    ;;
  enable)
    [ ! -e "$DISABLE" ] || { echo 'Safe mode is active; clear it explicitly first' >&2; exit 3; }
    _zygisk_prepare && _zygisk_set_conf zygisk_enabled 1 && _zygisk_set_conf zygisk_mode observer
    ;;
  disable)
    _zygisk_set_conf zygisk_enabled 0
    ;;
  safe-mode)
    case "${2:-on}" in
      on)
        _zygisk_prepare && true > "$DISABLE" && chmod 600 "$DISABLE" && _zygisk_set_conf zygisk_enabled 0
        ;;
      off)
        rm -f "$DISABLE" 2>/dev/null
        ;;
      *) echo 'Usage: safe-mode on|off' >&2; exit 2 ;;
    esac
    ;;
  status)
    printf 'enabled=%s\n' "$(sed -n 's/^zygisk_enabled=//p' "$CONF" 2>/dev/null | head -n 1)"
    printf 'mode=%s\n' "$(sed -n 's/^zygisk_mode=//p' "$CONF" 2>/dev/null | head -n 1)"
    printf 'lifecycle_hints=%s\n' "$(sed -n 's/^zygisk_hints=//p' "$CONF" 2>/dev/null | head -n 1)"
    printf 'safe_mode=%s\n' "$([ -e "$DISABLE" ] && echo on || echo off)"
    printf 'packages=%s\n' "$(_zygisk_list | wc -l | tr -d ' ')"
    ;;
  *)
    echo 'Usage: asb_zygisk.sh list|set-packages [pkg ...]|enable|disable|safe-mode on|off|status' >&2
    exit 2
    ;;
esac
