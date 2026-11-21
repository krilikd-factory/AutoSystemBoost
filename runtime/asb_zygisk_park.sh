#!/system/bin/sh
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
MODS="${ASB_ZP_MODULES:-${MODDIR%/*}}"
ON="$MODDIR/zygisk"
OFF="$MODDIR/zygisk.off"

_zp_provider_dir() {
  _pd="$1"
  [ -e "$_pd/disable" ] && return 1
  [ -e "$_pd/remove" ] && return 1
  for _pb in "$_pd/bin/zygiskd" "$_pd/bin/zygiskd64" "$_pd/bin/zygiskd32" "$_pd"/bin/*/zygiskd; do
    [ -f "$_pb" ] && return 0
  done
  _pn="$(sed -n 's/^name=//p' "$_pd/module.prop" 2>/dev/null | head -n 1 | tr 'A-Z' 'a-z' | tr -d ' _\r-')"
  case "$_pn" in
    nyazygisk|neozygisk|brezygisk|rezygisk|zygisknext) return 0 ;;
  esac
  return 1
}

_zp_magisk_builtin() {
  [ -n "$KSU$APATCH" ] && return 1
  [ "${ZYGISK_ENABLED:-}" = 1 ] && return 0
  command -v magisk >/dev/null 2>&1 || return 1
  magisk --sqlite "SELECT value FROM settings WHERE key='zygisk'" 2>/dev/null | grep -q 'value=1'
}

zp_present() {
  _zp_magisk_builtin && return 0
  for _d in "$MODS"/*; do
    [ -d "$_d" ] || continue
    [ "$_d" = "$MODDIR" ] && continue
    _zp_provider_dir "$_d" && return 0
  done
  return 1
}

zp_state() {
  if [ -d "$ON" ]; then echo active
  elif [ -d "$OFF" ]; then echo parked
  else echo none
  fi
}

zp_apply() {
  if zp_present; then
    if [ ! -d "$ON" ] && [ -d "$OFF" ]; then
      mv "$OFF" "$ON" 2>/dev/null || return 1
    elif [ -d "$ON" ] && [ -d "$OFF" ]; then
      rm -rf "$OFF" 2>/dev/null
    fi
  else
    if [ -d "$ON" ]; then
      rm -rf "$OFF" 2>/dev/null
      mv "$ON" "$OFF" 2>/dev/null || return 1
    fi
  fi
  return 0
}

case "${1:-status}" in
  boot)
    zp_apply
    echo "asb_libraries=$(zp_state)"
    ;;
  unpark)
    if [ ! -d "$ON" ] && [ -d "$OFF" ] && zp_present; then zp_apply; fi
    echo "asb_libraries=$(zp_state)"
    ;;
  status)
    if zp_present; then echo provider=present; else echo provider=absent; fi
    echo "asb_libraries=$(zp_state)"
    ;;
  *)
    echo "usage: $0 boot|unpark|status" >&2
    exit 2
    ;;
esac
