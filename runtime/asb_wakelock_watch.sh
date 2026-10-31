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
        # Holding multicast although ASB denied it: the op was reset (app update, permission
        # reset, boot sweep). Re-assert instead of reporting a restriction that is not in
        # force (fix100, same failure as the fitness WAKE_LOCK limit).
        if _has appops && ! appops get "$_p" WIFI_MULTICAST 2>/dev/null | grep -q 'WIFI_MULTICAST: ignore'; then
          appops set "$_p" WIFI_MULTICAST ignore >/dev/null 2>&1 \
            && echo "wakelock: $_p had WIFI_MULTICAST reset by the system - denial re-applied"
        fi
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
    # A DISABLED lock is one PowerManager no longer honours (app-op, idle, standby): it
    # does not hold the CPU, so it is not a holder.
    /DISABLED/ { next }
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
    # Messengers, calls and mail whose package id carries none of the words above (fix136).
    # A field capture had Signal - org.thoughtcrime.securesms - moved to the restricted
    # bucket: "*signal*" never matched it, and a messenger lost timely delivery.
    org.thoughtcrime.securesms|im.molly.*|org.thunderdog.challegram|\
    com.tencent.mm|com.tencent.mobileqq|com.facebook.orca|com.facebook.mlite|\
    com.skype.*|com.microsoft.teams*|us.zoom.*|im.vector.*|eu.siacs.conversations|\
    chat.simplex.*|network.loki.messenger|com.wire|com.wire.*|com.vk.im|com.vkontakte.android|\
    ru.oneme.app|ru.ok.tamtam|com.icq.*|com.google.android.apps.tachyon|\
    com.google.android.gm|*mail*|*.voip|*.voip.*|\
    *waze*|*.maps|*.maps.*|*navigation*|*navigator*|*inputmethod*|*keyboard*|com.touchtype.*) return 0 ;;
    # fix141, from the package list of the OP15 capture 2830: Wickr and Truecaller are
    # installed there and matched nothing above. Telegram clients other than the official
    # one (exteraGram, AyuGram, Nekogram, Nagram, Cherrygram) carry no "telegram" in their id;
    # the wearable and headphone companions keep a watch or earbuds connected; Moovit is
    # navigation by another name.
    *messenger*|*wickr*|com.truecaller|com.truecaller.*|*callerid*|\
    com.radolyn.ayugram|tw.nekomimi.nekogram|xyz.nextalone.nagram|uz.unnarsx.cherrygram|\
    com.samsung.accessory.*|com.sony.songpal.*|com.tranzmate|*transit*) return 0 ;;
    # The network path itself (fix177): a VPN, a proxy or a DNS filter carries every other
    # app's traffic. In capture 3970 a Telegram WebSocket proxy (com.amurcanov.tgwsproxy) held
    # its service wakelock in 78% of the screen-off samples and was moved to the restricted
    # bucket early in the morning, under a report line promising that "a proxy, a VPN" is left
    # alone. Restricting one saves its own few minutes and cuts the messenger behind it off.
    *vpn*|*proxy*|*tunnel*|*wireguard*|*v2ray*|*xray*|*clash*|*shadowsocks*|*shadowrocket*|\
    *singbox*|*sing.box*|*nekobox*|*hiddify*|*amnezia*|*outline*|*orbot*|org.torproject.*|\
    *adguard*|*nextdns*|*rethinkdns*|*blokada*|*netguard*|*dnsfilter*|*byedpi*|*zapret*|\
    *psiphon*|*lantern*|*mullvad*|*windscribe*|com.cloudflare.onedotonedotone|\
    io.nekohasekai.*|moe.nb4a) return 0 ;;
  esac
  return 1
}

# A foreground service running right now (fix177). The lru label is read once per pass and
# OxygenOS demotes a service process to "cached" in the middle of the night; the service
# record says what the app is actually doing. Asked only for an app about to be restricted.
_wl_fgs_running() {
  _has dumpsys || return 1
  dumpsys activity services "$1" 2>/dev/null | grep -q 'isForeground=true'
}

# Apps Android itself exempts from battery optimisation (fix136): the user's own "not
# optimised" list and the system's. A messenger is put there for exactly this reason - Signal
# asks for it at setup - and a watcher that restricts it from the side undoes the user's
# choice. Read once per pass, and only when something might be restricted or released.
_WL_DOZE_EX=""
_wl_doze_exempt_load() {
  _WL_DOZE_EX="$(cat "$D/doze_whitelist_removed" "$D/doze_whitelist_keep" 2>/dev/null | grep -E '^[A-Za-z0-9_.]+$')"
  _has dumpsys || return 0
  _WL_DOZE_EX="${_WL_DOZE_EX}
$(dumpsys deviceidle whitelist 2>/dev/null \
                 | sed -n 's/^[[:space:]]*[a-z-]*,\([A-Za-z0-9_.]*\),[0-9]*.*/\1/p')"
}
_wl_doze_exempt() {
  [ -n "$_WL_DOZE_EX" ] || return 1
  printf '%s\n' "$_WL_DOZE_EX" | grep -qxF "$1"
}

# Used today, by Android's own standby bucket: 5 exempted, 10 active, 20 working_set.
_wl_used_today() {
  _has am || return 1
  _bk="$(am get-standby-bucket "$1" 2>/dev/null | tr -dc '0-9')"
  case "$_bk" in 5|10|20) return 0 ;; esac
  return 1
}

# Restrictions made under the looser pre-fix137 rule (two minutes of any lock, used today or
# not) are handed back once; an app that still meets the stricter rule is restricted again
# by a later pass, on its own evidence.
_wl_rules_migrate() {
  _mk="$D/wakelock_rules_v137"
  [ -f "$_mk" ] && return 0
  if [ -s "$D/wakelock_restricted" ] && _has am; then
    while IFS= read -r _rp; do
      [ -n "$_rp" ] && am set-standby-bucket "$_rp" active >/dev/null 2>&1 \
        && echo "wakelock: $_rp released - restricted under the earlier, looser rule"
    done < "$D/wakelock_restricted"
    rm -f "$D/wakelock_restricted" 2>/dev/null
  fi
  mkdir -p "$D" 2>/dev/null
  true > "$_mk" 2>/dev/null
}

# Hand back what an earlier pass restricted but would not restrict today (fix136): a
# messenger the old name list missed, or an app the user has since exempted.
_wl_release_protected() {
  [ -s "$D/wakelock_restricted" ] || return 0
  _has am || return 0
  true > "$D/wakelock_restricted.tmp" 2>/dev/null || return 0
  while IFS= read -r _rp; do
    [ -n "$_rp" ] || continue
    if _wl_protected "$_rp" || _wl_doze_exempt "$_rp" || _wl_fgs_running "$_rp"; then
      am set-standby-bucket "$_rp" active >/dev/null 2>&1
      echo "wakelock: $_rp released from the restricted bucket - messengers, VPNs/proxies, apps with a foreground service and apps exempt from battery optimisation are never restricted"
    else
      echo "$_rp" >> "$D/wakelock_restricted.tmp"
    fi
  done < "$D/wakelock_restricted"
  if [ -s "$D/wakelock_restricted.tmp" ]; then
    mv -f "$D/wakelock_restricted.tmp" "$D/wakelock_restricted" 2>/dev/null
  else
    rm -f "$D/wakelock_restricted.tmp" "$D/wakelock_restricted" 2>/dev/null
  fi
}

# Step counters and workout trackers - the narrow subset of the protected list that
# wakelock_fitness=limit may act on. Watch and band companions are NOT in it: a companion
# that cannot wake stops forwarding notifications to the wrist, which is a different and
# worse loss than a coarser step timeline.
_wl_fitness() {
  case "$1" in
    *health*|*fitness*|*pedometer*|*stepcounter*|*fitbit*|*garmin*|*strava*) return 0 ;;
    # Step and run trackers whose ids carry none of the words above (fix177).
    *steptrack*|*runtastic*|*runkeeper*|com.nike.plusgps|cc.pacer.*|com.corusen.*|\
    *komoot*|*sportstracker*) return 0 ;;
  esac
  return 1
}

# wakelock_fitness: protect (default) | limit.
#
# Samsung Health's PedometerLib was the largest single night holder in three captures -
# minutes of CPU held awake, every night. It is protected above for a good reason: a
# tracker that cannot wake loses what it was installed for. But the choice belongs to the
# user, and someone who does not use step counting should be able to say so.
#
# limit = app-op WAKE_LOCK ignore for the installed step/fitness apps (see the pass at the
# bottom of this file). Android then treats its wakelocks as released: the app
# keeps running whenever the phone is awake for any other reason, it just cannot keep the
# CPU up by itself. The step sensor counts in the sensor hub regardless, so the daily total
# usually survives; what can suffer is the minute-by-minute timeline, and a workout
# recorded with the screen off. The mode the app had before is recorded and given back on
# protect or uninstall - an app the user limited themselves stays as they left it.
FIT="$D/wakelock_fitness_limited"
FIT_IGN="$D/wakelock_fitness_ignored"
_wl_fit_mode() { _cfg wakelock_fitness; }
# The package's own mode. appops get prints "Uid mode: WAKE_LOCK: <m>" FIRST when a per-uid
# mode is set (fix177), and this read whichever WAKE_LOCK line came first: with a uid line a
# freshly set package "ignore" read back as the uid's mode, the limit counted as not accepted
# and no ledger was written - one way the owner's Samsung Health and Renpho ended up in no
# ledger with limit chosen, and the WebUI read "no fitness apps".
_wl_fit_orig() {
  _o="$(appops get "$1" WAKE_LOCK 2>/dev/null | grep -v 'Uid mode' \
        | sed -n 's/.*WAKE_LOCK: \([a-z_]*\).*/\1/p' | head -1)"
  printf '%s' "${_o:-default}"
}
_wl_fit_uidmode() {
  appops get "$1" WAKE_LOCK 2>/dev/null | sed -n 's/.*Uid mode: WAKE_LOCK: \([a-z_]*\).*/\1/p' | head -1
}
# What Android goes by: AppOpsService checks a uid mode before the package's own.
_wl_fit_eff() {
  _fu="$(_wl_fit_uidmode "$1")"
  case "$_fu" in ''|default) _wl_fit_orig "$1" ;; *) printf '%s' "$_fu" ;; esac
}
# A uid mode that would override the package limit is set too, and recorded on its own
# ledger (pkg|mode) so protect and uninstall hand back exactly that.
FIT_UID="$D/wakelock_fitness_uidmode"
FIT_REF="$D/wakelock_fitness_refused"
_wl_fit_uid_limit() {
  _fu="$(_wl_fit_uidmode "$1")"
  case "$_fu" in ''|default|ignore) return 0 ;; esac
  appops set --uid "$1" WAKE_LOCK ignore >/dev/null 2>&1 || return 0
  grep -q "^$1|" "$FIT_UID" 2>/dev/null || echo "$1|$_fu" >> "$FIT_UID"
}
_wl_fit_uid_release() {
  [ -s "$FIT_UID" ] || return 0
  _fl="$(grep "^$1|" "$FIT_UID" 2>/dev/null | head -1)"
  [ -n "$_fl" ] || return 0
  appops set --uid "$1" WAKE_LOCK "${_fl#*\|}" >/dev/null 2>&1
  grep -v "^$1|" "$FIT_UID" > "$FIT_UID.tmp" 2>/dev/null
  if [ -s "$FIT_UID.tmp" ]; then mv -f "$FIT_UID.tmp" "$FIT_UID"; else rm -f "$FIT_UID.tmp" "$FIT_UID"; fi
}
_wl_fit_limit() {
  _has appops || return 1
  # Recorded is not the same as in force (fix100). An app update, a ROM "reset app
  # permissions" pass or OPlus' own boot-time app-op sweep puts WAKE_LOCK back to default,
  # and this returned 0 on the record alone - so the op stayed lapsed for good while the
  # report kept saying "limited". An OP15 asbdiag showed exactly that: "now: ?" (no
  # WAKE_LOCK entry at all) for both fitness apps. Re-assert, keeping the ORIGINAL mode on
  # record - the one to hand back is still what the app had before ASB, not "default".
  if grep -q "^$1|" "$FIT" 2>/dev/null; then
    [ "$(_wl_fit_eff "$1")" = ignore ] && return 0
    if [ "$(_wl_fit_orig "$1")" != ignore ]; then
      appops set "$1" WAKE_LOCK ignore >/dev/null 2>&1 || return 1
    fi
    _wl_fit_uid_limit "$1"
    [ "$(_wl_fit_eff "$1")" = ignore ] || return 1
    # Any "Android does not enforce it" verdict was drawn while the op was not set.
    if [ -s "$FIT_IGN" ]; then
      grep -vxF "$1" "$FIT_IGN" > "$FIT_IGN.tmp" 2>/dev/null
      mv -f "$FIT_IGN.tmp" "$FIT_IGN" 2>/dev/null
    fi
    echo "wakelock: $1 had WAKE_LOCK reset by the system - limit re-applied"
    # Marked for this pass's verdict (the proactive pass runs in a pipeline subshell, so a
    # variable would not reach asb_wl_relax).
    echo "$1" >> "$FIT.reapplied" 2>/dev/null
    return 0
  fi
  _orig="$(_wl_fit_orig "$1")"
  # Already ignored by someone else (the user, another tool): not ours to record or undo.
  [ "$(_wl_fit_eff "$1")" = ignore ] && return 1
  if [ "$_orig" != ignore ]; then
    appops set "$1" WAKE_LOCK ignore >/dev/null 2>&1 || return 1
  fi
  _wl_fit_uid_limit "$1"
  if [ "$(_wl_fit_eff "$1")" != ignore ]; then
    # Not accepted: put back what was changed, so nothing unrecorded is left behind, and
    # say so - the WebUI badge reads it instead of waiting on "pending" for good (fix177).
    [ "$_orig" != ignore ] && appops set "$1" WAKE_LOCK "$_orig" >/dev/null 2>&1
    _wl_fit_uid_release "$1"
    grep -qxF "$1" "$FIT_REF" 2>/dev/null || echo "$1" >> "$FIT_REF"
    echo "wakelock: $1 - the WAKE_LOCK app-op did not take (reads back $(_wl_fit_eff "$1")); left as it was"
    return 1
  fi
  if [ -s "$FIT_REF" ]; then
    grep -vxF "$1" "$FIT_REF" > "$FIT_REF.tmp" 2>/dev/null
    if [ -s "$FIT_REF.tmp" ]; then mv -f "$FIT_REF.tmp" "$FIT_REF"; else rm -f "$FIT_REF.tmp" "$FIT_REF"; fi
  fi
  echo "$1|$_orig" >> "$FIT"
  echo "wakelock: $1 may no longer hold the CPU awake (wakelock_fitness=limit)"
  return 0
}
_wl_fit_release() {
  rm -f "$FIT_REF" 2>/dev/null
  [ -s "$FIT" ] || return 0
  _has appops || return 0
  while IFS='|' read -r _fp _fo; do
    [ -n "$_fp" ] || continue
    appops set "$_fp" WAKE_LOCK "${_fo:-default}" >/dev/null 2>&1
    _wl_fit_uid_release "$_fp"
  done < "$FIT"
  rm -f "$FIT" "$FIT_IGN" "$FIT_UID" "$FIT_REF" 2>/dev/null
  echo "wakelock: fitness apps may hold wakelocks again (wakelock_fitness=protect)"
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
  _fitmode="$(_wl_fit_mode)"
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
  true > "$APPS.tmp" 2>/dev/null || return 0
  printf '%s\n' "$_rows" | while read -r _s _h _pl; do
    [ -n "$_pl" ] || continue
    # Two minutes since the last unplug, or a lock held past the framework's LONG mark
    # right now. Below that it is ordinary background chatter.
    [ "$_s" -ge 120 ] 2>/dev/null || [ "$_h" = 1 ] || continue
    for _p in $(printf '%s' "$_pl" | tr ',' ' '); do
      if [ -n "$(_wl_man_line "$_p")" ]; then
        # fix276: the explicit list owns this app's WAKE_LOCK op; do not additionally move
        # its standby bucket through the generic automatic policy. Read-back stays decisive.
        if [ "$(_wl_fit_eff "$_p")" = ignore ]; then
          _v=manual
        else
          _wl_man_apply "$_p" >/dev/null 2>&1
          [ "$(_wl_fit_eff "$_p")" = ignore ] && _v=manual || _v=manual_lapsed
        fi
      elif grep -qxF "$_p" "$D/wakelock_restricted" 2>/dev/null; then
        _v=restricted
      elif grep -q "^$_p|" "$FIT" 2>/dev/null && { [ "$_fitmode" != limit ] || _wl_fit_limit "$_p" >/dev/null; }; then
        # (_wl_fit_limit above re-asserts a lapsed op before any verdict is drawn: a lock
        # held while the op had been reset says nothing about enforcement.)
        # Verified, not assumed. A lock PowerManager still honours (LONG, not DISABLED) on a
        # later pass than the one that set the op means this Android does not enforce the
        # WAKE_LOCK app-op - a field capture had Samsung Health holding PedometerLib for
        # 17 minutes, not DISABLED, hours after "limited". Say so instead of claiming it.
        if grep -qxF "$_p" "$FIT.reapplied" 2>/dev/null; then
          # Just re-asserted: whatever it held, it held without the op in force.
          _v=limited
        elif grep -qxF "$_p" "$FIT_IGN" 2>/dev/null; then
          _v=limit_ignored
        elif [ "$_h" = 1 ]; then
          echo "$_p" >> "$FIT_IGN"
          echo "wakelock: $_p still holds the CPU although WAKE_LOCK is ignored - this Android does not enforce the app-op"
          _v=limit_ignored
        else
          _v=limited
        fi
      elif [ "$_fitmode" = limit ] && _wl_fitness "$_p" && _wl_fit_limit "$_p"; then
        # The user's explicit choice for this class of app, so it does not wait for the
        # awake-share gate the generic path needs: that gate exists because the generic
        # path acts on apps nobody named.
        _v=limited
      elif _wl_protected "$_p"; then
        _v=protected
      elif _wl_doze_exempt "$_p"; then
        _v=protected
      elif _wl_in_use "$_p"; then
        _v=in_use
      elif [ "$_act" = 1 ] && [ "$_s" -lt 600 ] 2>/dev/null && [ "$_h" != 1 ]; then
        # Acting needs a real hold (fix137): ten minutes since the last unplug, or a lock
        # held past the LONG mark right now. Two minutes is where naming starts, not where
        # restricting does - an OP15 night restricted com.anthropic.claude for one 3 m 27 s
        # WorkManager job, while the awake share that opened the gate was Bluetooth audio.
        # JobScheduler already caps a job at ten minutes and defers it in Doze.
        _v=report
      elif [ "$_act" = 1 ] && _wl_used_today "$_p"; then
        # Android's own usage verdict (fix137): active (10) and working_set (20) mean the
        # user opened it today. Background trimming already leaves those alone for the
        # same reason - restricting an app someone uses daily delays its notifications for
        # a battery saving Android would make by itself once it really goes unused.
        _v=used_today
      elif [ "$_act" = 1 ] && _wl_fgs_running "$_p"; then
        # A foreground service is work the user can see in the notification shade - the
        # report has always said those are left alone (fix177).
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

# --- explicit per-app WAKE_LOCK control (fix276) --------------------------------------
#
# The automatic watcher above remains conservative. This separate, user-named list is the
# deliberate exception: only a user-installed package, only Android's WAKE_LOCK app-op, and
# only after the WebUI's warning/confirmation. Kernel wakeup sources and system packages are
# never writable targets. The ledger stores BOTH original modes before the first change;
# read-back, not the ledger, decides whether a limit is actually in force.
MAN="$D/wakelock_manual"
_wl_man_pkgok() {
  case "$1" in ''|*[!A-Za-z0-9_.]*|.*|*..*) return 1 ;; esac
  return 0
}
_wl_man_installed() {
  _wl_man_pkgok "$1" || return 1
  _has pm || return 1
  pm list packages -3 2>/dev/null | sed -n 's/^package:\([^ ]*\).*/\1/p' | grep -qxF "$1"
}
_wl_man_line() { awk -F'|' -v p="$1" '$1 == p { print; exit }' "$MAN" 2>/dev/null; }
_wl_man_drop() {
  [ -s "$MAN" ] || return 0
  awk -F'|' -v p="$1" '$1 != p' "$MAN" > "$MAN.tmp" 2>/dev/null || return 1
  if [ -s "$MAN.tmp" ]; then mv -f "$MAN.tmp" "$MAN"; else rm -f "$MAN.tmp" "$MAN"; fi
}
# Apply an existing ledger entry without replacing its original modes. This is used by the
# existing boot and screen-off passes, not by a new polling worker.
_wl_man_apply() {
  _ml="$(_wl_man_line "$1")"
  [ -n "$_ml" ] || return 1
  _has appops || return 1
  [ "$(_wl_fit_eff "$1")" = ignore ] && return 0
  _mo="$(printf '%s' "$_ml" | cut -d'|' -f2)"
  _mu="$(printf '%s' "$_ml" | cut -d'|' -f3)"
  [ "$(_wl_fit_orig "$1")" = ignore ] || appops set "$1" WAKE_LOCK ignore >/dev/null 2>&1 || return 1
  case "${_mu:-default}" in ''|default) : ;; *) appops set --uid "$1" WAKE_LOCK ignore >/dev/null 2>&1 || : ;; esac
  [ "$(_wl_fit_eff "$1")" = ignore ]
}
_wl_man_limit() {
  _has appops || { printf 'result=unavailable\n'; return 1; }
  _wl_man_installed "$1" || { printf 'result=not_user_app\n'; return 1; }
  if [ -n "$(_wl_man_line "$1")" ]; then
    if _wl_man_apply "$1"; then printf 'result=limited\neffective=ignore\n'; return 0; fi
    printf 'result=not_enforced\neffective=%s\n' "$(_wl_fit_eff "$1")"; return 1
  fi
  # A restriction made by the user or another tool is not ours to record or later undo.
  [ "$(_wl_fit_eff "$1")" = ignore ] || {
    _mo="$(_wl_fit_orig "$1")"; _mu="$(_wl_fit_uidmode "$1")"; _mu="${_mu:-default}"
    [ "$_mo" = ignore ] || appops set "$1" WAKE_LOCK ignore >/dev/null 2>&1
    case "$_mu" in default) : ;; *) appops set --uid "$1" WAKE_LOCK ignore >/dev/null 2>&1 || : ;; esac
    if [ "$(_wl_fit_eff "$1")" = ignore ]; then
      mkdir -p "$D" 2>/dev/null
      printf '%s|%s|%s\n' "$1" "${_mo:-default}" "$_mu" >> "$MAN"
      printf 'result=limited\neffective=ignore\n'; return 0
    fi
    # Refusal is rolled back immediately; no unrecorded half-change is left behind.
    appops set "$1" WAKE_LOCK "${_mo:-default}" >/dev/null 2>&1
    [ "$_mu" = default ] || appops set --uid "$1" WAKE_LOCK "$_mu" >/dev/null 2>&1
  }
  printf 'result=not_enforced\neffective=%s\n' "$(_wl_fit_eff "$1")"
  return 1
}
_wl_man_restore() {
  _ml="$(_wl_man_line "$1")"
  [ -n "$_ml" ] || { printf 'result=not_selected\n'; return 1; }
  _has appops || { printf 'result=unavailable\n'; return 1; }
  _mo="$(printf '%s' "$_ml" | cut -d'|' -f2)"; _mu="$(printf '%s' "$_ml" | cut -d'|' -f3)"
  appops set "$1" WAKE_LOCK "${_mo:-default}" >/dev/null 2>&1 || { printf 'result=restore_failed\n'; return 1; }
  [ "${_mu:-default}" = default ] || appops set --uid "$1" WAKE_LOCK "$_mu" >/dev/null 2>&1
  # Verify the individual modes too: a stale uid override must not survive a "Restore" tap.
  _rp="$(_wl_fit_orig "$1")"; _ru="$(_wl_fit_uidmode "$1")"; _ru="${_ru:-default}"
  if [ "$_rp" = "${_mo:-default}" ] && [ "$_ru" = "${_mu:-default}" ]; then
    _wl_man_drop "$1" && printf 'result=restored\neffective=%s\n' "$(_wl_fit_eff "$1")" && return 0
  fi
  printf 'result=restore_failed\neffective=%s\n' "$(_wl_fit_eff "$1")"
  return 1
}
_wl_man_reapply() {
  [ -s "$MAN" ] || return 0
  while IFS='|' read -r _mp _mo _mu; do
    [ -n "$_mp" ] && _wl_man_installed "$_mp" && _wl_man_apply "$_mp" >/dev/null 2>&1 || :
  done < "$MAN"
}
# Read-only ranked candidates. Battery-stats durations are cumulative since the last unplug,
# not a current-capture energy attribution; the WebUI labels that basis explicitly.
_wl_man_scan() {
  _has dumpsys && _has pm || return 1
  _map="$(_wl_pkgmap)"; [ -n "$_map" ] || return 1
  { _wl_bs_uid_secs; _wl_power_long_uids | sed 's/$/ L/'; } | awk -v map="$_map" '
    BEGIN { n=split(map,a,"\n"); for(i=1;i<=n;i++) if(split(a[i],b," ")==2)
              pkg[b[1]]=(pkg[b[1]] ? pkg[b[1]] "," : "") b[2] }
    $2 == "L" { held[$1]=1; next }
    { secs[$1]=$2 }
    END { for(u in secs) if((u in pkg) && secs[u]>=30) {
              n=split(pkg[u],pa,","); for(i=1;i<=n;i++) print pa[i] "|" secs[u] "|" (held[u]?1:0) }
          for(u in held) if((u in pkg) && !(u in secs)) {
              n=split(pkg[u],pa,","); for(i=1;i<=n;i++) print pa[i] "|0|1" } }' \
    | sort -t'|' -k2,2nr | head -16
}
_wl_man_status() {
  _rows="$(_wl_man_scan)"; _scan=$?
  printf 'version=1\nscan=%s\n' "$([ "$_scan" -eq 0 ] && echo ok || echo unavailable)"
  _n=0; [ -s "$MAN" ] && _n="$(grep -c '|' "$MAN" 2>/dev/null)"
  printf 'selected=%s\n' "${_n:-0}"
  # Candidate rows plus selected apps that have no current batterystats row.
  { printf '%s\n' "$_rows"; [ -s "$MAN" ] && cut -d'|' -f1 "$MAN" | sed 's/$/|0|0/'; } \
    | awk -F'|' 'NF>=3 && $1!="" && !seen[$1]++ { print $1 "|" $2 "|" $3 }'
}
if [ "${1:-}" = manual-status ]; then
  _wl_man_status | while IFS='|' read -r _a _b _c; do
    case "$_a" in
      version=*|scan=*|selected=*) printf '%s\n' "$_a" ;;
      ''|*[!A-Za-z0-9_.]*) : ;;
      *) _sel=0; [ -n "$(_wl_man_line "$_a")" ] && _sel=1
         _eff=unknown; _has appops && _eff="$(_wl_fit_eff "$_a")"
         _prot=0; _wl_protected "$_a" && _prot=1
         printf 'row|%s|%s|%s|%s|%s|%s\n' "$_a" "${_b:-0}" "${_c:-0}" "$_sel" "${_eff:-unknown}" "$_prot" ;;
    esac
  done
  exit 0
fi
if [ "${1:-}" = manual-set ]; then
  case "${3:-}" in
    ignore) _wl_man_limit "${2:-}" ;;
    restore) _wl_man_restore "${2:-}" ;;
    *) printf 'result=bad_request\n'; exit 2 ;;
  esac
  exit $?
fi
if [ "${1:-}" = manual-reapply ]; then _wl_man_reapply; exit 0; fi

# fitness-status (fix177): what the WebUI badge needs, read-only. Installed step/fitness apps
# (third-party: the class wakelock_fitness acts on), how many ASB recorded as limited, how
# many have the limit in force with no record (set before - by the user, another tool or an
# earlier install), how many this ROM was seen ignoring, how many refused the op. The badge
# counted only the ledger lines and read "no fitness apps" on a phone with two whenever the
# ledger was empty, whatever the reason.
if [ "${1:-}" = fitness-status ]; then
  _fs_n=0; _fs_f=0; _fs_names=""
  if _has pm; then
    for _fs_p in $(pm list packages -3 2>/dev/null | sed -n 's/^package://p'); do
      _wl_fitness "$_fs_p" || continue
      _fs_n=$((_fs_n + 1)); _fs_names="${_fs_names}${_fs_names:+,}$_fs_p"
      # Recorded apps are counted from the ledger; appops (a Java client each) only for the
      # others - the case this exists for, an op already in force with no record.
      grep -q "^$_fs_p|" "$FIT" 2>/dev/null && continue
      _has appops && [ "$(_wl_fit_eff "$_fs_p")" = ignore ] && _fs_f=$((_fs_f + 1))
    done
  fi
  _fs_l=0; _fs_i=0; _fs_r=0
  [ -s "$FIT" ] && _fs_l="$(grep -c '|' "$FIT" 2>/dev/null)"
  [ -s "$FIT_IGN" ] && _fs_i="$(grep -c . "$FIT_IGN" 2>/dev/null)"
  [ -s "$FIT_REF" ] && _fs_r="$(grep -c . "$FIT_REF" 2>/dev/null)"
  printf 'installed=%s\npreset=%s\nlimited=%s\nignored=%s\nrefused=%s\nnames=%s\n' \
    "$_fs_n" "$_fs_f" "${_fs_l:-0}" "${_fs_i:-0}" "${_fs_r:-0}" "$_fs_names"
  exit 0
fi

# fitness: put the user's fitness limit back and nothing else (fix143).
#
# OPlus' boot-time sweep resets the WAKE_LOCK app-op, and the hourly screen-off pass was the
# first thing to set it again - an hour or more after every reboot with the limit off. Capture
# 26147 began three minutes after a reboot, asbdiag read "limit lapsed", and PedometerLib held
# the CPU up to 21 minutes at a stretch with the screen off. service.sh runs this on its first
# two ticks after boot. No measurement, no batterystats: pm and appops for the fitness apps.
if [ "${1:-}" = fitness ]; then
  [ "$(_wl_fit_mode)" = limit ] || exit 0
  _has pm || exit 0
  _map="$(_wl_pkgmap)"
  [ -n "$_map" ] || exit 0
  rm -f "$FIT.reapplied" 2>/dev/null
  printf '%s\n' "$_map" | while read -r _fu _fp; do
    [ -n "$_fp" ] && _wl_fitness "$_fp" && _wl_fit_limit "$_fp" >/dev/null
  done
  # A verdict "this Android ignores the limit" drawn while the op had lapsed says nothing:
  # the report shows "limited" until the next full pass checks it again with the op in force.
  if [ -s "$FIT.reapplied" ] && [ -s "$APPS" ]; then
    awk -F'|' -v OFS='|' 'NR == FNR { r[$0] = 1; next } ($1 in r) && $4 == "limit_ignored" { $4 = "limited" } { print }' \
      "$FIT.reapplied" "$APPS" > "$APPS.fit" 2>/dev/null && mv -f "$APPS.fit" "$APPS" 2>/dev/null
    rm -f "$APPS.fit" 2>/dev/null
  fi
  rm -f "$FIT.reapplied" 2>/dev/null
  exit 0
fi

# A manual choice is independent of the automatic wakelock_action gate. Re-assert it after
# ROM permission sweeps on this existing pass; never create another worker for it.
_wl_man_reapply

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

# wakelock_fitness is independent of wakelock_action: either may be on without the other.
#
# limit acts on every installed step/fitness app, not only on one caught holding a lock.
# The first version waited to SEE the hold - 2+ minutes in batterystats or LONG in
# dumpsys power at the moment the hourly screen-off pass ran. On the OP15 the batterystats
# dump carries no per-app durations, and the pedometer's 35-minute hold that night ended
# before the pass came round, so nothing was ever limited although the user had chosen it.
# The choice is about a class of app the user named, so it applies to that class.
rm -f "$FIT.reapplied" 2>/dev/null
case "$(_wl_fit_mode)" in
  limit)
    if [ -n "$_map" ]; then
      printf '%s\n' "$_map" | while read -r _fu _fp; do
        [ -n "$_fp" ] && _wl_fitness "$_fp" && _wl_fit_limit "$_fp" >/dev/null
      done
    fi
    ;;
  *) _wl_fit_release ;;
esac

case "$(_cfg wakelock_action)" in 1|on|true) _wl_rules_migrate ;; esac
if _wl_may_act; then
  _wl_doze_exempt_load
  _wl_release_protected
  asb_wl_relax 1
  asb_wl_relax_multicast 1
else
  # Not acting this pass, but a wrong restriction from an earlier one is still released.
  if [ -s "$D/wakelock_restricted" ]; then
    _wl_doze_exempt_load
    _wl_release_protected
  fi
  asb_wl_relax 0
  asb_wl_relax_multicast 0
fi
rm -f "$FIT.reapplied" 2>/dev/null
exit 0
