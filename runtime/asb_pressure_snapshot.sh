#!/system/bin/sh

MODDIR="${ASB_PRESSURE_MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
[ -r "$MODDIR/runtime/asb_pressure.sh" ] || MODDIR=/data/adb/modules/AutoSystemBoost
SYS="${ASB_PRESSURE_SYS:-/sys}"
PROC="${ASB_PRESSURE_PROC:-/proc}"

_clean() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-300
}
_emit() {
  [ -n "$1" ] && [ -n "$2" ] || return 0
  _v="$(_clean "$3")"
  [ -n "$_v" ] || _v='—'
  printf 'D\t%s\t%s\t%s\n' "$1" "$2" "$_v"
}
_read() { [ -r "$1" ] && cat "$1" 2>/dev/null; }
_mem() { sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n 1; }

[ -r "$MODDIR/runtime/asb_pressure.sh" ] || { printf 'D\tsystem_load\tscore\tunknown\n'; exit 1; }
. "$MODDIR/runtime/asb_pressure.sh"
_asb_pressure_collect
