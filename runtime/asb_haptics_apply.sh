#!/system/bin/sh
# asb_haptics_apply.sh - vibration strength, through the path this device actually uses.
#
# What the probe found on a OnePlus 15, and why this script looks the way it does:
#
# /sys/class/leds/vibrator/ does not exist /sys/class/timed_output/ does not exist
# /sys/class/qcom-haptics/ not present either vendor.oplus.vibrator running, with
# ro.oplus.haptic.lra_* properties
#
# So there is no sysfs node to write.
#
# The ro.oplus.haptic.lra_* properties are read-only calibration data written at first boot -
# the LRA's measured resonance range for THIS unit.
# They are not intensity controls, and overriding them means telling the driver to drive the
# motor off its resonant frequency: quieter and rougher, not stronger, with real wear on the
# actuator.
#
# What is left, and what actually works, is the framework layer.
# On this device most read "null", which means "never set, use the default" - so there is room
# to raise them.
#
# Scale: 0 = off, 1 = light, 2 = medium (Android's default), 3 = strong.

# Settings wrapper: falls back to the content provider where the `settings` command
# cannot reach the service. On a OnePlus 15R every call returned "Failure calling
# service settings" while exiting 0, so writes looked successful and reads returned the
# error text as a value - this makes those calls work without changing any of them.
[ -f "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh" ] && \
  . "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh"

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
BASE="/data/adb/asb/haptics_baseline.conf"
[ -f "$CONF" ] || { echo "config not found: $CONF"; exit 1; }

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]'
}

_lvl="$(_cfg haptic_strength)"
_lvl_touch="$(_cfg haptic_touch_strength)"

# OnePlus keeps the real control in its OWN settings, not Android's.
#
# The standard *_vibration_intensity keys accept 0-3 and were ALREADY at 3 on this
# device - which is why setting them to 3 changed nothing at all, and why "поставил 3,
# разницы не чувствую" was an accurate report rather than a perception problem.
#
# Watching what the OEM's own slider writes settles it: moving it rewrites
# *_stepless_vibration_intensity, a much finer scale - observed 900, 1400, 2000, 2300, 2400 -
# while the coarse key stays at 3.
#
# 2400 is the ceiling because that is the highest value the OEM slider was seen to produce.
#
# An earlier version used 2550, reasoned from the values all dividing by 10 and Android's
# amplitude running 1..255 - so 255 x 10 looked like full scale.
#
# The arithmetic was a hypothesis and the device disagreed. 2400 is not a guess: it is a
# value observed coming out of the OEM's own slider, which makes it a value the vendor
# service is known to accept.
ASB_HAP_MAX="$(_cfg haptic_stepless_max)"
case "$ASB_HAP_MAX" in ''|*[!0-9]*) ASB_HAP_MAX=2400 ;; esac
[ "$ASB_HAP_MAX" -lt 500 ] 2>/dev/null && ASB_HAP_MAX=500
# Hard ceiling.
[ "$ASB_HAP_MAX" -gt 2400 ] 2>/dev/null && ASB_HAP_MAX=2400
# Two groups, because the OEM treats them as two and so does the user.
#
# There is no duration control to expose - a full dump of system, global and secure while
# moving the OEM slider shows only these three keys change, and nothing anywhere carries a
# duration, length or time.
#
# What the dump DOES show is that the OEM sets the three independently - 1500 for
# notifications, 1600 for ring and touch - while we were writing one value to all three.
_coarse_alert="notification_vibration_intensity ring_vibration_intensity alarm_vibration_intensity media_vibration_intensity"
_coarse_touch="haptic_feedback_intensity"
_stepless_alert="notification_stepless_vibration_intensity ring_stepless_vibration_intensity"
_stepless_touch="touch_stepless_vibration_intensity"
_coarse="$_coarse_alert $_coarse_touch"
_stepless="$_stepless_alert $_stepless_touch"
_keys="$_coarse $_stepless"

case "$_lvl" in
  0|off)                    _want=0 ;;
  1|2|3|4|5|6|7|8|9|10)     _want="$_lvl" ;;
  light)                    _want=3 ;;
  medium)                   _want=6 ;;
  strong)                   _want=10 ;;
  *)                        _want="" ;;
esac

# Baseline, captured before anything is changed - and TOP UP if keys are missing.
#
# The old code wrote the baseline once and never looked at it again ("if [ !
mkdir -p /data/adb/asb 2>/dev/null
[ -f "$BASE" ] || : > "$BASE" 2>/dev/null
for _k in $_keys; do
  grep -q "^$_k|" "$BASE" 2>/dev/null && continue
  echo "$_k|$(settings get system "$_k" 2>/dev/null)" >> "$BASE" 2>/dev/null
done

# Restore a single key from the baseline.
_hap_restore_key() {
  _rk="$1"
  _rv="$(grep "^$_rk|" "$BASE" 2>/dev/null | head -1 | sed 's/^[^|]*|//')"
  if [ -z "$_rv" ] || [ "$_rv" = "null" ]; then
    settings delete system "$_rk" >/dev/null 2>&1 || true
  else
    settings put system "$_rk" "$_rv" >/dev/null 2>&1 || true
  fi
}

# Touch level: its own value if set, otherwise follow the alert level.
case "$_lvl_touch" in
  0|1|2|3|4|5|6|7|8|9|10) _want_t="$_lvl_touch" ;;
  *)                      _want_t="$_want" ;;
esac

# Both on stock -> restore everything and leave.
#
# The early exit used to fire on "$_want" alone.
if [ -z "$_want" ] && [ -z "$_want_t" ]; then
  for _k in $_keys; do _hap_restore_key "$_k"; done
  echo "haptics: stock (restored)"
  exit 0
fi

# Everything off.
if [ "$_want" = "0" ] && [ "$_want_t" = "0" ]; then
  for _k in $_coarse;   do settings put system "$_k" 0 >/dev/null 2>&1 || true; done
  for _k in $_stepless; do settings put system "$_k" 0 >/dev/null 2>&1 || true; done
  echo "haptics: off"
  exit 0
fi

# --- alerts (notification / ring / alarm / media) ---
if [ -z "$_want" ]; then
  # Master on stock while touch is set: leave the alert side exactly as the device
  # had it instead of dragging it along.
  for _k in $_coarse_alert;   do _hap_restore_key "$_k"; done
  for _k in $_stepless_alert; do _hap_restore_key "$_k"; done
  _amp=""
else
  for _k in $_coarse_alert; do settings put system "$_k" 3 >/dev/null 2>&1 || true; done
  _amp=$(( ASB_HAP_MAX * _want / 10 ))
fi

# --- touch ---
if [ -z "$_want_t" ]; then
  _hap_restore_key haptic_feedback_intensity
  _hap_restore_key touch_stepless_vibration_intensity
  _amp_t=""
else
  # if/else, not "A && B || C": a failed `settings put` in the middle of that idiom
  # falls through to the C branch and writes 3 where 0 was wanted.
  if [ "$_want_t" = "0" ]; then
    settings put system haptic_feedback_intensity 0 >/dev/null 2>&1 || true
  else
    settings put system haptic_feedback_intensity 3 >/dev/null 2>&1 || true
  fi
  _amp_t=$(( ASB_HAP_MAX * _want_t / 10 ))
fi

# Write, then read back.
# The vendor service silently refuses a value it does not like - the setting keeps its old
# contents and the phone just stops buzzing, with nothing anywhere reporting a problem.
for _k in $_stepless; do
  case " $_stepless_touch " in
    *" $_k "*) _try="$_amp_t" ;;
    *)         _try="$_amp"   ;;
  esac
  [ -z "$_try" ] && continue                 # that side is on stock - already restored
  if [ "$_try" = "0" ]; then
    settings put system "$_k" 0 >/dev/null 2>&1 || true
    continue
  fi
  while [ "$_try" -ge 200 ]; do
    settings put system "$_k" "$_try" >/dev/null 2>&1 || true
    [ "$(settings get system "$_k" 2>/dev/null)" = "$_try" ] && break
    _try=$(( _try - 150 ))
  done
done

# Touch feedback has its own on/off switch; an intensity set while it is off does
# nothing. Only ever turn it ON, and only when a touch level is actually active.
if [ -n "$_want_t" ] && [ "$_want_t" != "0" ]; then
  [ "$(settings get system haptic_feedback_enabled 2>/dev/null)" = "0" ] && \
    settings put system haptic_feedback_enabled 1 >/dev/null 2>&1
fi

_hap_fmt() { [ -z "$1" ] && echo "stock" || { [ "$1" = "0" ] && echo "off" || echo "$1/10"; }; }
echo "haptics: alerts $(_hap_fmt "$_want") ($_amp) - touch $(_hap_fmt "$_want_t") ($_amp_t)"
exit 0
