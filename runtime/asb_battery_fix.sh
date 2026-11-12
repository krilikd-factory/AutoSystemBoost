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
  if [ -n "${ASB_BFIX_COMPILE_CMD:-}" ]; then
    _o="$($ASB_BFIX_COMPILE_CMD "$1" 2>&1)"
  else
    _o="$(cmd package compile -m speed-profile -f "$1" 2>&1)"
  fi
  case "$_o" in *Success*) return 0 ;; esac
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
  } > "$_t" 2>/dev/null && mv -f "$_t" "$PROG" 2>/dev/null
}
_bf_worker_cleanup() {
  # A killed worker must not leave a package list or a half-published progress file.
  # Keep the last complete progress record: status will honestly report it as interrupted.
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
  _d=0; _ok=0; _f=0; _state=done
  _prog_write running compile "$_total" 0 0 0 - "$_st" -
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    if [ -f "$STOPF" ]; then _state=stopped; break; fi
    _prog_write running compile "$_total" "$_d" "$_ok" "$_f" "$_p" "$_st" -
    if _bf_compile_one "$_p"; then _ok=$((_ok + 1)); else _f=$((_f + 1)); fi
    _d=$((_d + 1))
  done < "$_pk"
  rm -f "$_pk" "$STOPF" 2>/dev/null
  if [ "$_state" = done ]; then
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
    # The record is published only after the lock exists. A missing lock therefore means
    # that the worker exited; it also avoids treating a reused PID as the old worker.
    [ -d "$LOCK" ] || { echo interrupted; return; }
    if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then echo interrupted; return; fi
  fi
  echo "${_s:-idle}"
}
_bf_mtime() { stat -c %Y "$1" 2>/dev/null || date -r "$1" +%s 2>/dev/null; }

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
    _removed=""; _missing=""
    for _b in $BSTATS; do
      if [ -e "$SYSDIR/$_b" ] && rm -f "$SYSDIR/$_b" 2>/dev/null && [ ! -e "$SYSDIR/$_b" ]; then
        _removed="${_removed:+$_removed,}$_b"
      else
        _missing="${_missing:+$_missing,}$_b"
      fi
    done
    printf 'done_at=%s\nremoved=%s\nmissing=%s\n' "$(_now)" "${_removed:--}" "${_missing:--}" > "$LASTLOG" 2>/dev/null
    rm -f "$PENDING" 2>/dev/null
    ;;
  cancel)
    if [ -f "$PENDING" ]; then rm -f "$PENDING" 2>/dev/null; echo 'result=cancelled'; else echo 'result=none'; fi
    ;;
  status)
    _e="$(_bf_eligible)"
    _plug=0; _bf_plugged && _plug=1
    if [ -f "$PENDING" ]; then _p=pending; else _p=none; fi
    _cs="$(_bf_compile_state)"
    _la="$(_kv done_at "$LASTLOG")"
    _fresh=-
    if [ -n "$_la" ]; then
      _fresh=0
      _mt="$(_bf_mtime "$SYSDIR/batterystats.bin")"
      case "$_mt" in ''|*[!0-9]*) : ;; *) [ "$_mt" -ge "$_la" ] && _fresh=1 ;; esac
    fi
    printf '%s charging=%s reset=%s compile=%s phase=%s total=%s done=%s ok=%s fail=%s cur=%s started=%s finished=%s now=%s last_reset=%s removed=%s missing=%s fresh=%s\n' \
      "$_e" "$_plug" "$_p" "$_cs" \
      "$(_kv phase "$PROG" || true)" "$(_kv total "$PROG" || true)" "$(_kv done "$PROG" || true)" \
      "$(_kv ok "$PROG" || true)" "$(_kv fail "$PROG" || true)" "$(_kv cur "$PROG" || true)" \
      "$(_kv started "$PROG" || true)" "$(_kv finished "$PROG" || true)" "$(_now)" \
      "${_la:--}" "$(_kv removed "$LASTLOG" || true)" "$(_kv missing "$LASTLOG" || true)" "$_fresh"
    ;;
  *)
    echo 'usage: eligible|run|worker|stop|boot|cancel|status' >&2
    exit 2
    ;;
esac
