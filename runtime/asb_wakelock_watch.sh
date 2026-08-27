#!/system/bin/sh
# asb_wakelock_watch.sh - name what is keeping the phone awake, and act only where it is safe.
#
# Six full-day captures put the same finding in front of us repeatedly: on some phones the
# CPU stays awake 73-84% of a screen-off night while every tuning knob in the module is
# already set correctly. No cap, profile or Doze level helps there, because the phone never
# reaches the state those settings govern. The drain is not the module's to fix by tuning -
# but it can be named, and a named cause is one the user can act on.
#
# Deliberately conservative about acting. A wakelock is held by an app that believes it
# needs one, and killing them wholesale is how a battery module becomes the reason an alarm
# did not ring or a message arrived an hour late. So: measure always, report always, and
# release only partial wakelocks held by user-installed packages, only while the screen has
# been off for a long stretch, and only when the user has switched it on.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
STATE=/data/adb/asb/wakelock_top
[ -f "$CONF" ] || exit 0

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]'
}
_has() { command -v "$1" >/dev/null 2>&1; }

# --- measure -------------------------------------------------------------------------
#
# /sys/kernel/debug/wakeup_sources is the kernel's own account and needs no permissions
# beyond root. active_since is what matters: a source held right now, and for how long.
asb_wl_snapshot() {
  _src=/sys/kernel/debug/wakeup_sources
  [ -r "$_src" ] || return 1
  mkdir -p /data/adb/asb 2>/dev/null
  # Columns vary between kernels; find active_since by header rather than by position,
  # because assuming column 7 is how this breaks silently on the next SoC.
  awk 'NR==1 {
         for (i = 1; i <= NF; i++) {
           if ($i == "name")          n = i;
           if ($i == "active_since")  a = i;
           if ($i == "active_count")  c = i;
         }
         next
       }
       n && a && $a > 0 {
         printf "%s|%s|%s\n", $n, $a, (c ? $c : 0)
       }' "$_src" 2>/dev/null | sort -t'|' -k2 -rn | head -12 > "$STATE" 2>/dev/null
  [ -s "$STATE" ]
}

# --- act -----------------------------------------------------------------------------
#
# Only ever partial wakelocks from third-party packages. Never a kernel source, never a
# system one: those are the modem, the display, the alarm timer and the sensors, and a
# module that releases them is breaking the phone rather than saving power.
# WiFi multicast is its own problem, and a bigger one than any single app wakelock.
#
# A multicast lock tells the Wi-Fi chip to receive packets addressed to the whole network,
# not just to this phone - so the radio cannot enter its low-power filter mode. On the
# capture that prompted this it was held 11 minutes out of 60, more than five times the
# next holder, by an app doing device discovery in the background.
#
# Casting, printer discovery and some smart-home apps genuinely need it WHILE IN USE. None
# of them need it with the screen off for the better part of an hour, which is the only
# case this touches.
asb_wl_relax_multicast() {
  _has dumpsys || return 0
  _mc="$(dumpsys batterystats 2>/dev/null \
         | sed -n 's/.*Total WiFi Multicast wakelock time: \(.*\)/\1/p' | head -1)"
  [ -n "$_mc" ] || return 0
  # Minutes only: anything under a minute is noise, and parsing "11m 2s 985ms" for
  # precision we do not need would just be another thing to get wrong.
  _mcm="$(printf '%s' "$_mc" | sed -n 's/^\([0-9]*\)m.*/\1/p')"
  case "$_mcm" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_mcm" -ge 5 ] 2>/dev/null || return 0
  echo "wakelock: WiFi multicast held ${_mcm} min in the last hour - the radio cannot idle while it is"
  echo "          (a discovery/casting app is asking for it; check Settings > Apps if this is unexpected)"
}

asb_wl_relax() {
  _has dumpsys || return 0
  _has pm || return 0
  _third="$(pm list packages -3 2>/dev/null | sed 's/^package://')"
  [ -n "$_third" ] || return 0

  # The same protected classes the doze trim uses. An authenticator or a messenger that
  # cannot wake is worse than a warm phone.
  for _p in $(dumpsys power 2>/dev/null \
              | sed -n 's/.*PARTIAL_WAKE_LOCK.*ACQ.*(\([a-zA-Z0-9_.]*\)).*/\1/p' \
              | sort -u); do
    case "$_third" in *"$_p"*) : ;; *) continue ;; esac
    # Package identifiers rarely contain the literal word `messaging`: WhatsApp, Telegram
    # and Signal are examples in real wake traces. These apps are notification-bearing, so
    # never auto-restrict them here; a user can still manage them directly in Android Settings.
    case "$_p" in
      *authenticator*|*.auth.*|*.otp.*|*.mfa.*|*passkey*|\
      *dialer*|*.mms*|*messaging*|*whatsapp*|*telegram*|*signal*|*viber*|\
      *line*|*discord*|*slack*|*matrix*|*threema*|*wechat*|*kakao*|\
      *clock*|*alarm*) continue ;;
    esac
    # forcestop is not used: it kills the app. Standby-bucket restricted tells Android to
    # stop honouring its background requests, which the platform already knows how to undo.
    if am set-standby-bucket "$_p" restricted >/dev/null 2>&1; then
      # Recorded so uninstall can undo exactly what we did and nothing else.
      grep -qxF "$_p" /data/adb/asb/wakelock_restricted 2>/dev/null \
        || echo "$_p" >> /data/adb/asb/wakelock_restricted
      echo "wakelock: $_p moved to restricted (held a wakelock during a long screen-off)"
    fi
  done
}

# Snapshot from batterystats when debugfs is unavailable.
#
# /sys/kernel/debug/wakeup_sources is not mounted on every ROM, and when it is missing the
# whole feature went silent - no file, no names, nothing in the report. batterystats has
# the same information in a different shape and needs no debugfs, so it is worth having as
# the fallback rather than giving up.
#
# It also carries something wakeup_sources does not: WiFi Multicast, which on the capture
# that prompted this was the single largest holder at 11 minutes out of 60.
asb_wl_snapshot_bs() {
  _has dumpsys || return 1
  mkdir -p /data/adb/asb 2>/dev/null
  dumpsys batterystats 2>/dev/null \
    | sed -n 's/.*Kernel Wake lock \([^:]*\): \([0-9hms ]*\).*/\1|\2/p' \
    | head -12 > "$STATE" 2>/dev/null
  # Multicast is reported on its own line and is worth naming separately.
  dumpsys batterystats 2>/dev/null \
    | sed -n 's/.*Total WiFi Multicast wakelock time: \(.*\)/WiFi-Multicast|\1|0/p' \
    | head -1 >> "$STATE" 2>/dev/null
  [ -s "$STATE" ]
}

asb_wl_snapshot || asb_wl_snapshot_bs || exit 0

case "$(_cfg wakelock_action)" in
  1|on|true) : ;;
  *) exit 0 ;;
esac

# Screen must have been off a while. A partial wakelock during active use is normal and
# none of our business; the same lock two hours into the night is the reported problem.
_awake="$(grep -m1 '^awake_pct_screenoff=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
_win="$(grep -m1 '^awake_window_min=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
# The snapshot above already ran and is worth having on its own - the report names the
# holder whether or not we act. Only the ACTION below needs the awake figure, so a missing
# one stops the action, not the measurement.
case "${_awake:--1}" in ''|-1) exit 0 ;; esac
[ "${_win:-0}" -ge 45 ] 2>/dev/null || exit 0
[ "${_awake:-0}" -ge 25 ] 2>/dev/null || exit 0

asb_wl_relax
asb_wl_relax_multicast
exit 0
