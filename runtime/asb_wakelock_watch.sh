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
D="${ASB_WL_DIR:-/data/adb/asb}"
RSTATE="${ASB_WL_STATE:-/dev/.asb/state}"
STATE="$D/wakelock_top"
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
  mkdir -p "$D" 2>/dev/null
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
# Limit multicast for apps that are not being used.
#
# The report-only version named the holder and stopped there, on the grounds that casting
# and printer discovery genuinely need this while in use. That reasoning still holds - but
# a capture now shows 35 minutes of multicast wakelock in a single session, on a phone
# whose owner reported the battery going faster. A multicast lock keeps the Wi-Fi chip
# receiving every packet on the network instead of just its own, so the radio cannot enter
# its low-power filter mode for as long as it is held.
#
# The same three conditions as the GPS trim, for the same reason: user-installed app, its
# process CACHED, screen off. An app being looked at is never touched, and neither is a
# system component. Recorded per package so it is undone on uninstall.
asb_wl_relax_multicast() {
  _act="${1:-0}"
  _has dumpsys || return 0
  MC="$D/wakelock_multicast"
  # Hours included. The old parse took "^([0-9]*)m" and read "1h 2m" as nothing at all -
  # so the worst case, multicast held for over an hour, was the one case never reported.
  _mcs="$(dumpsys batterystats 2>/dev/null | awk "$_WL_DUR_AWK"'
    /Total WiFi Multicast wakelock time:/ { s = $0; sub(/.*time: /, "", s); print dur(s); exit }')"
  case "$_mcs" in ''|*[!0-9]*) _mcs=0 ;; esac
  mkdir -p "$D" 2>/dev/null
  echo "total|$_mcs" > "$MC.tmp" 2>/dev/null || return 0
  # Holders right now. WifiMulticastLockManager prints each as "Multicaster{tag uid=10123}";
  # the old sed expected a package name after the uid and captured an empty string, so
  # the trim below never had a candidate. Resolved by uid like the CPU wakelocks.
  for _u in $(dumpsys wifi 2>/dev/null \
              | sed -n 's/.*Multicaster{.* uid=\([0-9][0-9]*\).*/\1/p' | sort -u); do
    _pl="$(printf '%s\n' "$_map" | awk -v u="$_u" '$1 == u { print $2 }')"
    if [ -z "$_pl" ]; then
      # A system component (Nearby, the cast receiver, the framework). Named, never touched.
      echo "uid $_u|system" >> "$MC.tmp"
      continue
    fi
    for _p in $_pl; do
      if grep -qxF "$_p" "$D/multicast_restricted" 2>/dev/null; then
        _v=restricted
      else
        # Casting, printing and local-device control need multicast the moment the user
        # opens them; breaking those is a worse outcome than the battery cost.
        case "$_p" in
          *cast*|*chromecast*|*printer*|*print*|*dlna*|*upnp*|*smartthings*|\
          *homeassistant*|*miio*|*tuya*|*yeelight*|*sonos*|*spotify*) _v=protected ;;
          *)
            # Only a CACHED process: an app the user is looking at, listening to or that
            # runs a foreground service is never touched.
            _labs="$(_wl_lru_labels "$_p")"
            case "$_labs" in
              '') _v=report; [ -n "$_lru" ] && _v=cached ;;
              *)  _v=cached
                  for _l in $_labs; do case "$_l" in cch*|cac*) : ;; *) _v=in_use ;; esac; done ;;
            esac
            # Ten minutes of held multicast is well past discovery and into "something
            # forgot to release it". Below that, leave it alone.
            if [ "$_v" = cached ]; then
              _v=report
              if [ "$_act" = 1 ] && [ "$_mcs" -ge 600 ] && _has appops \
                 && appops set "$_p" WIFI_MULTICAST ignore >/dev/null 2>&1; then
                echo "$_p" >> "$D/multicast_restricted"
                echo "wakelock: $_p held multicast while cached - denied until ASB is uninstalled"
                _v=restricted
              fi
            fi ;;
        esac
      fi
      echo "$_p|$_v" >> "$MC.tmp"
    done
  done
  mv -f "$MC.tmp" "$MC" 2>/dev/null
  return 0
}

# --- rank apps by the CPU time they kept awake ----------------------------------------
#
# The parsers this replaces matched the formats of an older Android and found nothing on
# a current one. dumpsys power writes the holder as "(uid=10493 pid=20367)", not as a
# package in brackets, and batterystats writes "Wake lock u0a493 PedometerLib:tag: ..." -
# the old sed took "PedometerLib" for a package name. A capture with wakelock_action=1
# shows PedometerLib holding the CPU for minutes at a time, LONG-flagged, and the watcher
# never once acted or reported: every candidate failed the third-party check because it
# was a tag, not a package. A switch that does nothing while saying it is on is worse than
# no switch.
#
# Holders are now resolved by uid. Jobs run by the system on an app's behalf carry the
# app's uid in their WorkSource, so a JobScheduler lock is charged to the app that asked
# for it rather than to uid 1000. The map comes from `pm list packages -3 -U`, which also
# makes "third-party only" a property of the data instead of a substring test.
APPS="$D/wakelock_apps"

# Duration "1d 2h 3m 4s 5ms (..." -> seconds. Shared by every batterystats parse here.
_WL_DUR_AWK='
function dur(s,  n, t, i, v, tot) {
  tot = 0; n = split(s, t, " ")
  for (i = 1; i <= n; i++) {
    v = t[i]
    if (v ~ /^\(/) break
    if (v ~ /^[0-9]+d$/) tot += (v + 0) * 86400
    else if (v ~ /^[0-9]+h$/) tot += (v + 0) * 3600
    else if (v ~ /^[0-9]+m$/) tot += (v + 0) * 60
    else if (v ~ /^[0-9]+s$/) tot += v + 0
  }
  return tot
}'

# Adjustment labels of every process the package runs ("fg", "vis", "prcp", "cch+"...).
_wl_lru_labels() {
  [ -n "$_lru" ] || return 0
  printf '%s\n' "$_lru" | awk -v p="$1" '
    { for (i = 3; i <= NF; i++) if (index($i, ":" p "/") || index($i, ":" p ":")) { print $2; break } }'
}

_wl_pkgmap() {
  pm list packages -3 -U 2>/dev/null \
    | sed -n 's/^package:\([^ ]*\) uid:\([0-9]*\).*/\2 \1/p'
}

# uid -> seconds held since batterystats last reset (the last unplug), summed over tags.
_wl_bs_uid_secs() {
  dumpsys batterystats 2>/dev/null | awk "$_WL_DUR_AWK"'
    /^[ \t]*Wake lock u[0-9]+a[0-9]+ / {
      u = $3; sub(/^u/, "", u); split(u, p, "a")
      uid = p[1] * 100000 + 10000 + p[2]
      s = $0; sub(/^[ \t]*Wake lock [^ ]+ /, "", s)
      if (!match(s, /: [0-9]/)) next
      tag = substr(s, 1, RSTART - 1)
      d = dur(substr(s, RSTART + 2))
      k = uid SUBSEP tag
      if (d > best[k]) best[k] = d
    }
    END { for (k in best) { split(k, q, SUBSEP); sum[q[1]] += best[k] }
          for (u in sum) if (sum[u] > 0) print u, sum[u] }'
}

# uids holding a partial wakelock right now that the framework has flagged LONG (> 1 min).
_wl_power_long_uids() {
  dumpsys power 2>/dev/null | awk '
    /PARTIAL_WAKE_LOCK/ && / LONG / {
      uid = ""
      if (match($0, /\(uid=[0-9]+/)) uid = substr($0, RSTART + 5, RLENGTH - 5) + 0
      if (uid < 10000) {
        if (match($0, /WorkChain\{\([0-9]+/)) uid = substr($0, RSTART + 11, RLENGTH - 11) + 0
        else if (match($0, /WorkSource\{[0-9]+/)) uid = substr($0, RSTART + 11, RLENGTH - 11) + 0
      }
      if (uid >= 10000) print uid
    }' | sort -u
}

# 0 when the package has a process the user can see or hear (foreground, visible,
# perceptible - a playing player, a navigation app, a step counter with its notification).
# Those are never restricted, whatever they hold.
_wl_in_use() {
  [ -n "$_lru" ] || return 0
  _labs="$(_wl_lru_labels "$1")"
  [ -n "$_labs" ] || return 1
  for _l in $_labs; do
    case "$_l" in cch*|cac*|svcb|svc|prev|empt*) : ;; *) return 0 ;; esac
  done
  return 1
}

# Notification-bearing and tracking apps. An authenticator or a messenger that cannot wake
# is worse than a warm phone; a fitness tracker that cannot wake silently loses the user's
# steps, which is the very thing it is installed for.
_wl_protected() {
  # Package identifiers rarely contain the literal word `messaging`: WhatsApp, Telegram
  # and Signal are examples in real wake traces. These apps are notification-bearing, so
  # never auto-restrict them here; a user can still manage them directly in Android Settings.
  case "$1" in
    *authenticator*|*.auth.*|*.otp.*|*.mfa.*|*passkey*|\
    *dialer*|*.mms*|*messaging*|*whatsapp*|*telegram*|*signal*|*viber*|\
    *line*|*discord*|*slack*|*matrix*|*threema*|*wechat*|*kakao*|\
    *clock*|*alarm*|\
    *health*|*fitness*|*pedometer*|*fitbit*|*garmin*|*strava*|*wear*|*watch*|*band*) return 0 ;;
  esac
  return 1
}

# Writes $APPS: pkg|seconds|held_now(0/1)|verdict, worst first, at most eight.
# Always runs - the report names the holder whether or not anything is done about it.
# Acts only when $1 is 1 (switch on, long screen-off, awake share over the bar).
asb_wl_relax() {
  _act="${1:-0}"
  _has dumpsys || return 0
  _has pm || return 0
  [ -n "$_map" ] || return 0
  mkdir -p "$D" 2>/dev/null
  printf '%s\n' "$_map" > "$APPS.map" 2>/dev/null || return 0
  _rows="$( { _wl_bs_uid_secs; _wl_power_long_uids | sed 's/$/ L/'; } | awk '
    NR == FNR { pkg[$1] = (pkg[$1] ? pkg[$1] "," : "") $2; next }
    $2 == "L" { held[$1] = 1; next }
    { secs[$1] = $2 }
    END {
      for (u in secs) if (u in pkg) print secs[u], (held[u] ? 1 : 0), pkg[u]
      for (u in held) if ((u in pkg) && !(u in secs)) print 0, 1, pkg[u]
    }' "$APPS.map" - | sort -rn | head -8)"
  rm -f "$APPS.map" 2>/dev/null
  : > "$APPS.tmp" 2>/dev/null || return 0
  printf '%s\n' "$_rows" | while read -r _s _h _pl; do
    [ -n "$_pl" ] || continue
    # Two minutes since the last unplug, or a lock held past the framework's LONG mark
    # right now. Below that it is ordinary background chatter.
    [ "$_s" -ge 120 ] 2>/dev/null || [ "$_h" = 1 ] || continue
    for _p in $(printf '%s' "$_pl" | tr ',' ' '); do
      if grep -qxF "$_p" "$D/wakelock_restricted" 2>/dev/null; then
        _v=restricted
      elif _wl_protected "$_p"; then
        _v=protected
      elif _wl_in_use "$_p"; then
        _v=in_use
      elif [ "$_act" = 1 ]; then
        # forcestop is not used: it kills the app. Standby-bucket restricted tells Android
        # to stop honouring its background requests, which the platform already knows how
        # to undo. Recorded so uninstall can undo exactly what we did and nothing else.
        if am set-standby-bucket "$_p" restricted >/dev/null 2>&1; then
          echo "$_p" >> "$D/wakelock_restricted"
          echo "wakelock: $_p moved to restricted (held a wakelock during a long screen-off)"
          _v=restricted
        else
          _v=report
        fi
      else
        _v=report
      fi
      echo "$_p|$_s|$_h|$_v" >> "$APPS.tmp"
    done
  done
  mv -f "$APPS.tmp" "$APPS" 2>/dev/null
  return 0
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
  mkdir -p "$D" 2>/dev/null
  dumpsys batterystats 2>/dev/null \
    | sed -n 's/.*Kernel Wake lock \([^:]*\): \([0-9hms ]*\).*/\1|\2/p' \
    | head -12 > "$STATE" 2>/dev/null
  # Multicast is reported on its own line and is worth naming separately.
  dumpsys batterystats 2>/dev/null \
    | sed -n 's/.*Total WiFi Multicast wakelock time: \(.*\)/WiFi-Multicast|\1|0/p' \
    | head -1 >> "$STATE" 2>/dev/null
  [ -s "$STATE" ]
}

asb_wl_snapshot || asb_wl_snapshot_bs || :

# Whether this pass may act. The ranking below runs either way: measure always, report
# always, act only when switched on and the evidence is overwhelming.
_wl_may_act() {
  case "$(_cfg wakelock_action)" in
    1|on|true) : ;;
    *) return 1 ;;
  esac
  # Screen must have been off a while. A partial wakelock during active use is normal and
  # none of our business; the same lock two hours into the night is the reported problem.
  _awake="$(grep -m1 '^awake_pct_screenoff=' "$RSTATE" 2>/dev/null | cut -d= -f2)"
  _win="$(grep -m1 '^awake_window_min=' "$RSTATE" 2>/dev/null | cut -d= -f2)"
  case "${_awake:--1}" in ''|-1) return 1 ;; esac
  [ "${_win:-0}" -ge 45 ] 2>/dev/null || return 1
  # 25% stands: a safety contract pins it, and the reasoning behind that is sound.
  #
  # Field nights sit at 16-17% awake, so this watcher does not fire on them - I lowered
  # the bar to 15 and test_wakelock_watch_safety_contract caught it. The contract exists
  # because this path CHANGES APP STATE without asking: restricting a standby bucket is
  # visible to the user as an app that stopped syncing. A high bar means it only acts
  # when the evidence is overwhelming, and 16% of a night is not that.
  #
  # The right answer for those nights is naming the apps in the report so the user can
  # decide - which the ranking does - not lowering the bar at which the module acts.
  [ "${_awake:-0}" -ge 25 ] 2>/dev/null || return 1
  # And the screen must be off now, not merely earlier in the window.
  case "$(dumpsys deviceidle get screen 2>/dev/null)" in *true*|*on*) return 1 ;; esac
  return 0
}

_has pm && _map="$(_wl_pkgmap)" || _map=""
_lru="$(dumpsys activity lru 2>/dev/null)"
# Switched off: hand back what this watcher restricted.
#
# Turning wakelock_action off used to change nothing for apps already moved: they stayed
# in the restricted bucket, and multicast stayed denied, until ASB was uninstalled - so
# "off" in the WebUI did not mean what it said. The GPS trim already releases on off; this
# does the same, using the per-package records that uninstall reads.
case "$(_cfg wakelock_action)" in
  1|on|true) : ;;
  *)
    if [ -s "$D/wakelock_restricted" ] && _has am; then
      while IFS= read -r _rp; do
        [ -n "$_rp" ] && am set-standby-bucket "$_rp" active >/dev/null 2>&1
      done < "$D/wakelock_restricted"
      rm -f "$D/wakelock_restricted" 2>/dev/null
      echo "wakelock: off - apps ASB had restricted are released"
    fi
    if [ -s "$D/multicast_restricted" ] && _has appops; then
      while IFS= read -r _rp; do
        [ -n "$_rp" ] && appops set "$_rp" WIFI_MULTICAST allow >/dev/null 2>&1
      done < "$D/multicast_restricted"
      rm -f "$D/multicast_restricted" 2>/dev/null
    fi
    ;;
esac

if _wl_may_act; then
  asb_wl_relax 1
  asb_wl_relax_multicast 1
else
  asb_wl_relax 0
  asb_wl_relax_multicast 0
fi
exit 0
