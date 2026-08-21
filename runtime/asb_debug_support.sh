#!/system/bin/sh
# Debug-only WebUI support actions. This helper accepts no user-supplied shell text:
# it either writes one asbdiag report or starts one bounded 24-hour full-day capture.
set -u

MODID="AutoSystemBoost"
resolve_moddir() {
  for d in \
    "/data/adb/modules/$MODID" \
    "/data/adb/modules_update/$MODID" \
    "/data/adb/ksu/modules/$MODID" \
    "/data/adb/ksu/modules_update/$MODID" \
    "/data/adb/ap/modules/$MODID"; do
    [ -f "$d/module.prop" ] || continue
    grep -qx "id=$MODID" "$d/module.prop" 2>/dev/null && { printf '%s' "$d"; return 0; }
  done
  return 1
}

MODDIR="${ASB_DEBUG_SUPPORT_MODDIR:-$(resolve_moddir 2>/dev/null || true)}"
[ -n "$MODDIR" ] || { echo 'error=module_not_found'; exit 2; }
VERSION="$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)"
_debug_seq="${VERSION##*-debug}"
case "$VERSION:$_debug_seq" in
  *-debug[1-9]*:[1-9]* )
    case "$_debug_seq" in *[!0-9]*) echo 'error=debug_only'; exit 3 ;; esac ;;
  *) echo 'error=debug_only'; exit 3 ;;
esac

STATE_DIR="${ASB_DEBUG_SUPPORT_STATE_DIR:-/data/adb/asb/logkit}"
# A directory is an atomic lock on Android filesystems. Unlike a PID file, it cannot be
# observed as a simultaneously absent/empty guard, and it carries the recorder's own PID.
LOCKDIR="$STATE_DIR/full_day_webui.lock"
PIDFILE="$LOCKDIR/pid"
LAUNCHERFILE="$LOCKDIR/launcher"
TOKENFILE="$LOCKDIR/token"
# Kept only to avoid starting a second recorder when the module is upgraded while a capture
# started by the pre-lock-directory helper is still alive. New starts never create this file.
LEGACY_PIDFILE="$STATE_DIR/full_day_webui.pid"
RUNLOG="${ASB_DEBUG_SUPPORT_RUNLOG:-/data/local/tmp/asb_full_day.out}"
DIAG_OUTDIR="${ASB_DEBUG_SUPPORT_DIAG_OUTDIR:-/sdcard/Download}"

pid_from_file() {
  _pf="${1:-}"
  [ -r "$_pf" ] || return 1
  _pf_pid="$(tr -dc '0-9' < "$_pf" 2>/dev/null)"
  [ -n "$_pf_pid" ] || return 1
  printf '%s' "$_pf_pid"
}

pid_is_live() {
  _pl_pid="${1:-}"
  [ -n "$_pl_pid" ] || return 1
  kill -0 "$_pl_pid" 2>/dev/null
}

lock_live_pid() {
  # The launcher PID covers the tiny interval before the recorder publishes its own PID.
  # Once published, both usually name the same `sh asb_log_full_day.sh` process.
  for _lp_file in "$PIDFILE" "$LAUNCHERFILE"; do
    _lp_pid="$(pid_from_file "$_lp_file" 2>/dev/null || true)"
    if [ -n "$_lp_pid" ] && pid_is_live "$_lp_pid"; then
      printf '%s' "$_lp_pid"
      return 0
    fi
  done
  return 1
}

legacy_live_pid() {
  _legacy_pid="$(pid_from_file "$LEGACY_PIDFILE" 2>/dev/null || true)"
  if [ -n "$_legacy_pid" ] && pid_is_live "$_legacy_pid"; then
    printf '%s' "$_legacy_pid"
    return 0
  fi
  return 1
}

lock_wait_live_pid() {
  # A concurrent request can arrive after mkdir but before the winner publishes launcher/pid.
  # Give that bounded handoff three 100ms attempts; never remove the directory on timeout.
  _lwp_try=0
  while [ "$_lwp_try" -lt 3 ]; do
    _lwp_pid="$(lock_live_pid 2>/dev/null || true)"
    if [ -n "$_lwp_pid" ]; then
      printf '%s' "$_lwp_pid"
      return 0
    fi
    sleep 0.1
    _lwp_try=$(( _lwp_try + 1 ))
  done
  return 1
}

lock_known_dead() {
  # A lock can be released only after both recorded process identities are known to be dead.
  # A missing PID is deliberately NOT considered stale: fail closed rather than risk a second
  # recorder during startup or after an interrupted launch.
  [ -d "$LOCKDIR" ] || return 1
  _lk_seen=0
  for _lk_file in "$PIDFILE" "$LAUNCHERFILE"; do
    _lk_pid="$(pid_from_file "$_lk_file" 2>/dev/null || true)"
    [ -n "$_lk_pid" ] || continue
    _lk_seen=1
    pid_is_live "$_lk_pid" && return 1
  done
  [ "$_lk_seen" = 1 ] || return 1
  return 0
}

full_day_status() {
  _pid="$(lock_live_pid 2>/dev/null || true)"
  if [ -n "$_pid" ]; then
    echo "status=running"
    echo "pid=$_pid"
    echo "log=$RUNLOG"
    return 0
  fi
  _pid="$(legacy_live_pid 2>/dev/null || true)"
  if [ -n "$_pid" ]; then
    echo "status=running"
    echo "pid=$_pid"
    echo "log=$RUNLOG"
    return 0
  fi
  if [ -d "$LOCKDIR" ]; then
    if lock_known_dead; then
      rm -rf "$LOCKDIR" 2>/dev/null || true
      echo 'status=idle'
    else
      # Winner has the atomic directory but has not published a PID yet. Do not remove it
      # and do not start a competing capture; the next status call will show the PID.
      echo 'status=starting'
      echo 'pid=starting'
      echo "log=$RUNLOG"
    fi
    return 0
  fi
  # Safe cleanup of a legacy PID file only after its recorded process is known dead.
  if [ -f "$LEGACY_PIDFILE" ]; then
    _legacy_raw="$(pid_from_file "$LEGACY_PIDFILE" 2>/dev/null || true)"
    if [ -n "$_legacy_raw" ] && ! pid_is_live "$_legacy_raw"; then
      rm -f "$LEGACY_PIDFILE" 2>/dev/null || true
    fi
  fi
  echo 'status=idle'
}

write_diag() {
  _outdir="$DIAG_OUTDIR"
  [ -d "$_outdir" ] || _outdir="/sdcard"
  _stamp="$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo now)"
  _out="$_outdir/asbdiag_${_stamp}.txt"
  _tmp="${_out}.tmp.$$"
  if [ ! -x "$MODDIR/system/bin/asbdiag" ]; then
    echo 'error=asbdiag_missing'
    return 4
  fi
  "$MODDIR/system/bin/asbdiag" > "$_tmp" 2>&1
  _rc=$?
  mv -f "$_tmp" "$_out" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null || true; echo 'error=diag_write_failed'; return 5; }
  echo "status=saved"
  echo "path=$_out"
  echo "exit=$_rc"
  return 0
}

start_full_day() {
  [ -f "$MODDIR/tools/logkit/asb_log_full_day.sh" ] || { echo 'error=logkit_missing'; return 6; }
  mkdir -p "$STATE_DIR" 2>/dev/null || { echo 'error=state_dir_failed'; return 7; }

  _pid="$(lock_live_pid 2>/dev/null || true)"
  if [ -n "$_pid" ]; then
    echo "status=already_running"
    echo "pid=$_pid"
    echo "log=$RUNLOG"
    return 0
  fi
  _pid="$(legacy_live_pid 2>/dev/null || true)"
  if [ -n "$_pid" ]; then
    echo "status=already_running"
    echo "pid=$_pid"
    echo "log=$RUNLOG"
    return 0
  fi
  if [ -d "$LOCKDIR" ]; then
    if lock_known_dead; then
      rm -rf "$LOCKDIR" 2>/dev/null || true
    else
      _pid="$(lock_wait_live_pid 2>/dev/null || true)"
      # A lock without a ready PID is still owned by another request. Returning a benign
      # already-running state is safer than guessing and creating a parallel recorder.
      echo 'status=already_running'
      echo "pid=${_pid:-starting}"
      echo "log=$RUNLOG"
      return 0
    fi
  fi
  if [ -f "$LEGACY_PIDFILE" ]; then
    _legacy_raw="$(pid_from_file "$LEGACY_PIDFILE" 2>/dev/null || true)"
    if [ -n "$_legacy_raw" ] && ! pid_is_live "$_legacy_raw"; then
      rm -f "$LEGACY_PIDFILE" 2>/dev/null || true
    fi
  fi

  # mkdir is atomic. Metadata failures here occur before any child exists, so removing this
  # just-created directory is safe; from the nohup line onward only the recorder/dead-PID
  # verifier may release the guard.
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    _pid="$(lock_wait_live_pid 2>/dev/null || true)"
    echo 'status=already_running'
    echo "pid=${_pid:-starting}"
    echo "log=$RUNLOG"
    return 0
  fi
  _token="$(date +%s 2>/dev/null || echo now).$$"
  if ! printf '%s\n' "$_token" > "$TOKENFILE" 2>/dev/null; then
    rmdir "$LOCKDIR" 2>/dev/null || true
    echo 'error=pid_guard_failed'
    return 8
  fi

  # The recorder receives the lock token and publishes its own PID before it begins capture.
  # The launcher PID is written immediately after fork to cover the publish interval.
  ASB_DEBUG_SUPPORT_LOCKDIR="$LOCKDIR" ASB_DEBUG_SUPPORT_LOCK_TOKEN="$_token" \
    nohup sh "$MODDIR/tools/logkit/asb_log_full_day.sh" 24 > "$RUNLOG" 2>&1 < /dev/null &
  _pid=$!
  if ! printf '%s\n' "$_pid" > "$LAUNCHERFILE" 2>/dev/null; then
    # Recorder may already be alive: leave the lock in place rather than clearing ownership.
    echo 'error=pid_guard_unconfirmed'
    return 8
  fi

  _wait=0
  while [ "$_wait" -lt 3 ]; do
    _claim="$(pid_from_file "$PIDFILE" 2>/dev/null || true)"
    if [ "$_claim" = "$_pid" ] && pid_is_live "$_pid"; then
      echo 'status=started'
      echo "pid=$_pid"
      echo 'hours=24'
      echo "log=$RUNLOG"
      return 0
    fi
    if ! pid_is_live "$_pid"; then
      # The sole launched process exited before ownership claim. No recorder can begin later,
      # so cleanup is safe and a future tap can retry.
      rm -rf "$LOCKDIR" 2>/dev/null || true
      echo 'error=recorder_exited'
      tail -n 4 "$RUNLOG" 2>/dev/null || true
      return 8
    fi
    sleep 1
    _wait=$(( _wait + 1 ))
  done

  # The launch process is alive but has not claimed in time. Fail closed: it may still be
  # about to claim, therefore no path here removes the directory or starts another recorder.
  echo 'status=starting'
  echo "pid=$_pid"
  echo "log=$RUNLOG"
  return 0
}

case "${1:-status}" in
  status) full_day_status ;;
  diag) write_diag ;;
  full-day) start_full_day ;;
  *) echo 'error=bad_action'; exit 64 ;;
esac
