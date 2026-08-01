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
    _c="inactive_to=300000,idle_after_inactive_to=300000,motion_inactive_to=300000"
    ;;
  aggressive)
    _c="inactive_to=120000,idle_after_inactive_to=120000,motion_inactive_to=120000,sensing_to=60000,locating_to=15000"
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
if [ "$_lvl" = "stock" ] || [ -z "$_c" ]; then
  if [ -n "$(asb_set_get global device_idle_constants)" ]; then
    asb_set_del global device_idle_constants
    echo "doze: stock - Android's own timings, nothing set by ASB"
  else
    echo "doze: stock (nothing had been set)"
  fi
  exit 0
fi

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
