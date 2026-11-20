#!/system/bin/sh
set -u

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
STATE_DIR="${ASB_BFIX_STATE_DIR:-/data/adb/asb}"
PENDING="$STATE_DIR/battery_fix.pending"
LASTLOG="$STATE_DIR/battery_fix.last"
PROG="$STATE_DIR/battery_fix.compile"
LOCK="$STATE_DIR/battery_fix.lock"
STOPF="$STATE_DIR/battery_fix.stop"
SYSDIR="${ASB_BFIX_SYSDIR:-/data/system}"
BSTATS="batterystats.bin batterystats-checkin.bin batterystats-daily.xml"
SELF="${ASB_BFIX_SELF:-$0}"

_now() { date +%s 2>/dev/null || echo 0; }
_bootid() {
  if [ -n "${ASB_BFIX_BOOT_ID:-}" ]; then printf '%s' "$ASB_BFIX_BOOT_ID"; return; fi
  cat /proc/sys/kernel/random/boot_id 2>/dev/null
}
_kv() { [ -f "$2" ] && sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }
_bf_err=""
_upsec() { _u=""; read -r _u _ur < /proc/uptime 2>/dev/null; _u="${_u%%.*}"; case "$_u" in ''|*[!0-9]*) echo "${ASB_BFIX_UPTIME:-}" ;; *) echo "${ASB_BFIX_UPTIME:-$_u}" ;; esac; }
_bf_clean() { printf '%s' "$1" | tr '\r\n\t|=' '     ' | tr -s ' ' | sed 's/^ //; s/ $//' | cut -c1-120; }

_bf_level() {
  _l=""
  [ -r /sys/class/power_supply/battery/capacity ] && _l="$(cat /sys/class/power_supply/battery/capacity 2>/dev/null | tr -dc '0-9')"
  if [ -z "$_l" ] && command -v dumpsys >/dev/null 2>&1; then
    _l="$(dumpsys battery 2>/dev/null | sed -n 's/^[[:space:]]*level:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
  fi
  printf '%s' "${ASB_BFIX_FAKE_LEVEL:-$_l}"
}
_bf_plugged() {
  if [ -n "${ASB_BFIX_FAKE_PLUGGED:-}" ]; then
    [ "$ASB_BFIX_FAKE_PLUGGED" = 1 ]; return
  fi
  _st=""
  [ -r /sys/class/power_supply/battery/status ] && _st="$(cat /sys/class/power_supply/battery/status 2>/dev/null)"
  case "$_st" in
    Charging|Full) return 0 ;;
    Discharging|"Not charging") return 1 ;;
  esac
  if command -v dumpsys >/dev/null 2>&1; then
    dumpsys battery 2>/dev/null | grep -Eq '(AC|USB|Wireless) powered:[[:space:]]*true' && return 0
  fi
  return 1
}
_bf_eligible() {
  _lv="$(_bf_level)"
  case "$_lv" in ''|*[!0-9]*) echo 'eligible=0 reason=unknown_level level=-'; return 1 ;; esac
  if ! _bf_plugged; then echo "eligible=0 reason=not_charging level=$_lv"; return 1; fi
  if [ "$_lv" -lt 100 ] 2>/dev/null; then echo "eligible=0 reason=not_full level=$_lv"; return 1; fi
  echo "eligible=1 reason=- level=$_lv"
  return 0
}

_bf_packages() {
  if [ -n "${ASB_BFIX_FAKE_PKGS+x}" ]; then
    for _x in $ASB_BFIX_FAKE_PKGS; do printf '%s\n' "$_x"; done
    return
  fi
  { cmd package list packages 2>/dev/null || pm list packages 2>/dev/null; } | sed -n 's/^package://p' | tr -d '\r' | sort -u
}
_bf_compile_one() {
  _bf_binder=0
  if [ -n "${ASB_BFIX_COMPILE_CMD:-}" ]; then
    _o="$($ASB_BFIX_COMPILE_CMD "$1" 2>&1)"
  else
    _o="$(cmd package compile -m speed-profile -f "$1" 2>&1)"
    _all="$_o"
    case "$_o" in
      *Success*) ;;
      *)
        if command -v pm >/dev/null 2>&1; then
          _po="$(pm compile -m speed-profile -f "$1" 2>&1)"
          _all="$(printf '%s\n%s\n' "$_all" "$_po")"
          case "$_po" in *Success*) _o="$_po" ;; esac
        fi ;;
    esac
    case "$_o" in
      *Success*) ;;
      *)
        _co="$(cmd package compile -m speed-profile "$1" 2>&1)"
        _all="$(printf '%s\n%s\n' "$_all" "$_co")"
        case "$_co" in *Success*) _o="$_co" ;; *)
          if command -v pm >/dev/null 2>&1; then
            _po="$(pm compile -m speed-profile "$1" 2>&1)"
            _all="$(printf '%s\n%s\n' "$_all" "$_po")"
            case "$_po" in *Success*) _o="$_po" ;; esac
          fi ;;
        esac ;;
    esac
    case "$_all" in *Success*) return 0 ;; esac
    _o="$(printf '%s\n' "$_all" | grep -m1 .)"
  fi
  case "$_o${_all:-}" in *Failed\ transaction*) _bf_binder=1 ;; esac
  case "$_o" in *Success*) return 0 ;; esac
  [ -n "$_bf_err" ] || _bf_err="$(_bf_clean "$(printf '%s\n' "${_all:-$_o}" | grep -m1 . )")"
  [ -n "$_bf_err" ] || _bf_err=no_output
  return 1
}
_bf_schedule_bgjob() {
  [ "${ASB_BFIX_NO_BGJOB:-0}" != 1 ] || return 1
  if command -v cmd >/dev/null 2>&1; then
    _bgo="$(cmd package bg-dexopt-job 2>&1)"; _bgrc=$?
    if [ "$_bgrc" -eq 0 ]; then
      case "$_bgo" in *[Ff]ail*|*[Ee]rror*|*Exception*|*'not found'*) ;; *) return 0 ;; esac
    fi
  fi
  if command -v pm >/dev/null 2>&1; then
    _bgo="$(pm bg-dexopt-job 2>&1)"; _bgrc=$?
    if [ "$_bgrc" -eq 0 ]; then
      case "$_bgo" in *[Ff]ail*|*[Ee]rror*|*Exception*|*'not found'*) ;; *) return 0 ;; esac
    fi
  fi
  return 1
}
_prog_write() {
  _t="$PROG.tmp.$$"
  {
    printf 'state=%s\n' "$1"
    printf 'phase=%s\n' "$2"
    printf 'total=%s\n' "$3"
    printf 'done=%s\n' "$4"
    printf 'ok=%s\n' "$5"
    printf 'fail=%s\n' "$6"
    printf 'cur=%s\n' "$7"
    printf 'started=%s\n' "$8"
    printf 'finished=%s\n' "$9"
    printf 'pid=%s\n' "$$"
    printf 'boot=%s\n' "$(_bootid)"
    printf 'err=%s\n' "${_bf_err:--}"
  } > "$_t" 2>/dev/null && mv -f "$_t" "$PROG" 2>/dev/null
}
_bf_worker_cleanup() {
  [ -n "${_pk:-}" ] && rm -f "$_pk" 2>/dev/null
  [ -n "${_t:-}" ] && rm -f "$_t" 2>/dev/null
  rmdir "$LOCK" 2>/dev/null
}
_bf_worker() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || exit 0
  _pk=""; _t=""
  trap '_bf_worker_cleanup' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  rm -f "$STOPF" 2>/dev/null
  _pk="$STATE_DIR/battery_fix.pkgs.$$"
  _bf_packages > "$_pk" 2>/dev/null
  _total="$(grep -c . "$_pk" 2>/dev/null)"
  case "$_total" in ''|*[!0-9]*) _total=0 ;; esac
  _st="$(_now)"
  if [ "$_total" -eq 0 ]; then
    rm -f "$_pk" 2>/dev/null
    _prog_write failed no_packages 0 0 0 0 - "$_st" "$(_now)"
    exit 0
  fi
  _d=0; _ok=0; _f=0; _binder_streak=0; _state=done
  _prog_write running compile "$_total" 0 0 0 - "$_st" -
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    if [ -f "$STOPF" ]; then _state=stopped; break; fi
    _prog_write running compile "$_total" "$_d" "$_ok" "$_f" "$_p" "$_st" -
    if _bf_compile_one "$_p"; then
      _ok=$((_ok + 1)); _d=$((_d + 1)); _binder_streak=0
    else
      _f=$((_f + 1)); _d=$((_d + 1))
      if [ "${_bf_binder:-0}" = 1 ]; then _binder_streak=$((_binder_streak + 1)); else _binder_streak=0; fi
    fi
    if [ "${_bf_binder:-0}" = 1 ] && [ "$_binder_streak" -ge "${ASB_BFIX_BINDER_REFUSE_AFTER:-3}" ]; then
      if [ "$_ok" -eq 0 ]; then
        if _bf_schedule_bgjob; then _state=scheduled; else _state=refused; fi
      else
        _state=partial
      fi
      break
    fi
    if [ "$_ok" -eq 0 ] && [ "$_f" -ge "${ASB_BFIX_REFUSE_AFTER:-12}" ]; then _state=refused; break; fi
  done < "$_pk"
  rm -f "$_pk" "$STOPF" 2>/dev/null
  [ "$_state" = done ] && [ "$_ok" -eq 0 ] && [ "$_f" -gt 0 ] && _state=refused
  if [ "$_state" = done ] || [ "$_state" = partial ]; then
    _prog_write running finishing "$_total" "$_d" "$_ok" "$_f" - "$_st" -
    if [ "${ASB_BFIX_NO_BGJOB:-0}" != 1 ] && command -v cmd >/dev/null 2>&1; then
      cmd package bg-dexopt-job >/dev/null 2>&1
    fi
  fi
  _prog_write "$_state" "$_state" "$_total" "$_d" "$_ok" "$_f" - "$_st" "$(_now)"
}
_bf_compile_state() {
  [ -f "$PROG" ] || { echo idle; return; }
  _s="$(_kv state "$PROG")"
  if [ "$_s" = running ]; then
    _b="$(_kv boot "$PROG")"
    _pid="$(_kv pid "$PROG")"
    if [ -n "$_b" ] && [ "$_b" != "$(_bootid)" ]; then echo interrupted; return; fi
    [ -d "$LOCK" ] || { echo interrupted; return; }
    if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then echo interrupted; return; fi
  fi
  echo "${_s:-idle}"
}
_bf_mtime() { stat -c %Y "$1" 2>/dev/null || date -r "$1" +%s 2>/dev/null; }
_bf_settle() {
  [ -f "$LASTLOG" ] || return 0
  [ "$(_kv done_boot "$LASTLOG")" = "$(_bootid)" ] || return 0
  _su="$(_kv done_up "$LASTLOG")"; _sn="$(_now)"; _sc="$(_upsec)"
  case "$_su$_sn$_sc" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_sc" -ge "$_su" ] || return 0
  _sv=$((_sn - _sc + _su))
  _sr="$(_kv armed_at "$LASTLOG")"
  case "$_sr" in ''|*[!0-9]*) _sr=0 ;; esac
  [ "$_sv" -ge "$_sr" ] || return 0
  _sa="$(_kv done_at "$LASTLOG")"
  case "$_sa" in
    ''|*[!0-9]*) ;;
    *)
      _sd=$((_sa - _sv)); [ "$_sd" -lt 0 ] && _sd=$((-_sd))
      [ "$_sd" -le 120 ] && return 0 ;;
  esac
  _t="$LASTLOG.tmp.$$"
  { printf 'done_at=%s\n' "$_sv"; grep -v '^done_at=' "$LASTLOG"; } > "$_t" 2>/dev/null && mv -f "$_t" "$LASTLOG" 2>/dev/null
  rm -f "$_t" 2>/dev/null
}

case "${1:-status}" in
  eligible)
    _bf_eligible
    ;;
  run)
    if ! _bf_eligible >/dev/null 2>&1; then
      _e="$(_bf_eligible)"
      echo "result=refused ${_e#eligible=0 }"
      exit 1
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf 'armed_at=%s\nlevel=%s\n' "$(_now)" "$(_bf_level)" > "$PENDING" 2>/dev/null
    if [ "${ASB_BFIX_NO_DEXOPT:-0}" = 1 ]; then
      _c=skipped
    elif [ "$(_bf_compile_state)" = running ]; then
      _c=busy
    else
      rm -f "$PROG" 2>/dev/null
      _c=started
      if [ "${ASB_BFIX_SYNC:-0}" = 1 ]; then
        ( _bf_worker )
      else
        MODDIR="$MODDIR" sh "$SELF" worker </dev/null >/dev/null 2>&1 &
      fi
    fi
    echo "result=armed reset_on=reboot compile=$_c"
    ;;
  worker)
    _bf_worker
    ;;
  stop)
    if [ "$(_bf_compile_state)" = running ]; then
      touch "$STOPF" 2>/dev/null
      echo 'result=stopping'
    else
      echo 'result=idle'
    fi
    ;;
  boot)
    [ -f "$PENDING" ] || exit 0
    _removed=""; _missing=""; _absent=""
    for _b in $BSTATS; do
      if [ ! -e "$SYSDIR/$_b" ]; then
        _absent="${_absent:+$_absent,}$_b"
      elif rm -f "$SYSDIR/$_b" 2>/dev/null && [ ! -e "$SYSDIR/$_b" ]; then
        _removed="${_removed:+$_removed,}$_b"
      else
        _missing="${_missing:+$_missing,}$_b"
      fi
    done
    _ba="$(_kv armed_at "$PENDING")"; _bn="$(_now)"
    case "$_ba" in ''|*[!0-9]*) _ba=0 ;; esac
    case "$_bn" in ''|*[!0-9]*) _bn=0 ;; esac
    [ "$_bn" -ge "$_ba" ] && [ "$_bn" -gt 0 ] || _bn=""
    printf 'done_at=%s\ndone_up=%s\ndone_boot=%s\narmed_at=%s\nremoved=%s\nmissing=%s\nabsent=%s\n' "$_bn" "$(_upsec)" "$(_bootid)" "$_ba" "${_removed:--}" "${_missing:--}" "${_absent:--}" > "$LASTLOG" 2>/dev/null
    rm -f "$PENDING" 2>/dev/null
    ;;
  settle)
    _bf_settle
    ;;
  cancel)
    if [ -f "$PENDING" ]; then rm -f "$PENDING" 2>/dev/null; echo 'result=cancelled'; else echo 'result=none'; fi
    ;;
  status)
    _bf_settle
    _e="$(_bf_eligible)"
    _plug=0; _bf_plugged && _plug=1
    if [ -f "$PENDING" ]; then _p=pending; else _p=none; fi
    _cs="$(_bf_compile_state)"
    _la="$(_kv done_at "$LASTLOG")"
    [ -z "$_la" ] && [ -f "$LASTLOG" ] && _la=boot
    _fresh=-
    if [ -n "$_la" ] && [ "$_la" != boot ]; then
      _fresh=0
      _mt="$(_bf_mtime "$SYSDIR/batterystats.bin")"
      case "$_mt" in ''|*[!0-9]*) : ;; *) [ "$_mt" -ge "$_la" ] && _fresh=1 ;; esac
    fi
    _ce="$(_kv err "$PROG" || true)"
    _ce="$(printf '%s' "${_ce:--}" | tr -cd 'A-Za-z0-9 _.:,()/\047-' | cut -c1-120)"
    printf '%s charging=%s reset=%s compile=%s phase=%s total=%s done=%s ok=%s fail=%s cur=%s started=%s finished=%s now=%s last_reset=%s removed=%s missing=%s fresh=%s absent=%s\n' \
      "$_e" "$_plug" "$_p" "$_cs" \
      "$(_kv phase "$PROG" || true)" "$(_kv total "$PROG" || true)" "$(_kv done "$PROG" || true)" \
      "$(_kv ok "$PROG" || true)" "$(_kv fail "$PROG" || true)" "$(_kv cur "$PROG" || true)" \
      "$(_kv started "$PROG" || true)" "$(_kv finished "$PROG" || true)" "$(_now)" \
      "${_la:--}" "$(_kv removed "$LASTLOG" || true)" "$(_kv missing "$LASTLOG" || true)" "$_fresh" \
      "$(_kv absent "$LASTLOG" || true)"
    case "$_ce" in ''|-) ;; *) printf 'err_text=%s\n' "$_ce" ;; esac
    ;;
  *)
    echo 'usage: eligible|run|worker|stop|boot|settle|cancel|status' >&2
    exit 2
    ;;
esac
