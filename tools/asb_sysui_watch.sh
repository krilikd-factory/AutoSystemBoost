#!/system/bin/sh
# asb_sysui_watch.sh - find out what is restarting SystemUI.
#
# Symptom this was written for: a minute or two after boot the screen blinks, the lock
# screen comes back, and overlays drawn by other modules (status-bar theming and the
# like) are torn down. That is SystemUI being restarted, and the question is by whom.
#
# The script watches SystemUI's PID.
#
# Usage: su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_sysui_watch.sh' # 10 min su -c
# 'sh .../asb_sysui_watch.sh 1200' # 20 min su -c 'sh .../asb_sysui_watch.sh 600
# /sdcard/my.txt' # custom path
#
# Start it right after a reboot. Press Ctrl-C to stop early - in Termux, Ctrl lives in
# the key row above the keyboard, or use volume-down + C. It also stops on its own when
# the time is up.
#
# It ALWAYS writes a file, and prints the same thing to the terminal.

DUR="${1:-600}"
OUT="${2:-}"
case "$DUR" in ''|*[!0-9]*) DUR=600 ;; esac

if [ -z "$OUT" ]; then
  for _d in /sdcard /storage/emulated/0 /data/local/tmp; do
    if [ -d "$_d" ] && [ -w "$_d" ]; then OUT="$_d/asb_sysui_watch.txt"; break; fi
  done
  [ -n "$OUT" ] || OUT="/data/adb/asb/asb_sysui_watch.txt"
fi
mkdir -p "$(dirname "$OUT")" 2>/dev/null
: > "$OUT" 2>/dev/null || OUT=""

# Print to the terminal AND to the file, so a session that gets closed still leaves the
# evidence behind.
_say() {
  printf '%s\n' "$1"
  [ -n "$OUT" ] && printf '%s\n' "$1" >> "$OUT" 2>/dev/null
  return 0
}

_uptime() { cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1; }
_pid()    { pidof com.android.systemui 2>/dev/null | awk '{print $1}'; }

_say "=== ASB SystemUI watch ==="
_say "started at:      $(date '+%Y-%m-%d %H:%M:%S')"
_say "seconds up:      $(_uptime)"
_say "watching for:    ${DUR}s   (Ctrl-C stops it early)"
_say "writing to:      ${OUT:-<terminal only - no writable path found>}"
_say ""

# --- the settings that decide whether ASB may restart SystemUI at all ---------------
CONF="/data/adb/modules/AutoSystemBoost/config/governor.conf"
_cfg() { grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'; }
_say "--- ASB settings that can restart SystemUI ---"
_say "  UX_ANIM_FORCE_RESTART = $(_cfg UX_ANIM_FORCE_RESTART)   <- the only one that kills it on purpose"
_say "  UX_MANAGE_TIMEOUTS    = $(_cfg UX_MANAGE_TIMEOUTS)      <- gates the animation-scale block"
_say "  UX_MANAGE_OEM_TOGGLES = $(_cfg UX_MANAGE_OEM_TOGGLES)"
_say "  disable_blur          = $(_cfg disable_blur)"
_say "  ui_effects_level      = $(_cfg ui_effects_level)"
_say "  current profile       = $(cat /data/adb/modules/AutoSystemBoost/current_profile 2>/dev/null)"
_say ""
_say "--- animation scales right now ---"
for _k in window_animation_scale transition_animation_scale animator_duration_scale; do
  _say "  $_k = $(settings get global $_k 2>/dev/null)"
done
_say ""

# --- baseline -----------------------------------------------------------------------
_prev="$(_pid)"
_say "SystemUI pid at start: ${_prev:-<not running>}"
_say "watching..."
_say ""

_t0="$(_uptime)"
_n=0
while [ "$_n" -lt "$DUR" ]; do
  sleep 2
  _n=$(( _n + 2 ))
  _cur="$(_pid)"
  [ -z "$_cur" ] && continue
  [ "$_cur" = "$_prev" ] && continue

  _up="$(_uptime)"
  _say "================================================================"
  _say "SystemUI RESTARTED"
  _say "  wall clock:     $(date '+%H:%M:%S')"
  _say "  seconds up:     $_up   (${_n}s into this watch)"
  _say "  pid:            $_prev -> $_cur"
  _say ""

  # Did ASB log anything in the same window? This is the deciding evidence.
  _say "  --- ASB log, last 25 lines ---"
  tail -25 /data/adb/asb/asb.log 2>/dev/null | while IFS= read -r _l; do _say "    $_l"; done
  _say ""
  _say "  --- profile apply log ---"
  tail -15 /dev/.asb_profile_state/runtime_apply.log 2>/dev/null | while IFS= read -r _l; do _say "    $_l"; done
  _say ""
  # The late /odm bind re-run lives here, and it ends with "setprop ctl.restart
  # audioserver". An audioserver restart can take SystemUI down with it, so a line here
  # timed with the restart is a much stronger lead than anything in the ASB log.
  _say "  --- vendor mounts log (late odm binds / audioserver restart) ---"
  tail -12 /data/adb/asb/vendor_mounts.log 2>/dev/null | while IFS= read -r _l; do _say "    $_l"; done
  _say ""
  _say "  --- audioserver pid now: $(pidof audioserver 2>/dev/null | awk '{print $1}') ---"
  _say ""
  _say "  --- animation scales after the restart ---"
  for _k in window_animation_scale transition_animation_scale animator_duration_scale; do
    _say "    $_k = $(settings get global $_k 2>/dev/null)"
  done
  _say ""
  # The old capture only looked at logcat AFTER the restart, which shows the new
  # SystemUI starting up and never the thing that ended the old one. Widen it and keep
  # the kill-side events.
  _say "  --- system log around the restart ---"
  logcat -b all -d -t 800 2>/dev/null \
    | grep -iE "am_kill|am_proc_died|am_crash|lowmemorykiller|Killing .*systemui|ctl\.restart|audioserver.*(died|restart)|Watchdog|ANR in" \
    | tail -40 | while IFS= read -r _l; do _say "    $_l"; done
  _say "================================================================"
  _say ""
  _prev="$_cur"
done

_say "watch finished after ${DUR}s. SystemUI pid now: $(_pid)"
_say "saved to: ${OUT:-<terminal only>}"
_say ""
_say "How to read this:"
_say "  * An ASB log line at the same second as the restart means ASB did it."
_say "    With UX_ANIM_FORCE_RESTART=1 that is the animation-scale path in profile_core."
_say "  * ASB logs quiet, and logcat showing am_kill / lowmemorykiller means something"
_say "    else killed it - memory pressure or another module."
_say "  * No restart at all during the watch means the trigger is elsewhere; run it again"
_say "    starting from the moment of a reboot, since the first 2 minutes are the window."
exit 0
