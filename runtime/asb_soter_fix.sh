#!/system/bin/sh

PKG=com.tencent.soter.soterserver
STATE="${ASB_SOTER_STATE_DIR:-/data/adb/asb/soter_fix}"
PKGLIST="${ASB_SOTER_PACKAGES_LIST:-/data/system/packages.list}"
WAIT_STEPS="${ASB_SOTER_WAIT_STEPS:-10}"
LOCK="$STATE/run.lock"
MODE="${1:-status}"

_sf_installed() {
  if [ -r "$PKGLIST" ]; then
    grep -q "^$PKG " "$PKGLIST" 2>/dev/null && return 0
    return 1
  fi
  command -v pm >/dev/null 2>&1 || return 2
  pm path "$PKG" 2>/dev/null | grep -q '^package:' && return 0
  return 1
}

_sf_services() {
  getprop 2>/dev/null | sed -n 's/^\[init\.svc\.\([A-Za-z0-9_.@-]*soter[A-Za-z0-9_.@-]*\)\]: \[\([a-z_]*\)\].*/\1/p' | head -n 4
}

_sf_state() {
  _ss="$(getprop "init.svc.$1" 2>/dev/null)"
  case "$_ss" in ''|*[!a-z_]*) printf 'unknown' ;; *) printf '%s' "$_ss" ;; esac
}

_sf_services_line() {
  _sl=''
  for _s in $(_sf_services); do
    _sl="${_sl:+$_sl,}$_s:$(_sf_state "$_s")"
  done
  printf '%s' "${_sl:-none}"
}

_sf_last() {
  _lt="$(sed -n 's/^time=\([0-9]*\)$/\1/p' "$STATE/last" 2>/dev/null | head -n 1)"
  _lr="$(sed -n 's/^result=\([a-z_]*\)$/\1/p' "$STATE/last" 2>/dev/null | head -n 1)"
  printf 'last_time=%s|last_result=%s' "${_lt:-0}" "${_lr:-none}"
}

_sf_status() {
  _sf_installed
  case $? in 0) _si=1 ;; 1) _si=0 ;; *) _si=unknown ;; esac
  printf 'soter|status|installed=%s|services=%s|%s\n' "$_si" "$(_sf_services_line)" "$(_sf_last)"
}

_sf_record() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf 'time=%s\nresult=%s\n' "$(date +%s 2>/dev/null || echo 0)" "$1" > "$STATE/last.tmp" 2>/dev/null &&
    mv -f "$STATE/last.tmp" "$STATE/last" 2>/dev/null
  chmod 0600 "$STATE/last" 2>/dev/null
}

_sf_result() {
  printf 'soter|result|state=%s|cleared=%s|services=%s\n' "$1" "$2" "$(_sf_services_line)"
}

_sf_run() {
  mkdir -p "$STATE" 2>/dev/null || { _sf_result lock_error 0; return 0; }
  mkdir "$LOCK" 2>/dev/null || { _sf_result busy 0; return 0; }
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _sf_installed
  case $? in
    0) ;;
    1) _sf_record not_installed; _sf_result not_installed 0; return 0 ;;
    *) _sf_result unknown 0; return 0 ;;
  esac
  _svcs="$(_sf_services)"
  for _s in $_svcs; do stop "$_s" 2>/dev/null; done
  [ -n "$_svcs" ] && sleep 1
  _clr="$(pm clear "$PKG" 2>&1)"
  case "$_clr" in *Success*) _ok=1 ;; *) _ok=0 ;; esac
  for _s in $_svcs; do start "$_s" 2>/dev/null; done
  _down=''
  if [ -n "$_svcs" ]; then
    _i=0
    while [ "$_i" -lt "$WAIT_STEPS" ]; do
      _down=''
      for _s in $_svcs; do [ "$(_sf_state "$_s")" = running ] || _down=1; done
      [ -z "$_down" ] && break
      sleep 0.5 2>/dev/null || sleep 1
      _i=$((_i + 1))
    done
  fi
  if [ "$_ok" != 1 ]; then _st=clear_failed
  elif [ -n "$_down" ]; then _st=service_down
  elif [ -z "$_svcs" ]; then _st=done_no_service
  else _st=done
  fi
  _sf_record "$_st"
  _sf_result "$_st" "$_ok"
}

case "$MODE" in
  status) _sf_status ;;
  run) _sf_run ;;
  *) printf 'soter|error|unknown_command\n'; exit 2 ;;
esac
