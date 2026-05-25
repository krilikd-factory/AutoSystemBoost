#!/system/bin/sh

[ "$ASB_GOV_ENABLED" -eq 1 ] || exit 0

ASB_FAIL_COUNT=0
ASB_SAFE_MODE_FILE="/dev/.asb/safe_mode"
ASB_RECOVERY_LOCK="/dev/.asb/recovery.lock"
ASB_RECOVERY_JSON="/dev/.asb/recovery.json"
ASB_RECOVERY_DISABLED_MARKER="/data/adb/asb/recovery_disabled"
ASB_MAX_CONSECUTIVE_FAILS=3
ASB_RECOVERY_WINDOW_S=1800
ASB_L2_THRESHOLD=2
ASB_L3_THRESHOLD=3

_recovery_count=0
_recovery_window_start=0
_last_recovery_ts=0
_last_recovery_reason=""

asb_recovery_load_state() {
  [ -r "$ASB_RECOVERY_JSON" ] || return 0
  _line="$(cat "$ASB_RECOVERY_JSON" 2>/dev/null)"
  _rc="$(echo "$_line" | sed -n 's/.*"recovery_count":\([0-9]*\).*/\1/p')"
  _rw="$(echo "$_line" | sed -n 's/.*"window_start":\([0-9]*\).*/\1/p')"
  _rt="$(echo "$_line" | sed -n 's/.*"last_recovery_ts":\([0-9]*\).*/\1/p')"
  _rr="$(echo "$_line" | sed -n 's/.*"last_recovery_reason":"\([^"]*\)".*/\1/p')"
  case "$_rc" in ''|*[!0-9]*) _rc=0 ;; esac
  case "$_rw" in ''|*[!0-9]*) _rw=0 ;; esac
  case "$_rt" in ''|*[!0-9]*) _rt=0 ;; esac
  _now_ts="$(date +%s 2>/dev/null || echo 0)"
  if [ $((_now_ts - _rw)) -gt $ASB_RECOVERY_WINDOW_S ] 2>/dev/null; then
    _recovery_count=0
    _recovery_window_start=0
    _last_recovery_ts=0
    _last_recovery_reason=""
  else
    _recovery_count=$_rc
    _recovery_window_start=$_rw
    _last_recovery_ts=$_rt
    _last_recovery_reason="$_rr"
  fi
}

asb_recovery_save_state() {
  _gov_disabled=0
  [ "$ASB_GOV_ENABLED" = "0" ] && _gov_disabled=1
  printf '{"recovery_count":%d,"window_start":%d,"last_recovery_ts":%d,"last_recovery_reason":"%s","gov_disabled":%d}\n' \
    "$_recovery_count" "$_recovery_window_start" "$_last_recovery_ts" "$_last_recovery_reason" "$_gov_disabled" \
    > "$ASB_RECOVERY_JSON" 2>/dev/null
}

asb_recovery_acquire_lock() {
  _now_ts="$(date +%s 2>/dev/null || echo 0)"
  if [ -f "$ASB_RECOVERY_LOCK" ]; then
    _lock_ts="$(cat "$ASB_RECOVERY_LOCK" 2>/dev/null)"
    case "$_lock_ts" in ''|*[!0-9]*) _lock_ts=0 ;; esac
    if [ $((_now_ts - _lock_ts)) -lt 60 ] 2>/dev/null; then
      return 1
    fi
  fi
  echo "$_now_ts" > "$ASB_RECOVERY_LOCK" 2>/dev/null
  return 0
}

asb_recovery_release_lock() {
  rm -f "$ASB_RECOVERY_LOCK" 2>/dev/null
}

asb_recovery_record() {
  _reason="$1"
  _now_ts="$(date +%s 2>/dev/null || echo 0)"
  if [ "$_recovery_window_start" = "0" ] || \
     [ $((_now_ts - _recovery_window_start)) -gt $ASB_RECOVERY_WINDOW_S ] 2>/dev/null; then
    _recovery_window_start=$_now_ts
    _recovery_count=1
  else
    _recovery_count=$((_recovery_count + 1))
  fi
  _last_recovery_ts=$_now_ts
  _last_recovery_reason="$_reason"
  asb_recovery_save_state
  asb_log "recovery: level=1 count=$_recovery_count reason=$_reason"
}

asb_recovery_level2_apply() {
  asb_log "recovery: level=2 applying shell fallback bounds (count=$_recovery_count)"
  asb_load_profile
  asb_feature_enabled CPU && apply_runtime_profile_now 2>/dev/null
}

asb_recovery_level3_safe_mode() {
  asb_log "recovery: level=3 SAFE_MODE entry (count=$_recovery_count reason=$_last_recovery_reason)"
  echo "1" > "$ASB_SAFE_MODE_FILE" 2>/dev/null
  echo "$_last_recovery_ts" > "$ASB_RECOVERY_DISABLED_MARKER" 2>/dev/null
  _gpid="$(cat /dev/.asb/governor.pid 2>/dev/null)"
  [ -n "$_gpid" ] && kill "$_gpid" 2>/dev/null
  echo "balanced" > "$MODDIR/current_profile" 2>/dev/null
  echo "balanced" > /data/adb/asb/active_profile 2>/dev/null
  asb_load_profile
  asb_feature_enabled CPU && apply_runtime_profile_now 2>/dev/null
  ASB_GOV_ENABLED=0
  asb_recovery_save_state
}

asb_recovery_load_state

if [ -f "$ASB_RECOVERY_DISABLED_MARKER" ]; then
  _marker_ts="$(cat "$ASB_RECOVERY_DISABLED_MARKER" 2>/dev/null)"
  case "$_marker_ts" in ''|*[!0-9]*) _marker_ts=0 ;; esac
  _now_ts="$(date +%s 2>/dev/null || echo 0)"
  if [ $((_now_ts - _marker_ts)) -lt 86400 ] 2>/dev/null; then
    asb_log "recovery: marker present (age=$((_now_ts - _marker_ts))s), watchdog dormant"
    exit 0
  else
    asb_log "recovery: marker stale (>24h), clearing and resuming watchdog"
    rm -f "$ASB_RECOVERY_DISABLED_MARKER" 2>/dev/null
    _recovery_count=0
    _recovery_window_start=0
    asb_recovery_save_state
  fi
fi

while true; do
  sleep 300

  if ! asb_governor_running; then
    asb_recovery_acquire_lock || {
      asb_log "recovery: lock contention, deferring"
      continue
    }
    ASB_FAIL_COUNT=$((ASB_FAIL_COUNT + 1))
    asb_recovery_record "governor_died"

    if [ "$_recovery_count" -ge "$ASB_L3_THRESHOLD" ] 2>/dev/null; then
      asb_recovery_level3_safe_mode
      asb_recovery_release_lock
      exit 0
    fi

    if [ "$_recovery_count" -ge "$ASB_L2_THRESHOLD" ] 2>/dev/null; then
      asb_recovery_level2_apply
    fi

    asb_governor_start || {
      asb_log "recovery: governor restart failed, level=2 fallback"
      asb_recovery_level2_apply
      asb_recovery_release_lock
      if [ "$_recovery_count" -ge "$ASB_L3_THRESHOLD" ] 2>/dev/null; then
        asb_recovery_level3_safe_mode
        exit 0
      fi
      continue
    }
    asb_recovery_release_lock
    continue
  fi

  ASB_FAIL_COUNT=0
  _state_age=0
  if [ -f /dev/.asb/state ]; then
    _state_mtime="$(stat -c %Y /dev/.asb/state 2>/dev/null || echo 0)"
    _now_ts="$(date +%s 2>/dev/null || echo 0)"
    _state_age=$((_now_ts - _state_mtime))
  fi
  if [ "$_state_age" -gt 240 ] 2>/dev/null; then
    asb_recovery_acquire_lock || {
      asb_log "recovery: stale state but lock contention, deferring"
      continue
    }
    asb_recovery_record "state_stale_${_state_age}s"

    if [ "$_recovery_count" -ge "$ASB_L3_THRESHOLD" ] 2>/dev/null; then
      asb_recovery_level3_safe_mode
      asb_recovery_release_lock
      exit 0
    fi

    if [ "$_recovery_count" -ge "$ASB_L2_THRESHOLD" ] 2>/dev/null; then
      asb_recovery_level2_apply
    fi

    _gpid="$(cat /dev/.asb/governor.pid 2>/dev/null)"
    [ -n "$_gpid" ] && kill "$_gpid" 2>/dev/null
    sleep 1
    asb_governor_start || {
      asb_log "recovery: stale-state restart failed, level=2 fallback"
      asb_recovery_level2_apply
      asb_recovery_release_lock
      continue
    }
    asb_recovery_release_lock
  fi
  asb_drift_check "$ASB_PROFILE" 2>/dev/null
done
