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
PIDFILE="$STATE_DIR/full_day_webui.pid"
RUNLOG="${ASB_DEBUG_SUPPORT_RUNLOG:-/data/local/tmp/asb_full_day.out}"
DIAG_OUTDIR="${ASB_DEBUG_SUPPORT_DIAG_OUTDIR:-/sdcard/Download}"

running_pid() {
  _pid=""
  [ -r "$PIDFILE" ] && _pid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
  [ -n "$_pid" ] || return 1
  kill -0 "$_pid" 2>/dev/null || return 1
  printf '%s' "$_pid"
}

full_day_status() {
  _pid="$(running_pid 2>/dev/null || true)"
  if [ -n "$_pid" ]; then
    echo "status=running"
    echo "pid=$_pid"
    echo "log=$RUNLOG"
    return 0
  fi
  rm -f "$PIDFILE" 2>/dev/null || true
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
  _pid="$(running_pid 2>/dev/null || true)"
  if [ -n "$_pid" ]; then
    echo "status=already_running"
    echo "pid=$_pid"
    echo "log=$RUNLOG"
    return 0
  fi
  rm -f "$PIDFILE" 2>/dev/null || true
  [ -f "$MODDIR/tools/logkit/asb_log_full_day.sh" ] || { echo 'error=logkit_missing'; return 6; }
  mkdir -p "$STATE_DIR" 2>/dev/null || { echo 'error=state_dir_failed'; return 7; }
  # Reserve the guard before fork. noclobber makes two WebUI sessions serialize without
  # starting a second recorder between their individual status checks.
  if ( set -C; : > "$PIDFILE" ) 2>/dev/null; then
    printf '%s\n' "$$" > "$PIDFILE" 2>/dev/null || { rm -f "$PIDFILE" 2>/dev/null || true; echo 'error=pid_guard_failed'; return 8; }
  else
    _pid="$(running_pid 2>/dev/null || true)"
    if [ -n "$_pid" ]; then
      echo "status=already_running"
      echo "pid=$_pid"
      echo "log=$RUNLOG"
      return 0
    fi
    echo 'error=pid_guard_busy'
    return 8
  fi
  # Equivalent to the documented nohup command, with a PID guard and no inherited WebUI stdin.
  nohup sh "$MODDIR/tools/logkit/asb_log_full_day.sh" 24 > "$RUNLOG" 2>&1 < /dev/null &
  _pid=$!
  printf '%s\n' "$_pid" > "$PIDFILE" 2>/dev/null || { rm -f "$PIDFILE" 2>/dev/null || true; echo 'error=pid_guard_failed'; return 8; }
  sleep 1
  if kill -0 "$_pid" 2>/dev/null; then
    echo 'status=started'
    echo "pid=$_pid"
    echo "hours=24"
    echo "log=$RUNLOG"
    return 0
  fi
  rm -f "$PIDFILE" 2>/dev/null || true
  echo 'error=recorder_exited'
  tail -n 4 "$RUNLOG" 2>/dev/null || true
  return 8
}

case "${1:-status}" in
  status) full_day_status ;;
  diag) write_diag ;;
  full-day) start_full_day ;;
  *) echo 'error=bad_action'; exit 64 ;;
esac
