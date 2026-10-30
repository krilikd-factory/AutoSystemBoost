#!/system/bin/sh
# One-shot ART profile compilation requested by the HeyTap MCS card.
# The service already runs as root, so `pm compile ...` here is the direct equivalent of
# su -c 'pm compile ...' without another shell or a persistent polling worker.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="${ASB_CONF:-$MODDIR/config/governor.conf}"
STATE="${ASB_ART_COMPILE_STATE:-/data/adb/asb/heytap_art_compile.conf}"
LOCK="${ASB_ART_COMPILE_LOCK:-/data/adb/asb/heytap_art_compile.lock}"
TIMEOUT_S="${ASB_ART_COMPILE_TIMEOUT:-1800}"
DELAY_S="${ASB_ART_COMPILE_DELAY:-10}"
PKG="com.heytap.mcs"

[ -f "$MODDIR/runtime/asb_package_state.sh" ] && . "$MODDIR/runtime/asb_package_state.sh"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | tail -1 | sed 's/^[^=]*=//; s/#.*//' | tr -d ' \r'
}
_now() { date +%s 2>/dev/null || echo 0; }
_state_value() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -1; }
_write_state() {
  mkdir -p "${STATE%/*}" 2>/dev/null || return 1
  _ws_tmp="$STATE.tmp.$$"
  printf '%s\n' "$@" > "$_ws_tmp" 2>/dev/null || { rm -f "$_ws_tmp"; return 1; }
  mv -f "$_ws_tmp" "$STATE" 2>/dev/null || { rm -f "$_ws_tmp"; return 1; }
}
_unlock() { rm -rf "$LOCK" 2>/dev/null; }
_enabled() { [ "$(_cfg heytap_mcs)" = off ]; }

_request() {
  _enabled || { echo 'result=disabled'; return 0; }
  # Re-applying the same Off value is idempotent. In particular, never turn a running or
  # completed one-shot back into pending; Stock first cancels the old request, so a deliberate
  # Stock -> Off cycle still creates a fresh one.
  _existing="$(_state_value state)"
  case "$_existing" in
    pending|running|done|failed) echo "result=$_existing"; return 0 ;;
  esac
  _write_state 'state=pending' "requested_at=$(_now)" || {
    echo 'result=state_write_failed'; return 1;
  }
  echo 'result=pending'
}

_cancel() {
  if [ "$(_state_value state)" = running ]; then
    # A compile already inside PackageManager is not killed halfway. The next config check
    # still prevents a delayed worker that has not entered pm yet.
    echo 'result=running_not_cancelled'
    return 0
  fi
  rm -f "$STATE" 2>/dev/null
  echo 'result=cancelled'
}

_status() {
  if [ -f "$STATE" ]; then
    cat "$STATE" 2>/dev/null
  else
    echo 'state=idle'
  fi
}

_run_pending() {
  [ "$(_state_value state)" = pending ] || { echo 'result=not_pending'; return 0; }
  _enabled || { rm -f "$STATE" 2>/dev/null; echo 'result=cancelled'; return 0; }
  command -v pm >/dev/null 2>&1 || {
    _write_state 'state=failed' 'reason=pm_unavailable'
    echo 'result=failed reason=pm_unavailable'; return 0;
  }

  if ! mkdir "$LOCK" 2>/dev/null; then
    _old_pid="$(cat "$LOCK/pid" 2>/dev/null)"
    case "$_old_pid" in
      ''|*[!0-9]*) : ;;
      *) kill -0 "$_old_pid" 2>/dev/null && { echo 'result=already_running'; return 0; } ;;
    esac
    _unlock
    mkdir "$LOCK" 2>/dev/null || { echo 'result=lock_busy'; return 0; }
  fi
  echo $$ > "$LOCK/pid" 2>/dev/null
  _write_state 'state=running' "pid=$$" "started_at=$(_now)" || {
    _unlock; echo 'result=state_write_failed'; return 1;
  }

  _wait=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ] && [ "$_wait" -lt 180 ]; do
    sleep 1
    _wait=$((_wait + 1))
  done
  if [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ]; then
    _write_state 'state=failed' 'reason=boot_timeout'
    _unlock; echo 'result=failed reason=boot_timeout'; return 0
  fi
  case "$DELAY_S" in ''|*[!0-9]*) DELAY_S=10 ;; esac
  [ "$DELAY_S" -eq 0 ] || sleep "$DELAY_S"

  if ! _enabled; then
    _write_state 'state=cancelled' 'reason=disabled_before_compile'
    _unlock; echo 'result=cancelled'; return 0
  fi
  if ! asb_pkg_present "$PKG"; then
    _write_state 'state=failed' 'reason=mcs_absent'
    _unlock; echo 'result=failed reason=mcs_absent'; return 0
  fi
  _dump="$LOCK/package.dump"
  dumpsys package "$PKG" > "$_dump" 2>/dev/null || :
  _mcs_state="$(asb_pkg_enabled "$_dump" 2>/dev/null)"
  rm -f "$_dump" 2>/dev/null
  case "$_mcs_state" in
    2|3) : ;;
    ''|*[!0-9]*)
      _write_state 'state=failed' 'reason=mcs_state_unknown'
      _unlock; echo 'result=failed reason=mcs_state_unknown'; return 0 ;;
    *)
      _write_state 'state=failed' 'reason=mcs_not_disabled'
      _unlock; echo 'result=failed reason=mcs_not_disabled'; return 0 ;;
  esac
  command -v timeout >/dev/null 2>&1 || {
    _write_state 'state=failed' 'reason=timeout_unavailable'
    _unlock; echo 'result=failed reason=timeout_unavailable'; return 0;
  }
  case "$TIMEOUT_S" in ''|*[!0-9]*|0) TIMEOUT_S=1800 ;; esac

  _start="$(_now)"
  timeout "$TIMEOUT_S" pm compile -m speed-profile -a >/dev/null 2>&1
  _rc=$?
  _end="$(_now)"
  case "$_start$_end" in
    ''|*[!0-9]*) _duration=unknown ;;
    *) _duration=$((_end - _start)) ;;
  esac
  if [ "$_rc" -eq 0 ]; then
    _write_state 'state=done' "exit_code=$_rc" "duration_s=$_duration" "finished_at=$_end"
    _unlock
    echo "result=done exit_code=$_rc duration_s=$_duration"
  else
    _reason=pm_compile_failed
    [ "$_rc" -eq 124 ] && _reason=timeout
    # No automatic retry: a failed all-package compile must not become a boot loop of work.
    _write_state 'state=failed' "reason=$_reason" "exit_code=$_rc" "duration_s=$_duration" "finished_at=$_end"
    _unlock
    echo "result=failed reason=$_reason exit_code=$_rc duration_s=$_duration"
  fi
}

case "${1:-status}" in
  request) _request ;;
  cancel) _cancel ;;
  status) _status ;;
  run-pending) _run_pending ;;
  *) echo 'usage: asb_art_compile.sh request|cancel|status|run-pending' >&2; exit 2 ;;
esac
exit 0
