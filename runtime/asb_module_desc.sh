#!/system/bin/sh

ASB_MD_MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
ASB_MD_ZDIR="${ASB_ZYGISK_DIR:-/data/adb/asb/zygisk_observer}"
ASB_MD_RUN="${ASB_ZYGISK_RUN_DIR:-/dev/.asb/zygisk}"

asb_md_cfg() {
  sed -n "s/^[[:space:]]*$1=//p" "$ASB_MD_MODDIR/config/governor.conf" 2>/dev/null | head -n 1 | tr -d ' \r'
}

asb_md_zygisk() {
  if [ "$(asb_md_cfg zygisk_enabled)" != 1 ]; then
    printf ' | Zygisk ⏸️ off'
    return 0
  fi
  if [ ! -f "$ASB_MD_MODDIR/zygisk/arm64-v8a.so" ] && [ ! -f "$ASB_MD_MODDIR/zygisk/armeabi-v7a.so" ]; then
    printf ' | Zygisk ⛔ not installed'
    return 0
  fi
  if [ -e "$ASB_MD_ZDIR/disable" ]; then
    printf ' | Zygisk 🛟 safe mode'
    return 0
  fi
  if [ -s "$ASB_MD_RUN/state.arm64-v8a.tsv" ] || [ -s "$ASB_MD_RUN/state.armeabi-v7a.tsv" ]; then
    printf ' | Zygisk ✅ connected'
    return 0
  fi
  if [ ! -s "$ASB_MD_ZDIR/packages.list" ] && [ "$(asb_md_cfg zygisk_launch)" != 1 ] && [ "$(asb_md_cfg zygisk_ledger)" != 1 ]; then
    printf ' | Zygisk 💤 idle'
    return 0
  fi
  printf ' | Zygisk ⏳ waiting'
}

asb_md_refresh() {
  _amd_prop="$ASB_MD_MODDIR/module.prop"
  _amd_line="$(grep -m 1 '^description=' "$_amd_prop" 2>/dev/null)"
  [ -n "$_amd_line" ] || return 1
  _amd_base="${_amd_line%% \| Zygisk *}"
  case "$_amd_base" in
    'description=status: no profile selected'*) _amd_new="$_amd_base" ;;
    *) _amd_new="$_amd_base$(asb_md_zygisk)" ;;
  esac
  case "$_amd_new" in *[/\&\\]*) return 1 ;; esac
  [ "$_amd_new" = "$_amd_line" ] && return 0
  sed "s/^description=.*/$_amd_new/" "$_amd_prop" > "$_amd_prop.tmp" 2>/dev/null || { rm -f "$_amd_prop.tmp"; return 1; }
  if grep -qxF "$_amd_new" "$_amd_prop.tmp" 2>/dev/null; then
    cat "$_amd_prop.tmp" > "$_amd_prop"
  fi
  rm -f "$_amd_prop.tmp"
}

case "${0##*/}" in
  asb_module_desc.sh)
    case "${1:-refresh}" in
      suffix) asb_md_zygisk ;;
      refresh) asb_md_refresh ;;
      *) printf 'usage: asb_module_desc.sh suffix|refresh\n' >&2; exit 2 ;;
    esac
    ;;
esac
