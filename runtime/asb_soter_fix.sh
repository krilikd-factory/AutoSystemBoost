#!/system/bin/sh

PKG=com.tencent.soter.soterserver
STATE="${ASB_SOTER_STATE_DIR:-/data/adb/asb/soter_fix}"
PKGLIST="${ASB_SOTER_PACKAGES_LIST:-/data/system/packages.list}"
CE_ROOT="${ASB_SOTER_CE_ROOT:-/data/user/0}"
BOOT_ID_FILE="${ASB_SOTER_BOOT_ID:-/proc/sys/kernel/random/boot_id}"
UPTIME_FILE="${ASB_SOTER_UPTIME:-/proc/uptime}"
WAIT_STEPS="${ASB_SOTER_WAIT_STEPS:-30}"
READY_STEPS="${ASB_SOTER_READY_STEPS:-6}"
PASSES="${ASB_SOTER_PASSES:-2}"
UNLOCK_MAX="${ASB_SOTER_UNLOCK_MAX:-21600}"
UNLOCK_STEP="${ASB_SOTER_UNLOCK_STEP:-5}"
SETTLE="${ASB_SOTER_SETTLE:-90}"
RETRY_WAIT="${ASB_SOTER_RETRY_WAIT:-60}"
VERIFY_WAIT="${ASB_SOTER_VERIFY_WAIT:-120}"
LOG_KEEP="${ASB_SOTER_LOG_KEEP:-120}"
LOCK="$STATE/run.lock"
AUTO="$STATE/auto"
JOURNAL="$STATE/log"
BOOTREC="$STATE/boot"
NOTIFY="$STATE/notify"
MODE="${1:-status}"

_sf_now() { date +%s 2>/dev/null || echo 0; }

_sf_up() {
  _u="$(cut -d. -f1 "$UPTIME_FILE" 2>/dev/null)"
  case "$_u" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$_u" ;; esac
}

_sf_boot_id() {
  _b="$(tr -cd 'A-Za-z0-9-' < "$BOOT_ID_FILE" 2>/dev/null | cut -c1-40)"
  printf '%s' "${_b:-unknown}"
}

_sf_clean() { printf '%s' "$1" | tr '\r\n\t|' '    ' | tr -d '\000-\037\177' | cut -b1-"${2:-160}"; }

_sf_log() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s up=%ss %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now)" "$(_sf_up)" "$(_sf_clean "$*" 400)" >> "$JOURNAL" 2>/dev/null
  _ln="$(wc -l < "$JOURNAL" 2>/dev/null | tr -d ' ')"
  case "$_ln" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$_ln" -gt "$LOG_KEEP" ]; then
    tail -n "$LOG_KEEP" "$JOURNAL" > "$JOURNAL.tmp" 2>/dev/null && mv -f "$JOURNAL.tmp" "$JOURNAL" 2>/dev/null
  fi
  chmod 0600 "$JOURNAL" 2>/dev/null
  return 0
}

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

_sf_proc() {
  _p="$(pidof "$PKG" 2>/dev/null | tr -cd '0-9 ' | cut -c1-24)"
  printf '%s' "${_p:--}"
}

_sf_files() {
  [ -d "$CE_ROOT/$PKG" ] || { printf 'locked'; return 0; }
  _n="$(find "$CE_ROOT/$PKG" -type f 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' "${_n:-0}"
}

_sf_snapshot() { printf 'services=%s proc=%s files=%s' "$(_sf_services_line)" "$(_sf_proc)" "$(_sf_files)"; }

_sf_last() {
  _lt="$(sed -n 's/^time=\([0-9]*\)$/\1/p' "$STATE/last" 2>/dev/null | head -n 1)"
  _lr="$(sed -n 's/^result=\([a-z_]*\)$/\1/p' "$STATE/last" 2>/dev/null | head -n 1)"
  _lg="$(sed -n 's/^trigger=\([a-z_]*\)$/\1/p' "$STATE/last" 2>/dev/null | head -n 1)"
  printf 'last_time=%s|last_result=%s|last_trigger=%s' "${_lt:-0}" "${_lr:-none}" "${_lg:-manual}"
}

_sf_auto() { [ -f "$AUTO" ] && printf 1 || printf 0; }

_sf_brec_get() { sed -n "s/^$1=\([A-Za-z0-9_.-]*\)$/\1/p" "$BOOTREC" 2>/dev/null | head -n 1; }

_sf_brec() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  {
    printf 'boot_id=%s\n' "$(_sf_boot_id)"
    printf 'state=%s\n' "$1"
    printf 'result=%s\n' "${2:-none}"
    printf 'unlock_s=%s\n' "${_bw:-0}"
    printf 'via=%s\n' "${_bvia:-none}"
    printf 'time=%s\n' "$(_sf_now)"
    printf 'first=%s\n' "${_bfirst:-none}"
  } > "$BOOTREC.tmp" 2>/dev/null && mv -f "$BOOTREC.tmp" "$BOOTREC" 2>/dev/null
  chmod 0600 "$BOOTREC" 2>/dev/null
  return 0
}

_sf_boot_fields() {
  if [ "$(_sf_auto)" != 1 ]; then
    printf 'boot_state=off|boot_result=none|boot_unlock=0|boot_via=none|boot_time=0|boot_first=none'
    return 0
  fi
  if [ ! -f "$BOOTREC" ] || [ "$(_sf_brec_get boot_id)" != "$(_sf_boot_id)" ]; then
    printf 'boot_state=none|boot_result=none|boot_unlock=0|boot_via=none|boot_time=0|boot_first=none'
    return 0
  fi
  _bs="$(_sf_brec_get state)"; _br="$(_sf_brec_get result)"; _bu="$(_sf_brec_get unlock_s)"
  _bv="$(_sf_brec_get via)"; _bt="$(_sf_brec_get time)"; _bf="$(_sf_brec_get first)"
  printf 'boot_state=%s|boot_result=%s|boot_unlock=%s|boot_via=%s|boot_time=%s|boot_first=%s' \
    "${_bs:-none}" "${_br:-none}" "${_bu:-0}" "${_bv:-none}" "${_bt:-0}" "${_bf:-none}"
}

_sf_notify_lang() { sed -n 's/^lang=\([A-Za-z_-]*\)$/\1/p' "$NOTIFY" 2>/dev/null | head -n 1; }

_sf_status() {
  _sf_installed
  case $? in 0) _si=1 ;; 1) _si=0 ;; *) _si=unknown ;; esac
  _nl="$(_sf_notify_lang)"
  printf 'soter|status|installed=%s|services=%s|%s|auto=%s|%s|key_status=unverified|after_sale=required|notify_lang=%s\n' \
    "$_si" "$(_sf_services_line)" "$(_sf_last)" "$(_sf_auto)" "$(_sf_boot_fields)" "${_nl:-none}"
}

_sf_record() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf 'time=%s\nresult=%s\ntrigger=%s\npasses=%s\nboot_id=%s\nup=%s\nkey_status=unverified\nafter_sale=required\n' "$(_sf_now)" "$1" "${TRIGGER:-manual}" "${_pass:-0}" "$(_sf_boot_id)" "$(_sf_up)" > "$STATE/last.tmp" 2>/dev/null &&
    mv -f "$STATE/last.tmp" "$STATE/last" 2>/dev/null
  chmod 0600 "$STATE/last" 2>/dev/null
}

_sf_manual_this_boot() {
  [ -f "$STATE/last" ] || return 1
  [ "$(sed -n 's/^trigger=//p' "$STATE/last" 2>/dev/null | head -n 1)" = manual ] || return 1
  [ "$(sed -n 's/^boot_id=//p' "$STATE/last" 2>/dev/null | head -n 1)" = "$(_sf_boot_id)" ] || return 1
  case "$(sed -n 's/^result=//p' "$STATE/last" 2>/dev/null | head -n 1)" in done|done_no_service) return 0 ;; esac
  return 1
}

_sf_result() {
  printf 'soter|result|state=%s|cleared=%s|passes=%s|services=%s|key_status=unverified|after_sale=required\n' "$1" "$2" "${_pass:-0}" "$(_sf_services_line)"
}

_sf_wait() {
  _w=0
  while [ "$_w" -lt "$WAIT_STEPS" ]; do
    _miss=''
    for _s in $_svcs; do [ "$(_sf_state "$_s")" = "$1" ] || _miss=1; done
    [ -z "$_miss" ] && return 0
    sleep 0.5 2>/dev/null || sleep 1
    _w=$((_w + 1))
  done
  return 1
}

_sf_stable() {
  _stable=0
  while [ "$_stable" -lt "$READY_STEPS" ]; do
    sleep 0.5 2>/dev/null || sleep 1
    for _s in $_svcs; do [ "$(_sf_state "$_s")" = running ] || return 1; done
    _stable=$((_stable + 1))
  done
  return 0
}

_sf_pass() {
  am force-stop "$PKG" >/dev/null 2>&1
  for _s in $_svcs; do stop "$_s" 2>/dev/null; done
  [ -n "$_svcs" ] && _sf_wait stopped
  _clr="$(pm clear "$PKG" 2>&1)"
  case "$_clr" in *Success*) _ok=1 ;; *) _ok=0 ;; esac
  for _s in $_svcs; do start "$_s" 2>/dev/null; done
  _down=''
  if [ -n "$_svcs" ]; then
    if _sf_wait running; then _sf_stable || _down=1; else _down=1; fi
  fi
}

_sf_lock() {
  mkdir -p "$STATE" 2>/dev/null || return 2
  mkdir "$LOCK" 2>/dev/null && return 0
  _lm="$(stat -c %Y "$LOCK" 2>/dev/null)"
  case "$_lm" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(_sf_now) - _lm )) -gt 600 ] || return 1
  rmdir "$LOCK" 2>/dev/null || return 1
  _sf_log "lock older than 10 min removed"
  mkdir "$LOCK" 2>/dev/null && return 0
  return 1
}

_sf_run() {
  _sf_lock
  case $? in
    0) ;;
    2) _st=lock_error; _sf_result lock_error 0; return 0 ;;
    *) _st=busy; _sf_log "run trigger=${TRIGGER:-manual} result=busy"; _sf_result busy 0; return 0 ;;
  esac
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _t0="$(_sf_now)"
  _sf_installed
  case $? in
    0) ;;
    1) _st=not_installed; _pass=0; _sf_record not_installed; _sf_log "run trigger=${TRIGGER:-manual} result=not_installed"; rmdir "$LOCK" 2>/dev/null; _sf_result not_installed 0; return 0 ;;
    *) _st=unknown; _pass=0; _sf_log "run trigger=${TRIGGER:-manual} result=unknown"; rmdir "$LOCK" 2>/dev/null; _sf_result unknown 0; return 0 ;;
  esac
  _before="$(_sf_snapshot)"
  _svcs="$(_sf_services)"
  case "$PASSES" in 1|2|3) ;; *) PASSES=2 ;; esac
  case "$READY_STEPS" in 1|2|3|4|5|6|7|8|9|10|11|12) ;; *) READY_STEPS=6 ;; esac
  _pass=0; _ok=0; _down=''; _clr=''
  while [ "$_pass" -lt "$PASSES" ]; do
    [ "$_pass" -gt 0 ] && sleep 2
    _pass=$((_pass + 1))
    _sf_pass
    [ "$_ok" = 1 ] && [ -z "$_down" ] || break
  done
  if [ "$_ok" != 1 ]; then _st=clear_failed
  elif [ -n "$_down" ]; then _st=service_down
  elif [ -z "$_svcs" ]; then _st=done_no_service
  else _st=done
  fi
  _sf_record "$_st"
  _sf_log "run trigger=${TRIGGER:-manual} result=$_st passes=$_pass took=$(( $(_sf_now) - _t0 ))s clear=[$(_sf_clean "$(printf '%s' "$_clr" | head -n 1)" 60)] before=[$_before] after=[$(_sf_snapshot)]"
  rmdir "$LOCK" 2>/dev/null
  _sf_result "$_st" "$_ok"
}

_sf_unlocked() {
  if [ "$(getprop sys.user.0.ce_available 2>/dev/null)" = true ]; then _bvia=ce_available; return 0; fi
  if [ "$1" = 1 ] && am get-started-user-state 0 2>/dev/null | grep -q RUNNING_UNLOCKED; then _bvia=user_state; return 0; fi
  return 1
}

_sf_notify() {
  command -v cmd >/dev/null 2>&1 || return 0
  _nk="$1"
  _nt="$(sed -n 's/^title=//p' "$NOTIFY" 2>/dev/null | head -n 1)"
  _nb="$(sed -n "s/^$_nk=//p" "$NOTIFY" 2>/dev/null | head -n 1)"
  [ -n "$_nt" ] || _nt='SOTER'
  if [ -z "$_nb" ]; then
    case "$_nk" in
      done) _nb='The automatic SOTER reset and service restart completed, but the physical key is unverified. Check AfterSale, Key Status, SOTER key. Switch fingerprint payment on again in your payment apps.' ;;
      *) _nb='The automatic SOTER repair did not finish. Open ASB, Infirmary, SOTER Repair.' ;;
    esac
  fi
  _nb="$(_sf_clean "$_nb" 600)"; _nt="$(_sf_clean "$_nt" 120)"
  if cmd notification post -S bigtext -t "$_nt" asb_soter "$_nb" >/dev/null 2>&1; then
    _sf_log "boot: notification requested ($_nk)"
  else
    _sf_log "boot: notification command failed ($_nk)"
  fi
}

_sf_verify() {
  sleep "$VERIFY_WAIT"
  _vsvc=''
  for _s in $(_sf_services); do
    [ "$(_sf_state "$_s")" = running ] && continue
    start "$_s" 2>/dev/null
    _vsvc="${_vsvc:+$_vsvc,}$_s"
  done
  if [ -n "$_vsvc" ]; then
    _sf_log "boot: verify ${VERIFY_WAIT}s later restarted stopped service(s) $_vsvc; $(_sf_snapshot)"
  else
    _sf_log "boot: verify ${VERIFY_WAIT}s later $(_sf_snapshot)"
  fi
  command -v logcat >/dev/null 2>&1 || return 0
  logcat -d -t 3000 2>/dev/null | grep -i soter | tail -n 12 | while IFS= read -r _ll; do
    _sf_log "logcat: $(_sf_clean "$_ll" 200)"
  done
  return 0
}

_sf_boot() {
  if [ ! -f "$AUTO" ]; then
    _pass=0; _sf_result auto_off 0
    return 0
  fi
  _bw=0; _bvia=none; _bfirst=none
  _sf_brec waiting
  _sf_log "boot: waiting for boot_completed"
  _bc=0
  until [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ]; do
    sleep 5
    _bc=$((_bc + 5))
    [ "$_bc" -ge 3600 ] && { _sf_log "boot: boot_completed not seen in 3600s"; _sf_brec skipped no_boot; return 0; }
  done
  _sf_log "boot: boot_completed seen; waiting for the first unlock; $(_sf_snapshot)"
  case "$UNLOCK_STEP" in ''|*[!0-9]*|0) UNLOCK_STEP=5 ;; esac
  _bam=0
  while ! _sf_unlocked "$_bam"; do
    if [ "$_bw" -ge "$UNLOCK_MAX" ]; then
      _sf_log "boot: skipped, the phone was not unlocked within ${_bw}s of boot_completed"
      _sf_brec skipped no_unlock
      _pass=0; _sf_result no_unlock 0
      return 0
    fi
    sleep "$UNLOCK_STEP"
    _bw=$((_bw + UNLOCK_STEP))
    _bam=0
    [ $((_bw % 60)) -lt "$UNLOCK_STEP" ] && _bam=1
  done
  _sf_brec unlocked
  _sf_log "boot: unlocked ${_bw}s after boot_completed (via $_bvia); repair in ${SETTLE}s; $(_sf_snapshot)"
  sleep "$SETTLE"
  if ! _sf_unlocked 1; then
    _sf_brec skipped no_unlock
    _sf_log "boot: skipped because CE storage was no longer unlocked after the settle; no SOTER data was touched"
    _pass=0; _sf_result no_unlock 0
    return 0
  fi
  if [ ! -f "$AUTO" ]; then
    _sf_brec skipped auto_off
    _sf_log "boot: skipped because automatic repair was switched off during the settle"
    _pass=0; _sf_result auto_off 0
    return 0
  fi
  if _sf_manual_this_boot; then
    _sf_brec skipped recent_manual
    _sf_log "boot: skipped because a manual repair already completed in this boot"
    _pass=0; _sf_result skipped_recent_manual 0
    return 0
  fi
  TRIGGER=boot
  _sf_run
  case "$_st" in
    done|done_no_service|clear_failed|service_down)
      _bfirst="$_st"
      _sf_log "boot: first automatic pass $_st, second pass in ${RETRY_WAIT}s; key_status=unverified"
      sleep "$RETRY_WAIT"
      if [ ! -f "$AUTO" ]; then
        _sf_log "boot: second pass skipped because automatic repair was switched off"
      elif ! _sf_unlocked 1; then
        _sf_log "boot: second pass skipped because CE storage was locked again; no SOTER data was touched"
      elif _sf_manual_this_boot; then
        _sf_log "boot: second pass skipped because a manual repair completed during the wait"
      else
        TRIGGER=boot
        _sf_run
      fi
      ;;
  esac
  _sf_brec done "$_st"
  case "$_st" in
    done|done_no_service) _sf_notify done ;;
    not_installed) ;;
    *) _sf_notify failed ;;
  esac
  _sf_verify
  return 0
}

_sf_set_auto() {
  case "$1" in
    on) mkdir -p "$STATE" 2>/dev/null && printf '1\n' > "$AUTO" 2>/dev/null && _sf_log "auto repair switched on" ;;
    off) rm -f "$AUTO" 2>/dev/null; _sf_log "auto repair switched off" ;;
    *) printf 'soter|error|unknown_command\n'; exit 2 ;;
  esac
  printf 'soter|auto|state=%s\n' "$(_sf_auto)"
}

_sf_texts() {
  case "$1" in ''|*[!A-Za-z_-]*) printf 'soter|error|bad_lang\n'; exit 2 ;; esac
  mkdir -p "$STATE" 2>/dev/null || { printf 'soter|texts|state=0\n'; return 0; }
  {
    printf 'lang=%s\n' "$1"
    printf 'title=%s\n' "$(_sf_clean "$2" 120)"
    printf 'done=%s\n' "$(_sf_clean "$3" 600)"
    printf 'failed=%s\n' "$(_sf_clean "$4" 600)"
  } > "$NOTIFY.tmp" 2>/dev/null && mv -f "$NOTIFY.tmp" "$NOTIFY" 2>/dev/null
  chmod 0600 "$NOTIFY" 2>/dev/null
  printf 'soter|texts|state=%s\n' "$([ "$(_sf_notify_lang)" = "$1" ] && echo 1 || echo 0)"
}

_sf_show_log() {
  [ -s "$JOURNAL" ] || { printf 'soter|log|empty\n'; return 0; }
  tail -n "${1:-40}" "$JOURNAL" 2>/dev/null
}

case "$MODE" in
  status) _sf_status ;;
  run) TRIGGER=manual; _sf_run ;;
  boot) _sf_boot ;;
  auto) _sf_set_auto "${2:-}" ;;
  texts) _sf_texts "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
  log)
    case "${2:-40}" in ''|*[!0-9]*) _sf_show_log 40 ;; *) _sf_show_log "${2:-40}" ;; esac
    ;;
  *) printf 'soter|error|unknown_command\n'; exit 2 ;;
esac
