#!/system/bin/sh
# asb_wifi_fallback.sh — opt-in escape hatch for a framework-unvalidated Wi‑Fi route.
#
# This does NOT tune RSSI thresholds, preferred network mode or carrier policy. Android normally
# owns that decision. When the user explicitly enables the active fallback, and Android itself
# says the current Wi‑Fi is *not validated* while it still owns the default route, ASB briefly
# releases Wi‑Fi so ConnectivityService can put mobile data on the route. The action is bounded,
# screen-on only, has a cooldown and turns Wi‑Fi back on afterwards.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
STATE_DIR="${ASB_WIFI_FALLBACK_STATE_DIR:-/data/adb/asb}"
PID="$STATE_DIR/wifi_fallback.pid"
ACTION="$STATE_DIR/wifi_fallback.action"
COOLDOWN="$STATE_DIR/wifi_fallback.cooldown"
LOG="$STATE_DIR/wifi_fallback.log"
LOCK="$STATE_DIR/wifi_fallback.watch.lock"
# Injected only by host fixtures; production always reads Android's /proc. Keeping this separate
# makes watcher identity portable across toybox shells that exec the script without retaining `sh`.
PROC_ROOT="${ASB_WIFI_FALLBACK_PROC_ROOT:-/proc}"

# The environment overrides are only for deterministic host fixtures. Still validate them here:
# a malformed or zero value must never turn the root watcher into a busy loop or endless outage.
_valid_seconds() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}
INTERVAL_S=8
RELEASE_S=28
COOLDOWN_S=150
_raw_interval="${ASB_WIFI_FALLBACK_INTERVAL_S:-}"
_raw_release="${ASB_WIFI_FALLBACK_RELEASE_S:-}"
_raw_cooldown="${ASB_WIFI_FALLBACK_COOLDOWN_S:-}"
_valid_seconds "$_raw_interval" 1 120 && INTERVAL_S="$_raw_interval"
_valid_seconds "$_raw_release" 1 120 && RELEASE_S="$_raw_release"
_valid_seconds "$_raw_cooldown" 1 3600 && COOLDOWN_S="$_raw_cooldown"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}
_radio_policy_enabled() { [ "$(_cfg radio_policy_enable)" = 1 ]; }
_enabled() { _radio_policy_enabled && [ "$(_cfg net_handover_active)" = 1 ]; }
_now() { date +%s 2>/dev/null || echo 0; }
_log() { mkdir -p "$STATE_DIR" 2>/dev/null; printf '%s wifi_fallback: %s\n' "$(date '+%F %T' 2>/dev/null || echo now)" "$*" >> "$LOG" 2>/dev/null; tail -n 80 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null || true; }

_screen_on() {
  _p="$(dumpsys power 2>/dev/null)"
  printf '%s' "$_p" | grep -Eqi 'mWakefulness=Awake|mInteractive=true|Display Power: state=ON'
}
_mobile_allowed() {
  [ "$(settings get global airplane_mode_on 2>/dev/null | tr -d ' \r')" != 1 ] || return 1
  # Explicit Android mobile-data off is authoritative. An absent legacy setting is not treated
  # as off because modern multi-SIM ROMs can expose data state only through telephony.
  [ "$(settings get global mobile_data 2>/dev/null | tr -d ' \r')" != 0 ]
}
_wifi_default() {
  ip route get 1.1.1.1 2>/dev/null | grep -Eq '(^| )dev wlan[0-9A-Za-z_.-]*([[:space:]]|$)'
}
_wifi_unvalidated() {
  _w="$(dumpsys wifi 2>/dev/null)"
  # Require framework-owned validation evidence. RSSI alone is deliberately never enough:
  # a weak but still working local Wi-Fi link must remain Android's and the user's choice.
  printf '%s\n' "$_w" | grep -Eqi 'VALIDATED[=: ]*false|NOT_VALIDATED|not[[:space:]-]*validated|no[[:space:]-]*internet|validated=false'
}
_wifi_disable() {
  svc wifi disable >/dev/null 2>&1 || cmd wifi set-wifi-enabled disabled >/dev/null 2>&1 || return 1
  return 0
}
_wifi_enable() {
  svc wifi enable >/dev/null 2>&1 || cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 || return 1
  return 0
}
_restore_if_owned() {
  [ -f "$ACTION" ] || return 0
  if _wifi_enable; then
    rm -f "$ACTION" 2>/dev/null
    _log 'Wi-Fi re-enabled after ASB fallback window'
    return 0
  fi
  # Keep the ownership marker if Android rejects the restore call; a subsequent watcher pass,
  # reconcile or uninstall stop can retry instead of pretending Wi-Fi was restored.
  _log 'could not re-enable ASB-owned Wi-Fi; retry retained'
  return 1
}
_reconcile_action() {
  [ -f "$ACTION" ] || return 0
  _line="$(cat "$ACTION" 2>/dev/null)"
  _until="${_line#*|}"
  case "$_until" in ''|*[!0-9]*) _until=0 ;; esac
  _nowv="$(_now)"
  if ! _enabled || [ "$_nowv" -ge "$_until" ] 2>/dev/null; then
    if _restore_if_owned; then
      _cool_until=$((_nowv + COOLDOWN_S))
      printf '%s\n' "$_cool_until" > "$COOLDOWN" 2>/dev/null
      _log "cooldown started (${COOLDOWN_S}s)"
    fi
  fi
}
_in_cooldown() {
  [ -f "$COOLDOWN" ] || return 1
  _until="$(cat "$COOLDOWN" 2>/dev/null | tr -dc '0-9')"
  _nowv="$(_now)"
  case "$_until" in ''|*[!0-9]*) rm -f "$COOLDOWN" 2>/dev/null; return 1 ;; esac
  if [ "$_nowv" -lt "$_until" ] 2>/dev/null; then return 0; fi
  rm -f "$COOLDOWN" 2>/dev/null
  return 1
}
_try_release() {
  _enabled || return 0
  _screen_on || return 0
  _mobile_allowed || return 0
  _wifi_default || return 0
  _wifi_unvalidated || return 0
  _in_cooldown && return 0
  _nowv="$(_now)"
  _until=$((_nowv + RELEASE_S))
  if _wifi_disable; then
    printf '%s|%s\n' "$_nowv" "$_until" > "$ACTION" 2>/dev/null
    _log "released unvalidated Wi-Fi default route for ${RELEASE_S}s"
  else
    _log 'could not disable Wi-Fi; no route action taken'
  fi
}
_status() {
  if ! _radio_policy_enabled; then echo 'radio_policy_off'; return; fi
  if ! _enabled; then echo 'off'; return; fi
  if [ -f "$ACTION" ]; then
    _until="$(cut -d'|' -f2 "$ACTION" 2>/dev/null | tr -dc '0-9')"
    echo "releasing_wifi_until=${_until:-unknown}"; return
  fi
  if _in_cooldown; then echo "cooldown_until=$(cat "$COOLDOWN" 2>/dev/null)"; return; fi
  if _wifi_default && _wifi_unvalidated; then echo 'unvalidated_wifi_default_detected'; else echo 'armed_waiting_for_unvalidated_wifi_default'; fi
}
_pid_is_our_watcher() {
  _candidate="$1"
  case "$_candidate" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_candidate" != "$$" ] || return 1
  [ -r "$PROC_ROOT/$_candidate/cmdline" ] || return 1
  _cmdline="$(tr '\000' ' ' < "$PROC_ROOT/$_candidate/cmdline" 2>/dev/null)"
  # Android can retain `sh`, use an absolute interpreter, or exec the script directly. The
  # invariant is the exact module script plus its dedicated `watch` argument, not the token
  # immediately before it. This remains a narrow identity check: a stale/reused state PID is
  # never accepted merely for containing a generic Wi-Fi word or the script basename.
  case "$_cmdline" in
    *"$MODDIR/runtime/asb_wifi_fallback.sh watch"*) return 0 ;;
    *) return 1 ;;
  esac
}
_watcher_alive() {
  _pid="$(cat "$PID" 2>/dev/null | tr -dc '0-9')"
  if _pid_is_our_watcher "$_pid" && kill -0 "$_pid" 2>/dev/null; then
    return 0
  fi
  # A power loss or a cleaner can remove the PID file while the lock-protected watcher is
  # healthy. Recover only from a verified exact argv, never from an arbitrary state-file PID.
  if _lock_owner_alive; then
    _pid="$(cat "$LOCK/pid" 2>/dev/null | tr -dc '0-9')"
    printf '%s\n' "$_pid" > "$PID" 2>/dev/null
    return 0
  fi
  return 1
}
_lock_owner_alive() {
  [ -f "$LOCK/pid" ] || return 1
  _lock_pid="$(cat "$LOCK/pid" 2>/dev/null | tr -dc '0-9')"
  _pid_is_our_watcher "$_lock_pid" && kill -0 "$_lock_pid" 2>/dev/null
}
_acquire_watch_lock() {
  mkdir "$LOCK" 2>/dev/null && { printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null; return 0; }
  _lock_owner_alive && return 1
  # A second reconcile can observe the directory during the first watcher's tiny mkdir→pid
  # window. Give it one bounded second before treating an incomplete lock as stale.
  sleep 1
  _lock_owner_alive && return 1
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null
  return 0
}
_release_watch_lock() {
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null
}
_watch_cleanup() {
  _restore_if_owned
  [ "$(cat "$PID" 2>/dev/null)" = "$$" ] && rm -f "$PID" 2>/dev/null
  _release_watch_lock
}
_stop() {
  # Target only the recorded PID after confirming its exact watcher argv through /proc.
  # Never kill by a broad Wi-Fi/network name or a user-controlled PID file alone.
  # Stop by lock ownership as well as by argv.
  #
  # _watcher_alive confirms identity through /proc/<pid>/cmdline, which is the right guard
  # against killing an unrelated process that happens to hold a reused PID. But it is also
  # the only path to the kill, so a watcher whose argv no longer matches - re-exec'd,
  # wrapped by a different interpreter, or simply started before an update - could never be
  # stopped. Turning the feature off then removed the PID file and left the process
  # running: an orphan loop polling Wi-Fi until reboot, with nothing left on disk pointing
  # at it. That is the leak the contract test has been failing on.
  #
  # The lock directory records the PID that took it, and only this script writes there. If
  # that PID is alive it is ours whatever argv says, so it is safe to signal - and the
  # identity check still gates the PID file, which is the value a user could tamper with.
  _pid="$(cat "$PID" 2>/dev/null | tr -dc '0-9')"
  _lpid="$(cat "$LOCK/pid" 2>/dev/null | tr -dc '0-9')"
  for _target in "$_pid" "$_lpid"; do
    case "$_target" in ''|*[!0-9]*) continue ;; esac
    [ "$_target" = "$$" ] && continue
    kill -0 "$_target" 2>/dev/null || continue
    kill "$_target" 2>/dev/null || true
  done
  _wait=0
  while [ "$_wait" -lt 3 ]; do
    _still=0
    for _target in "$_pid" "$_lpid"; do
      case "$_target" in ''|*[!0-9]*) continue ;; esac
      [ "$_target" = "$$" ] && continue
      kill -0 "$_target" 2>/dev/null && _still=1
    done
    [ "$_still" = "0" ] && break
    sleep 1; _wait=$((_wait + 1))
  done
  _restore_if_owned
  rm -f "$PID" "$COOLDOWN" 2>/dev/null
  _lock_owner_alive || rm -rf "$LOCK" 2>/dev/null
}
_watch() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  _acquire_watch_lock || { _log 'watcher start skipped (another ASB watcher owns the lock)'; return 0; }
  printf '%s\n' "$$" > "$PID" 2>/dev/null
  trap '_watch_cleanup; exit 0' EXIT HUP INT TERM
  _log 'watcher started'
  while _enabled; do
    _reconcile_action
    [ -f "$ACTION" ] || _try_release
    sleep "$INTERVAL_S"
  done
  _watch_cleanup
  rm -f "$COOLDOWN" 2>/dev/null
  _log 'watcher stopped (feature off)'
}

case "${1:-reconcile}" in
  reconcile)
    if _enabled; then
      if ! _watcher_alive; then
        rm -f "$PID" 2>/dev/null
        ( MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_wifi_fallback.sh" watch </dev/null >/dev/null 2>&1 & )
      fi
    else
      _stop
    fi
    ;;
  watch) _watch ;;
  stop) _stop ;;
  status) _status ;;
  *) echo 'usage: asb_wifi_fallback.sh reconcile|watch|stop|status' >&2; exit 2 ;;
esac
