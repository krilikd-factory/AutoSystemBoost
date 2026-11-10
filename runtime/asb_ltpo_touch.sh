#!/system/bin/sh
# ASB integrated LTPO interaction controller (fix236).
#
# Independent Android-range implementation: touch opens the panel's highest advertised
# mode; a short quiet interval selects the normal 60 Hz ADFR-capable mode (configurable).
# It waits in blocking getevent, never polls display/foreground state, and writes Settings
# only on an actual active/idle transition. Camera and game frames are not lowered.
# The install-time oplus_vrr_config bind remains a separate, stock-safe ADFR enabler.
set -u

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
STATE_DIR="${ASB_LTPO_STATE_DIR:-/data/adb/asb}"
CONF="$MODDIR/config/governor.conf"
RSTATE="${ASB_LTPO_RSTATE:-/dev/.asb/state}"
DISPLAY_DUMP="${ASB_LTPO_DISPLAY_DUMP:-}"
VIDEO_LOWERED="$STATE_DIR/ltpo_video.lowered"
PIDFILE="$STATE_DIR/ltpo_touch.pid"
STOPFILE="$STATE_DIR/ltpo_touch.stop"
HEARTBEAT="$STATE_DIR/ltpo_touch.heartbeat"
CHILD=""
[ -f "$MODDIR/runtime/asb_settings.sh" ] && . "$MODDIR/runtime/asb_settings.sh"
. "$MODDIR/runtime/asb_ltpo_lock.sh"

_cfg() {
  grep -E "^$1=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' \r'
}
_max_mode() {
  if [ -n "$DISPLAY_DUMP" ]; then cat "$DISPLAY_DUMP" 2>/dev/null
  else dumpsys display 2>/dev/null; fi \
    | sed -n 's/.*DisplayMode{id=[0-9]*,.*peakRefreshRate=\([0-9.]*\).*/\1/p' \
    | awk '{ v=int($1+0.5); if(v>m)m=v } END { if(m>=30 && m<=480) print m }'
}
_get() { command -v asb_set_get >/dev/null 2>&1 && asb_set_get system "$1" || settings get system "$1" 2>/dev/null | sed 's/^null$//'; }
_put() { command -v asb_set_put >/dev/null 2>&1 && asb_set_put system "$1" "$2" || settings put system "$1" "$2" >/dev/null 2>&1; }
_peak_write() {
  _pw="$1"
  # The existence check, ownership-record edit and Settings write are one contract.
  # Otherwise video can publish its record between our check and write, and the touch
  # value can overwrite the content-matched rate (or lose the video restore target).
  asb_ltpo_lock || return 1
  if [ -f "$VIDEO_LOWERED" ]; then
    # The video owner currently holds the live value. Change only the value it will
    # restore; never fight its 24/30/60 fps request.
    asb_ltpo_set_orig "$VIDEO_LOWERED" "$_pw"
    _pw_rc=$?
  else
    [ "$(_get peak_refresh_rate)" = "$_pw" ] || _put peak_refresh_rate "$_pw"
    _pw_rc=$?
  fi
  asb_ltpo_unlock
  return "$_pw_rc"
}
_find_touch() {
  if [ -n "${ASB_LTPO_TOUCH_DEVICE:-}" ] && [ -e "$ASB_LTPO_TOUCH_DEVICE" ]; then
    printf '%s\n' "$ASB_LTPO_TOUCH_DEVICE"; return 0
  fi
  for _d in /dev/input/event*; do
    [ -e "$_d" ] || continue
    if getevent -pl "$_d" 2>/dev/null | grep -q 'ABS_MT_POSITION_X'; then
      printf '%s\n' "$_d"; return 0
    fi
  done
  return 1
}
_wait_event() {
  if [ -n "${1:-}" ]; then timeout "$1" getevent -c 1 "$DEV" >/dev/null 2>&1 &
  else getevent -c 1 "$DEV" >/dev/null 2>&1 & fi
  CHILD=$!
  wait "$CHILD" 2>/dev/null
  _rc=$?
  CHILD=""
  return "$_rc"
}
SFSTATE="$STATE_DIR/ltpo_peak_force.state"
SFUNSUP="$STATE_DIR/ltpo_peak_force.unsupported"
PEAK_FORCE=0
SFID=""
SFHZ=""
SFTS=0
SFON=0
SFFAIL=0
_sf_mode() {
  if [ -n "$DISPLAY_DUMP" ]; then cat "$DISPLAY_DUMP" 2>/dev/null
  else dumpsys display 2>/dev/null; fi | awk '
    function field(s, k,   r) { r = ""; if (match(s, k "=[0-9.]+")) r = substr(s, RSTART + length(k) + 1, RLENGTH - length(k) - 1); return r }
    /mActiveSfDisplayMode=DisplayMode\{/ { aw = field($0, "width") "x" field($0, "height"); next }
    /DisplayMode\{id=[0-9]+, width=/ {
      id = field($0, "id"); wh = field($0, "width") "x" field($0, "height"); pk = field($0, "peakRefreshRate") + 0
      if (id != "" && !((id SUBSEP wh) in seen)) { seen[id SUBSEP wh] = 1; n++; ids[n] = id; whs[n] = wh; pks[n] = pk }
    }
    END {
      if (aw == "" || aw == "x") exit
      b = 0; bp = 0
      for (i = 1; i <= n; i++) if (whs[i] == aw && pks[i] > bp) { bp = pks[i]; b = i }
      if (b > 0) printf "%s %d\n", ids[b], int(bp + 0.5)
    }'
}
_sf_force() {
  _now_s="$(date +%s 2>/dev/null || echo 0)"
  if [ -z "$SFID" ] || [ $(( _now_s - SFTS )) -ge 30 ] 2>/dev/null; then
    _sm="$(_sf_mode)"
    SFTS="$_now_s"
    SFID="${_sm%% *}"; SFHZ="${_sm##* }"
    case "$SFID$SFHZ" in ''|*[!0-9]*) SFID=""; SFHZ="" ;; esac
  fi
  [ -n "$SFID" ] || return 1
  _sr="$(service call SurfaceFlinger 1035 i32 "$SFID" 2>&1)"
  case "$_sr" in
    *rror*|*xception*|'') SFFAIL=$((SFFAIL + 1))
      if [ "$SFFAIL" -ge 3 ]; then
        PEAK_FORCE=0
        printf 'reason=refused\n' > "$SFUNSUP" 2>/dev/null
        printf 'state=unsupported\n' > "$SFSTATE" 2>/dev/null
      fi
      return 1 ;;
  esac
  SFFAIL=0
  SFON=1
  printf 'state=forced\nmode=%s\nhz=%s\n' "$SFID" "$SFHZ" > "$SFSTATE" 2>/dev/null
  return 0
}
_sf_release() {
  [ "$SFON" = 1 ] || return 0
  service call SurfaceFlinger 1035 i32 -1 >/dev/null 2>&1
  SFON=0
  [ "$PEAK_FORCE" = 1 ] && printf 'state=idle\nmode=%s\nhz=%s\n' "$SFID" "$SFHZ" > "$SFSTATE" 2>/dev/null
  return 0
}
_active() {
  _peak_write "$MAX.0" && touch "$HEARTBEAT" 2>/dev/null || true
  [ "$PEAK_FORCE" = 1 ] && _sf_force
  return 0
}
_idle() {
  _sf_release
  _peak_write "$IDLE.0" && touch "$HEARTBEAT" 2>/dev/null || true
}
_cleanup() {
  [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null || true
  _sf_release
  rm -f "$PIDFILE" "$STOPFILE" "$HEARTBEAT" 2>/dev/null
  exit 0
}
trap _cleanup TERM INT HUP

[ "$(_cfg ltpo_force)" = "1" ] || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null
rm -f "$STOPFILE" 2>/dev/null
# Publish ownership only after input and panel discovery both succeed. The apply owner
# uses this PID as the handover barrier: an early failure must leave the external LTPO
# writer running instead of pausing it and then silently losing touch switching.
DEV="$(_find_touch)" || exit 1
MAX="$(_max_mode)"
case "$MAX" in ''|*[!0-9]*) exit 1 ;; esac
printf '%s\n' "$$" > "$PIDFILE" 2>/dev/null || exit 1
# A transition marker is evidence for status/diagnostics. It is deliberately not a
# stale-PID restart timer: a healthy idle watcher may block in getevent indefinitely.
touch "$HEARTBEAT" 2>/dev/null || true
# Probe once: toybox supports fractional delays, some older sleep applets do not.
SLEEP_STEP=0.2
sleep 0.01 2>/dev/null || SLEEP_STEP=1
IDLE="$(_cfg ltpo_idle_rate)"; [ -n "$IDLE" ] || IDLE=60
case "$IDLE" in ''|*[!0-9]*) IDLE=60 ;; esac
[ "$IDLE" -ge 30 ] 2>/dev/null || IDLE=30
[ "$IDLE" -le "$MAX" ] 2>/dev/null || IDLE="$MAX"
TIMEOUT="$(_cfg ltpo_idle_s)"; [ -n "$TIMEOUT" ] || TIMEOUT=2
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=2 ;; esac
[ "$TIMEOUT" -ge 1 ] 2>/dev/null || TIMEOUT=1
[ "$TIMEOUT" -le 15 ] 2>/dev/null || TIMEOUT=15

if [ "$(_cfg ltpo_peak_force)" = 1 ] && [ ! -f "$SFUNSUP" ] && command -v service >/dev/null 2>&1; then
  PEAK_FORCE=1
  SFON=1
  _sf_release
elif [ "$(_cfg ltpo_peak_force)" != 1 ]; then
  rm -f "$SFSTATE" "$SFUNSUP" 2>/dev/null
fi
state=active
_active
while [ ! -f "$STOPFILE" ] && [ -e "$DEV" ]; do
  if [ "$state" = idle ]; then
    if _wait_event ""; then
      state=active
      _active
    fi
  else
    if _wait_event "$TIMEOUT"; then
      # Consume a complete gesture at a bounded rate; this is an event wait, not a timer.
      sleep "$SLEEP_STEP"
    else
      # Camera and games can animate without touch. The governor state is read only at
      # this transition, never in a polling loop.
      if grep -Eq '^camera_hold=1$|^state=GAMING$' "$RSTATE" 2>/dev/null; then
        continue
      fi
      state=idle
      _idle
    fi
  fi
done
_cleanup
