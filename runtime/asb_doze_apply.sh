#!/system/bin/sh
# asb_doze_apply.sh - how quickly Android puts the phone into deep sleep when it is idle.
#
# WHY THIS ONE
#
# The full-day capture from an OP15 showed the idle phase sitting at 45.5% CPU-awake over
# 116 minutes, against the report's own target of under 5%. The wakelock ranking named only
# ordinary Android and GMS components - nothing the module could switch off. What CAN be
# moved is when the framework stops letting them run at all, and that is Doze.
#
# Doze is Android's own mechanism, so this is not a workaround: it just stops waiting so
# long before using it. Stock waits 30 minutes of screen-off before even entering INACTIVE,
# which on a phone picked up every few minutes is 30 minutes that never elapse.
#
#   doze_level = stock | moderate | aggressive
#
#   stock       the key is deleted and Android's own timings apply. Nothing is changed.
#   moderate    idle begins after 5 minutes instead of 30. The change most people want.
#   aggressive  2 minutes, and the sensing and locating windows are shortened too.
#
# THE COST, PLAINLY
#
# In Doze the system batches background work and holds most network access until the next
# maintenance window. That is exactly where the saving comes from, and it is also why chat
# messages can arrive late. Apps using high-priority FCM still break through - that is the
# path Android guarantees - but an app that polls on its own will be delayed. If messages
# arriving on time matters more than standby drain, stock is the right answer.
#
# Everything is one Settings.Global key, so leaving is deleting it: no residue.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"

[ -f "$MODDIR/runtime/asb_settings.sh" ] && . "$MODDIR/runtime/asb_settings.sh"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r'
}

_lvl="$(_cfg doze_level)"
case "$_lvl" in stock|moderate|aggressive|night) : ;; *) _lvl=stock ;; esac

# Only the timings that decide WHEN idle starts. Deliberately not touching the maintenance
# window lengths or the quota constants: those govern how much work gets done once idle,
# and shrinking them is how you turn "battery saving" into "my alarms stopped firing".
# "night" applies aggressive timings only inside the sleep window.
#
# Chosen from a real overnight capture: 9.5 hours screen-off at 0.52 %/h with awake 9%.
# The wakelock report named what was doing it - 21 alarms, the GMS scheduler, GOOGLE_C2DM,
# and eight *walarm*:com.android.systemui.aod.HIDE_TIME - none of which needs to run on
# time at 04:00. Applying aggressive doze around the clock would make messages arrive late
# during the day, which is a bad trade; applying it only while the user is asleep is not,
# because there is nobody waiting for the notification.
#
# Alarm clocks are unaffected: AlarmManager.setAlarmClock() is exempt from doze by design,
# and these constants do not touch that path.
case "$_lvl" in
  moderate)
    # Light doze is tuned too, not just deep.
    #
    # Deep doze only starts once the device has been STILL for inactive_to - a phone in a
    # pocket or on a moving desk never gets there, so on an ordinary day the only phase
    # that actually runs is light. Tuning deep alone means tuning the phase that rarely
    # happens, which is why the previous version of this had so little visible effect
    # outside a night on the nightstand.
    #
    # Light phase: enter sooner (30s -> 15s), longer idle windows, and a shorter
    # maintenance budget - maintenance is when apps are let out to run, and its length is
    # what the battery actually pays for.
    _c="inactive_to=300000,idle_after_inactive_to=300000,motion_inactive_to=300000"
    _c="${_c},light_after_inactive_to=15000,light_idle_to=20000,light_idle_factor=3.0"
    _c="${_c},light_idle_maintenance_max_budget=10000"
    ;;
  aggressive)
    _c="inactive_to=120000,idle_after_inactive_to=120000,motion_inactive_to=120000,sensing_to=60000,locating_to=15000"
    # Light phase pushed harder: in at 10s, 30s windows growing 4x, maintenance cut to
    # 5s. max_idle_to is left alone deliberately - capping how long a light-idle window
    # may grow is what keeps a long screen-off period from becoming one unbroken block
    # where nothing gets a chance to sync at all.
    _c="${_c},light_after_inactive_to=10000,light_idle_to=30000,light_idle_factor=4.0"
    _c="${_c},light_idle_maintenance_min_budget=1000,light_idle_maintenance_max_budget=5000"
    _c="${_c},light_pre_idle_to=2000"
    ;;
  night)
    # Prefer the LEARNED window over the fixed one.
    #
    # The governor already watches when the screen actually goes dark and comes back, and
    # writes the result to night_window.conf - on this device it learned 00:16 to 09:31
    # from four nights, against the 23:00-06:00 the config assumes. Using the static hours
    # here would have started the aggressive window 75 minutes before the user was asleep
    # and ended it three and a half hours before they woke: the wrong end of both.
    #
    # Minute granularity, because that is what the learner produces. Below the sample
    # threshold the learned value is not trusted yet and the configured hours stand.
    _nw="/data/adb/asb/night_window.conf"
    _min_s="$(_cfg night_quiet_auto_min_samples)"; case "$_min_s" in ''|*[!0-9]*) _min_s=3 ;; esac
    _auto="$(_cfg night_quiet_auto)"
    _s_min=""; _e_min=""
    if [ "$_auto" = "1" ] && [ -f "$_nw" ]; then
      _sm="$(grep -E '^sleep_min=' "$_nw" 2>/dev/null | head -1 | sed 's/.*=//')"
      _wm="$(grep -E '^wake_min='  "$_nw" 2>/dev/null | head -1 | sed 's/.*=//')"
      _ns="$(grep -E '^samples='   "$_nw" 2>/dev/null | head -1 | sed 's/.*=//')"
      case "$_sm$_wm$_ns" in *[!0-9]*|'') : ;; *)
        if [ "$_ns" -ge "$_min_s" ] 2>/dev/null; then
          # Same margins the governor uses on this window (asb_smart_defs.h): start 15
          # minutes late and end 20 minutes early. The learned time is an average, so the
          # real one moves either side of it by a few minutes on any given night - hugging
          # the average exactly means being wrong half the time, and being wrong at the
          # END means the phone is still in aggressive doze when the alarm-adjacent apps
          # need to catch up. Erring inward costs a few minutes of saving and cannot make
          # the user miss anything.
          _s_min=$(( (_sm + 15) % 1440 ))
          _e_min=$(( (_wm - 20 + 1440) % 1440 ))
        fi ;;
      esac
    fi
    if [ -z "$_s_min" ]; then
      _nq_s="$(_cfg night_quiet_hour_start)"; _nq_e="$(_cfg night_quiet_hour_end)"
      case "$_nq_s" in ''|*[!0-9]*) _nq_s=23 ;; esac
      case "$_nq_e" in ''|*[!0-9]*) _nq_e=6  ;; esac
      _s_min=$(( _nq_s * 60 )); _e_min=$(( _nq_e * 60 ))
    fi
    _now_min="$(date +%H:%M 2>/dev/null | awk -F: '{print ($1*60)+$2}')"
    case "$_now_min" in ''|*[!0-9]*) _now_min=720 ;; esac
    _in_night=0
    if [ "$_s_min" -gt "$_e_min" ] 2>/dev/null; then
      # window crosses midnight
      { [ "$_now_min" -ge "$_s_min" ] || [ "$_now_min" -lt "$_e_min" ]; } 2>/dev/null && _in_night=1
    else
      { [ "$_now_min" -ge "$_s_min" ] && [ "$_now_min" -lt "$_e_min" ]; } 2>/dev/null && _in_night=1
    fi
    if [ "$_in_night" = "1" ]; then
      _c="inactive_to=120000,idle_after_inactive_to=120000,motion_inactive_to=120000,sensing_to=60000,locating_to=15000"
      _c="${_c},light_after_inactive_to=10000,light_idle_to=30000,light_idle_factor=4.0"
      _c="${_c},light_idle_maintenance_min_budget=1000,light_idle_maintenance_max_budget=5000"
      _c="${_c},light_pre_idle_to=2000"
    else
      _c=""   # outside the window this behaves exactly like stock
    fi

    # Always-On Display, inside the window only.
    #
    # The wakelock report named *walarm*:com.android.systemui.aod.HIDE_TIME eight times -
    # AOD redrawing the clock on an RTC timer, all night, for nobody. It is the single
    # largest named wakeup source in that capture, and an OLED panel lighting pixels is
    # real current rather than a scheduling artefact.
    #
    # The user's own setting is captured before the first change and restored when the
    # window closes, so this borrows AOD for the night rather than turning it off. If they
    # never had it on, nothing happens at all.
    _aod_base="/data/adb/asb/aod_baseline"
    _aod_now="$(asb_set_get secure doze_always_on)"
    if [ "$_in_night" = "1" ]; then
      if [ "$_aod_now" = "1" ]; then
        [ -f "$_aod_base" ] || printf '1\n' > "$_aod_base" 2>/dev/null
        asb_set_put secure doze_always_on 0 >/dev/null 2>&1 \
          && echo "doze: AOD paused for the night window"
      fi
    elif [ -f "$_aod_base" ]; then
      asb_set_put secure doze_always_on "$(cat "$_aod_base" 2>/dev/null || echo 1)" >/dev/null 2>&1
      rm -f "$_aod_base" 2>/dev/null
      echo "doze: AOD restored"
    fi
    ;;
esac

# night outside its window is stock, and has to actually clear the constants rather than
# leaving last night's aggressive values in place all day.
# Whitelist trimming, aggressive and night only.
#
# Constants decide how soon Doze starts; the whitelist decides who ignores it. An app on
# the exemption list keeps its alarms and network through every idle window, so a phone
# can sit in deep doze all night while three exempted apps wake it anyway. This is the
# part Frosty gets at by freezing packages outright - we do not freeze anything, but we
# can stop apps that added THEMSELVES to the list from being exempt.
#
# System entries are never touched: the list also contains the dialer, the SMS app, the
# alarm clock and the root manager, and dropping those is how a module ends up being
# blamed for a missed alarm. Only user-installed packages, and only ones the user has not
# separately marked as unrestricted in Android's own battery settings.
asb_doze_trim_whitelist() {
  command -v dumpsys >/dev/null 2>&1 || return 0
  command -v pm >/dev/null 2>&1 || return 0
  _wl_file="/data/adb/asb/doze_whitelist_removed"
  mkdir -p /data/adb/asb 2>/dev/null
  # Third-party packages only: pm list packages -3 is the definition Android itself uses.
  _third="$(pm list packages -3 2>/dev/null | sed 's/^package://')"
  [ -n "$_third" ] || return 0
  for _p in $(dumpsys deviceidle whitelist 2>/dev/null \
              | grep -E '^user,' | cut -d, -f2); do
    case "$_third" in
      *"$_p"*) : ;;
      *) continue ;;   # not user-installed - leave it alone
    esac
    # A package name is [A-Za-z0-9_.] and nothing else. It reaches a shell command, and the
    # keep-list below is a user-editable file, so anything carrying a quote, a slash or a
    # space is refused outright rather than escaped.
    case "$_p" in
      *[!A-Za-z0-9_.]*|'') continue ;;
    esac
    # Apps the user chose to keep exempt, one package per line.
    #
    # "Remove every user app" is the right default and the wrong rule for everyone: an
    # alarm clock, a work chat or a health tracker are exactly the apps someone needs to
    # reach them late, and the only way to express that was to switch the tweak off
    # entirely. The editor in the WebUI writes this file.
    if [ -f /data/adb/asb/doze_whitelist_keep ] && \
       grep -qxF "$_p" /data/adb/asb/doze_whitelist_keep 2>/dev/null; then
      continue
    fi
    if dumpsys deviceidle whitelist "-$_p" >/dev/null 2>&1; then
      grep -qxF "$_p" "$_wl_file" 2>/dev/null || echo "$_p" >> "$_wl_file"
    fi
  done
  [ -s "$_wl_file" ] && echo "doze: $(wc -l < "$_wl_file") user app(s) removed from the exemption list"
}

# Put them all back. Called when the level returns to stock and from uninstall.sh - an
# exemption the user granted deliberately must survive the module being removed.
asb_doze_restore_whitelist() {
  _wl_file="/data/adb/asb/doze_whitelist_removed"
  [ -f "$_wl_file" ] || return 0
  command -v dumpsys >/dev/null 2>&1 || return 0
  while IFS= read -r _p; do
    [ -n "$_p" ] && dumpsys deviceidle whitelist "+$_p" >/dev/null 2>&1
  done < "$_wl_file"
  rm -f "$_wl_file" 2>/dev/null
  echo "doze: exemption list restored"
}

if [ "$_lvl" = "stock" ] || [ -z "$_c" ]; then
  if [ -n "$(asb_set_get global device_idle_constants)" ]; then
    asb_set_del global device_idle_constants
    asb_doze_restore_whitelist
    echo "doze: stock - Android's own timings, nothing set by ASB"
  else
    echo "doze: stock (nothing had been set)"
  fi
  exit 0
fi

# Trimming the exemption list is its own opt-in: constants are timings and reversible on
# the next boot, but removing an app's exemption changes when that app can reach the
# network, and a user who put it there had a reason.
case "$(_cfg doze_trim_whitelist)" in
  1|on|true)
    case "$_lvl" in
      aggressive|night) asb_doze_trim_whitelist ;;
      *)                asb_doze_restore_whitelist ;;
    esac ;;
  *) asb_doze_restore_whitelist ;;
esac

if asb_set_put global device_idle_constants "$_c"; then
  case "$_lvl" in
    moderate)   echo "doze: moderate - idle begins after 5 minutes of screen-off instead of 30" ;;
    aggressive) echo "doze: aggressive - idle after 2 minutes; background messages may arrive late" ;;
    night)      echo "doze: night - aggressive idle inside the sleep window only, stock during the day" ;;
  esac
else
  # Some ROMs guard this key. Say so rather than leaving the card looking applied - the
  # value not sticking is indistinguishable from success unless it is read back.
  echo "doze: this ROM refused the setting - Android's own timings still apply"
fi
exit 0
