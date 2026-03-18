#!/system/bin/sh
# asb_watchdog.sh — governor process watchdog
# Sourced inside a background subshell from service.sh

[ "$ASB_GOV_ENABLED" -eq 1 ] || exit 0
while true; do
  sleep 300
  if ! asb_governor_running; then
    asb_log "governor watchdog: process died, restarting"
    asb_governor_start || {
      asb_log "governor restart failed, entering shell fallback"
      asb_load_profile
      asb_feature_enabled CPU && apply_runtime_profile_now
      ASB_GOV_ENABLED=0
      exit 0
    }
    continue
  fi
  _state_age=0
  if [ -f /dev/.asb/state ]; then
    _state_mtime="$(stat -c %Y /dev/.asb/state 2>/dev/null || echo 0)"
    _now_ts="$(date +%s 2>/dev/null || echo 0)"
    _state_age=$((_now_ts - _state_mtime))
  fi
  if [ "$_state_age" -gt 240 ] 2>/dev/null; then
    asb_log "governor watchdog: state stale (${_state_age}s), restarting"
    _gpid="$(cat /dev/.asb/governor.pid 2>/dev/null)"
    [ -n "$_gpid" ] && kill "$_gpid" 2>/dev/null
    sleep 1
    asb_governor_start || {
      asb_log "governor restart failed after stale, shell fallback"
      asb_load_profile
      asb_feature_enabled CPU && apply_runtime_profile_now
      ASB_GOV_ENABLED=0
      exit 0
    }
  fi
done
