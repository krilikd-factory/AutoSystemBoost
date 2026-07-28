#!/system/bin/sh
# asb_haptics_apply.sh - vibration strength, through the path this device actually uses.
#
# What the probe found on a OnePlus 15, and why this script looks the way it does:
#
#   /sys/class/leds/vibrator/      does not exist
#   /sys/class/timed_output/       does not exist
#   /sys/class/qcom-haptics/       not present either
#   vendor.oplus.vibrator          running, with ro.oplus.haptic.lra_* properties
#
# So there is no sysfs node to write. The HapticControl module the user tried writes to
# /sys/class/qcom-haptics/{cali_time,cl_vmax,t_lra_us} - nodes that simply are not there
# on this platform, which is exactly why it "does not work or does not work as expected".
# It is not a broken module; it is a module for a different vibrator driver.
#
# The ro.oplus.haptic.lra_* properties are read-only calibration data written at first
# boot - the LRA's measured resonance range for THIS unit. They are not intensity
# controls, and overriding them means telling the driver to drive the motor off its
# resonant frequency: quieter and rougher, not stronger, with real wear on the actuator.
# That is why this script does not touch them.
#
# What is left, and what actually works, is the framework layer. VibrationEffect scales
# every haptic by the per-usage intensity settings, and the vendor service honours them
# because they arrive through the standard Vibrator HAL path. On this device most read
# "null", which means "never set, use the default" - so there is room to raise them.
#
# Scale: 0 = off, 1 = light, 2 = medium (Android's default), 3 = strong.

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
# *_stepless_vibration_intensity, a much finer scale - observed 900, 1400, 2000, 2300,
# 2400 - while the coarse key stays at 3. So the coarse key is a gate and the stepless
# one is the actual amplitude. We set both: the gate open, the amplitude from the slider.
#
# 2400 is the ceiling because that is the highest value the OEM slider was seen to
# produce. Going above an untested value on a linear actuator is not a knob worth
# turning blind, so the top of our range is the top of theirs.
# Ceiling of the stepless scale: 2400, which is what the OEM slider produces at its top.
#
# An earlier version used 2550, reasoned from the values all dividing by 10 and Android's
# amplitude running 1..255 - so 255 x 10 looked like full scale. Tested on the device, it
# is not: at 2550 the vibration disappears entirely while 2295 (level 9) works. The value
# is REJECTED above the real maximum, not clamped to it, so overshooting does not cost a
# little headroom - it costs the vibration.
#
# The arithmetic was a hypothesis and the device disagreed. 2400 is not a guess: it is a
# value observed coming out of the OEM's own slider, which makes it a value the vendor
# service is known to accept.
ASB_HAP_MAX="$(_cfg haptic_stepless_max)"
case "$ASB_HAP_MAX" in ''|*[!0-9]*) ASB_HAP_MAX=2400 ;; esac
[ "$ASB_HAP_MAX" -lt 500 ] 2>/dev/null && ASB_HAP_MAX=500
# Hard ceiling. Above the value the vendor service accepts, vibration stops rather than
# saturating, so an over-large override is not an experiment with a dull result - it is a
# silent phone. Anyone raising this is testing whether their device takes more, and the
# cap keeps that from turning into "haptics broke and I do not know why".
[ "$ASB_HAP_MAX" -gt 2400 ] 2>/dev/null && ASB_HAP_MAX=2400
# Two groups, because the OEM treats them as two and so does the user.
#
# There is no duration control to expose - a full dump of system, global and secure while
# moving the OEM slider shows only these three keys change, and nothing anywhere carries a
# duration, length or time. Android has no system-wide duration multiplier either: it
# comes from each VibrationEffect's own waveform. So a second slider for duration would be
# a control with nothing behind it.
#
# What the dump DOES show is that the OEM sets the three independently - 1500 for
# notifications, 1600 for ring and touch - while we were writing one value to all three.
# That is the real second axis, and it maps onto what people actually want differently
# from each other: alerts strong enough to feel through a pocket, and typing feedback that
# is not punishing to hold in the hand.
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
# The old code wrote the baseline once and never looked at it again ("if [ ! -f ]").
# When the key list grew (the three *_stepless_* amplitudes are the ones that are
# actually felt), devices that had already been installed kept a five-key baseline
# from the older build. Restoring "stock" then put back only the coarse gates and left
# the amplitude wherever ASB last wrote it - so turning the tweak OFF was impossible,
# and the phone stayed on ASB's vibration forever while claiming to be stock.
# Topping up per key is self-healing: a future key addition fixes itself the same way.
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
# The early exit used to fire on "$_want" alone. haptic_strength ships as -1 (stock),
# so on a default install this returned before haptic_touch_strength was ever looked
# at: the touch slider wrote its value, the WebUI confirmed it, and nothing happened.
# Now the exit needs BOTH to be stock.
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

# Write, then read back. The vendor service silently refuses a value it does not like -
# the setting keeps its old contents and the phone just stops buzzing, with nothing
# anywhere reporting a problem. Stepping down until one sticks turns that into a slightly
# weaker buzz instead of no buzz, which is the failure mode worth having.
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
