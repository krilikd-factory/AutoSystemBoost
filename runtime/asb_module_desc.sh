#!/system/bin/sh

ASB_MD_MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
ASB_MD_ZDIR="${ASB_ZYGISK_DIR:-/data/adb/asb/zygisk_observer}"
ASB_MD_RUN="${ASB_ZYGISK_RUN_DIR:-/dev/.asb/zygisk}"

asb_md_cfg() {
  sed -n "s/^[[:space:]]*$1=//p" "$ASB_MD_MODDIR/config/governor.conf" 2>/dev/null | head -n 1 | tr -d ' \r'
}

asb_md_zstate() {
  if [ "$(asb_md_cfg zygisk_enabled)" != 1 ]; then
    printf 'off\n'
  elif [ ! -f "$ASB_MD_MODDIR/zygisk/arm64-v8a.so" ] && [ ! -f "$ASB_MD_MODDIR/zygisk/armeabi-v7a.so" ]; then
    printf 'not_installed\n'
  elif [ -e "$ASB_MD_ZDIR/disable" ]; then
    printf 'safe\n'
  elif [ -s "$ASB_MD_RUN/state.arm64-v8a.tsv" ] || [ -s "$ASB_MD_RUN/state.armeabi-v7a.tsv" ]; then
    printf 'connected\n'
  elif [ ! -s "$ASB_MD_ZDIR/packages.list" ] && [ "$(asb_md_cfg zygisk_launch)" != 1 ] && [ "$(asb_md_cfg zygisk_ledger)" != 1 ]; then
    printf 'idle\n'
  else
    printf 'waiting\n'
  fi
}

asb_md_zygisk() {
  case "$(asb_md_zstate)" in
    off) printf '[Zygisk 🧩 off ⏸️]' ;;
    not_installed) printf '[Zygisk 🧩 not installed ⛔]' ;;
    safe) printf '[Zygisk 🧩 safe mode 🛟]' ;;
    connected) printf '[Zygisk 🧩 connected ✅]' ;;
    idle) printf '[Zygisk 🧩 idle 💤]' ;;
    *) printf '[Zygisk 🧩 waiting ⏳]' ;;
  esac
}

asb_md_profile() {
  case "$1" in
    performance) printf '[Performance 🔥 active ✅]' ;;
    battery) printf '[Battery 🔋 active ✅]' ;;
    smart) printf '[Smart Mode 🤖 active ✅]' ;;
    stock) printf '[Stock 👶🏻 active ✅]' ;;
    ''|none) printf '[no profile selected — open the WebUI to choose one]' ;;
    *) printf '[Balanced ⚖️ active ✅]' ;;
  esac
}

asb_md_line() {
  _amd_p="$(tr -d ' \t\r\n' < "$ASB_MD_MODDIR/current_profile" 2>/dev/null)"
  case "$_amd_p" in
    ''|none) printf 'description=%s\n' "$(asb_md_profile "$_amd_p")" ;;
    *) printf 'description=%s   %s\n' "$(asb_md_profile "$_amd_p")" "$(asb_md_zygisk)" ;;
  esac
}

asb_md_refresh() {
  _amd_prop="$ASB_MD_MODDIR/module.prop"
  _amd_line="$(grep -m 1 '^description=' "$_amd_prop" 2>/dev/null)"
  [ -n "$_amd_line" ] || return 1
  _amd_new="$(asb_md_line)"
  case "$_amd_new" in ''|*[/\&\\]*) return 1 ;; esac
  [ "$_amd_new" = "$_amd_line" ] && return 0
  sed "s/^description=.*/$_amd_new/" "$_amd_prop" > "$_amd_prop.tmp" 2>/dev/null || { rm -f "$_amd_prop.tmp"; return 1; }
  if grep -qxF "$_amd_new" "$_amd_prop.tmp" 2>/dev/null; then
    cat "$_amd_prop.tmp" > "$_amd_prop"
  fi
  rm -f "$_amd_prop.tmp"
}

asb_md_settle() {
  _amd_n=0
  while :; do
    asb_md_refresh
    [ "$(asb_md_zstate)" = waiting ] || return 0
    [ "$_amd_n" -lt "${ASB_MD_SETTLE_STEPS:-60}" ] || return 0
    sleep "${ASB_MD_SETTLE_SLEEP:-10}"
    _amd_n=$((_amd_n + 1))
  done
}

case "${0##*/}" in
  asb_module_desc.sh)
    case "${1:-refresh}" in
      suffix) asb_md_zygisk ;;
      state) asb_md_zstate ;;
      line) asb_md_line ;;
      refresh) asb_md_refresh ;;
      settle) asb_md_settle ;;
      *) printf 'usage: asb_module_desc.sh suffix|state|line|refresh|settle\n' >&2; exit 2 ;;
    esac
    ;;
esac
