#!/system/bin/sh
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
D="${ASB_NF_DIR:-/data/adb/asb}"
LED="$D/notif_fix"
KEEP="${ASB_DOZE_KEEP:-$D/doze_whitelist_keep}"
WLMAN="$D/wakelock_manual"
[ -f "$MODDIR/runtime/asb_settings.sh" ] && . "$MODDIR/runtime/asb_settings.sh"

_has() { command -v "$1" >/dev/null 2>&1; }
_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}
_pkgok() {
  case "$1" in ''|*[!A-Za-z0-9_.]*|.*|*..*) return 1 ;; esac
  return 0
}
_users() {
  pm list packages -3 -U 2>/dev/null | sed -n 's/^package:\([A-Za-z0-9_.]*\) uid:\([0-9]*\).*/\1 \2/p'
}
_ops() { appops get "$1" 2>/dev/null; }
_pmode() {
  printf '%s\n' "$1" | grep -v 'Uid mode' | sed -n "s/^[[:space:]]*$2: \([a-z_]*\).*/\1/p" | head -1
}
_umode() {
  printf '%s\n' "$1" | sed -n "s/.*Uid mode: $2: \([a-z_]*\).*/\1/p" | head -1
}
_eff() {
  _ef="$(_umode "$1" "$2")"
  case "$_ef" in ''|default) _ef="$(_pmode "$1" "$2")" ;; esac
  printf '%s' "${_ef:-default}"
}
_wlist() { dumpsys deviceidle whitelist 2>/dev/null; }
_wl_kind() {
  printf '%s\n' "$1" | awk -F, -v p="$2" '$2 == p { k = $1; if (k == "user") { print "user"; f = 1; exit } }
    END { if (!f) print (k != "" ? "system" : "none") }'
}
_np_cmd() {
  case "$2" in deny) _nc_a=blacklist; _nc_b=denylist ;; *) _nc_a=whitelist; _nc_b=allowlist ;; esac
  _nc_o="$(cmd netpolicy "$1" "restrict-background-$_nc_a" $3 2>&1)"
  case "$_nc_o" in
    *[Ee]rror*|*[Uu]nknown*|*[Ii]nvalid*|*[Uu]nsupported*) cmd netpolicy "$1" "restrict-background-$_nc_b" $3 2>&1 ;;
    *) printf '%s\n' "$_nc_o" ;;
  esac
}
_np_list() { _np_cmd list "$1" "" | sed 's/^[^:]*://' | tr ' ,' '\n\n' | grep -E '^[0-9]+$'; }
_np_saver() {
  case "$(cmd netpolicy get restrict-background 2>/dev/null)" in *enabled*) echo on ;; *) echo off ;; esac
}
_bucket() {
  _bk="$(am get-standby-bucket "$1" 2>/dev/null | tr -d ' \r' | head -1)"
  case "$_bk" in
    ''|*[!0-9A-Za-z_]*) echo unknown ;;
    *) printf '%s' "$_bk" ;;
  esac
}
_line() { awk -F'|' -v p="$1" '$1 == p { print; exit }' "$LED" 2>/dev/null; }
_drop() {
  [ -s "$LED" ] || return 0
  awk -F'|' -v p="$1" '$1 != p' "$LED" > "$LED.tmp" 2>/dev/null || return 1
  if [ -s "$LED.tmp" ]; then mv -f "$LED.tmp" "$LED"; else rm -f "$LED.tmp" "$LED"; fi
}
_setf() {
  awk -F'|' -v OFS='|' -v p="$1" -v i="$2" -v v="$3" '$1 == p { $i = v } { print }' "$LED" > "$LED.tmp" 2>/dev/null \
    && mv -f "$LED.tmp" "$LED"
}
_keep_add() {
  grep -qxF "$1" "$KEEP" 2>/dev/null && return 1
  mkdir -p "${KEEP%/*}" 2>/dev/null
  printf '%s\n' "$1" >> "$KEEP"
}
_keep_del() {
  [ -f "$KEEP" ] || return 0
  grep -vxF "$1" "$KEEP" > "$KEEP.tmp" 2>/dev/null
  mv -f "$KEEP.tmp" "$KEEP" 2>/dev/null
}
_record() {
  _ro="$(_ops "$1")"
  _rw="$(_wlist)"
  _rd=0; [ "$(_wl_kind "$_rw" "$1")" = user ] && _rd=1
  _rdn=0; _np_list deny | grep -qx "$2" && _rdn=1
  _raw=0; grep -q "^$1|" "$WLMAN" 2>/dev/null && _raw=1
  _rk=0; grep -qxF "$1" "$KEEP" 2>/dev/null || _rk=1
  mkdir -p "$D" 2>/dev/null
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|0|%s|%s\n' "$1" "$2" "$_rd" \
    "$(_pmode "$_ro" RUN_ANY_IN_BACKGROUND | sed 's/^$/default/')" "$(_umode "$_ro" RUN_ANY_IN_BACKGROUND | sed 's/^$/default/')" \
    "$(_pmode "$_ro" RUN_IN_BACKGROUND | sed 's/^$/default/')" "$(_umode "$_ro" RUN_IN_BACKGROUND | sed 's/^$/default/')" \
    "$(_pmode "$_ro" WAKE_LOCK | sed 's/^$/default/')" "$(_umode "$_ro" WAKE_LOCK | sed 's/^$/default/')" \
    "$_rdn" "$_raw" "$_rk" >> "$LED"
}
_apply() {
  _ap="$1"; _au="$2"
  [ "$(_wl_kind "$(_wlist)" "$_ap")" = none ] && dumpsys deviceidle whitelist "+$_ap" >/dev/null 2>&1
  _ao="$(_ops "$_ap")"
  for _aop in RUN_ANY_IN_BACKGROUND RUN_IN_BACKGROUND WAKE_LOCK; do
    case "$(_pmode "$_ao" "$_aop")" in ignore|deny|errored) appops set "$_ap" "$_aop" allow >/dev/null 2>&1 ;; esac
    case "$(_umode "$_ao" "$_aop")" in ignore|deny|errored) appops set --uid "$_ap" "$_aop" allow >/dev/null 2>&1 ;; esac
  done
  _np_list deny | grep -qx "$_au" && _np_cmd remove deny "$_au" >/dev/null 2>&1
  if [ "$(_np_saver)" = on ] && ! _np_list allow | grep -qx "$_au"; then
    _np_cmd add allow "$_au" >/dev/null 2>&1
    _np_list allow | grep -qx "$_au" && _setf "$_ap" 11 1
  fi
  _keep_add "$_ap" >/dev/null 2>&1
  if grep -q "^$_ap|" "$WLMAN" 2>/dev/null && [ -f "$MODDIR/runtime/asb_wakelock_watch.sh" ]; then
    MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_wakelock_watch.sh" manual-set "$_ap" restore >/dev/null 2>&1
  fi
}
_check() {
  _co="$(_ops "$1")"
  _cd="$(_wl_kind "$(_wlist)" "$1")"
  _cra="$(_eff "$_co" RUN_ANY_IN_BACKGROUND)"; _crb="$(_eff "$_co" RUN_IN_BACKGROUND)"; _cwk="$(_eff "$_co" WAKE_LOCK)"
  _cpn="$(_eff "$_co" POST_NOTIFICATION)"
  _cbg=ok
  _np_list deny | grep -qx "$2" && _cbg=denied
  [ "$_cbg" = ok ] && [ "$(_np_saver)" = on ] && ! _np_list allow | grep -qx "$2" && _cbg=saver
  _cok=1
  [ "$_cd" = none ] && _cok=0
  case "$_cra$_crb$_cwk" in *ignore*|*deny*|*errored*) _cok=0 ;; esac
  [ "$_cbg" = ok ] || _cok=0
  printf 'row|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$_cok" "$_cd" "$_cra" "$_crb" "$_cwk" "$_cpn" "$(_bucket "$1")" "$_cbg"
}
_rop() {
  [ "$(_pmode "$_ro" "$1" | sed 's/^$/default/')" = "$2" ] || appops set "$_rp" "$1" "$2" >/dev/null 2>&1
  [ "$(_umode "$_ro" "$1" | sed 's/^$/default/')" = "$3" ] || appops set --uid "$_rp" "$1" "$3" >/dev/null 2>&1
}
_restore() {
  _l="$(_line "$1")"
  [ -n "$_l" ] || return 0
  _oifs="$IFS"; IFS='|'; set -- $_l; IFS="$_oifs"
  _rp="$1"; _ru="$2"; _rdz="$3"; _rdn="${10}"; _ral="${11}"; _raw="${12}"; _rk="${13}"
  _ro="$(_ops "$_rp")"
  _rop RUN_ANY_IN_BACKGROUND "${4:-default}" "${5:-default}"
  _rop RUN_IN_BACKGROUND "${6:-default}" "${7:-default}"
  _rop WAKE_LOCK "${8:-default}" "${9:-default}"
  if [ "$_rdz" = 0 ] && [ "$_rk" = 1 ]; then
    [ "$(_wl_kind "$(_wlist)" "$_rp")" = user ] && dumpsys deviceidle whitelist "-$_rp" >/dev/null 2>&1
  fi
  [ "$_rdn" = 1 ] && _np_cmd add deny "$_ru" >/dev/null 2>&1
  [ "$_ral" = 1 ] && _np_cmd remove allow "$_ru" >/dev/null 2>&1
  if [ "${ASB_NF_UNINSTALL:-0}" != 1 ]; then
    [ "$_rk" = 1 ] && _keep_del "$_rp"
    if [ "$_raw" = 1 ] && [ -f "$MODDIR/runtime/asb_wakelock_watch.sh" ]; then
      MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_wakelock_watch.sh" manual-set "$_rp" ignore >/dev/null 2>&1
    fi
  fi
  _drop "$_rp"
}
_findings() {
  _fs=""
  [ "$(_cfg gms_trim)" = strict ] && _fs="$_fs gms_strict"
  if [ "$(_cfg gms_trim)" != strict ] && [ "$(_wl_kind "$(_wlist)" com.google.android.gms)" = none ] \
     && pm list packages com.google.android.gms 2>/dev/null | grep -qx 'package:com.google.android.gms'; then
    _fs="$_fs gms_not_exempt"
  fi
  case "$(_cfg doze_level)" in aggressive) _fs="$_fs doze_aggressive" ;; night) _fs="$_fs doze_night" ;; esac
  [ "$(_cfg doze_trim_whitelist)" = 1 ] && _fs="$_fs doze_trim"
  [ "$(_cfg wakelock_action)" = 1 ] && _fs="$_fs wakelock_action"
  [ "$(_cfg heytap_mcs)" = off ] && _fs="$_fs heytap_off"
  [ "$(_cfg athena_service)" = off ] || _fs="$_fs athena_on"
  [ "$(settings get global low_power 2>/dev/null | tr -d ' \r')" = 1 ] && _fs="$_fs battery_saver"
  [ "$(_np_saver)" = on ] && _fs="$_fs data_saver"
  printf 'findings=%s\n' "${_fs# }"
}
_status() {
  echo 'version=1'
  _has appops && _has dumpsys && _has pm || { echo 'tools=missing'; return 0; }
  _findings
  _sn=0; [ -s "$LED" ] && _sn="$(grep -c '|' "$LED" 2>/dev/null)"
  echo "selected=${_sn:-0}"
  [ -s "$LED" ] || return 0
  _su="$(_users)"
  while IFS='|' read -r _sp _suid _rest; do
    _pkgok "$_sp" || continue
    if printf '%s\n' "$_su" | grep -q "^$_sp "; then _check "$_sp" "$_suid" </dev/null
    else printf 'row|%s|0|gone|-|-|-|-|-|-\n' "$_sp"; fi
  done < "$LED"
}
_set() {
  _has appops && _has dumpsys && _has pm || { echo 'result=unavailable'; return 1; }
  _su="$(_users)"
  [ -n "$_su" ] || { echo 'result=unavailable'; return 1; }
  _want=""
  for _wp in "$@"; do
    _pkgok "$_wp" || continue
    printf '%s\n' "$_su" | grep -q "^$_wp " || continue
    _want="$_want $_wp"
  done
  if [ -s "$LED" ]; then
    for _op in $(cut -d'|' -f1 "$LED"); do
      case " $_want " in *" $_op "*) : ;; *) _restore "$_op" ;; esac
    done
  fi
  _n=0
  for _wp in $_want; do
    _wu="$(printf '%s\n' "$_su" | awk -v p="$_wp" '$1 == p { print $2; exit }')"
    [ -n "$(_line "$_wp")" ] || _record "$_wp" "$_wu"
    _apply "$_wp" "$_wu"
    _n=$((_n + 1))
  done
  echo "result=ok"
  echo "selected=$_n"
  for _wp in $_want; do
    _check "$_wp" "$(printf '%s\n' "$_su" | awk -v p="$_wp" '$1 == p { print $2; exit }')"
  done
}
_reapply() {
  [ -s "$LED" ] || return 0
  _has appops && _has dumpsys && _has pm || return 0
  _su="$(_users)"
  [ -n "$_su" ] || return 0
  _gone=""
  while IFS='|' read -r _rp _ruid _rest; do
    _pkgok "$_rp" || continue
    if printf '%s\n' "$_su" | grep -q "^$_rp "; then _apply "$_rp" "$_ruid" </dev/null
    else _gone="$_gone $_rp"; fi
  done < "$LED"
  for _rp in $_gone; do
    [ "$(_line "$_rp" | cut -d'|' -f13)" = 1 ] && _keep_del "$_rp"
    _drop "$_rp"
  done
}
_restore_all() {
  [ -s "$LED" ] || { rm -f "$LED" 2>/dev/null; return 0; }
  for _op in $(cut -d'|' -f1 "$LED"); do
    _pkgok "$_op" && _restore "$_op"
  done
  rm -f "$LED" "$LED.tmp" 2>/dev/null
}

case "${1:-status}" in
  status) _status ;;
  apps)
    _users | while read -r _ap _au; do echo "A $_ap"; done
    [ -s "$LED" ] && cut -d'|' -f1 "$LED" | while read -r _ap; do _pkgok "$_ap" && echo "S $_ap"; done
    ;;
  set) shift; _set "$@" ;;
  reapply) _reapply ;;
  restore-all) _restore_all ;;
  *) echo 'result=bad_request'; exit 2 ;;
esac
exit 0
