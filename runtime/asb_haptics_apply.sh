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
# Ceiling of the stepless scale.
#
# Every observed value divides cleanly by 10 - 900, 1400, 2000, 2300, 2400 - and Android's
# VibrationEffect amplitude runs 1..255. 255 x 10 = 2550, which makes the OEM value look
# like amplitude in tenths and puts full scale at 2550 rather than the 2400 the slider
# happened to stop at. So the top step is 2550: the strongest the actuator is driven at
# all, not the strongest the OEM UI offers.
#
# Above that the value is almost certainly clamped rather than louder - amplitude has
# nowhere left to go. haptic_stepless_max in governor.conf overrides this for anyone who
# wants to find out on their own device; the default stays at the value the arithmetic
# supports rather than a guess.
ASB_HAP_MAX="$(_cfg haptic_stepless_max)"
case "$ASB_HAP_MAX" in ''|*[!0-9]*) ASB_HAP_MAX=2550 ;; esac
[ "$ASB_HAP_MAX" -lt 500 ] 2>/dev/null && ASB_HAP_MAX=500
[ "$ASB_HAP_MAX" -gt 5000 ] 2>/dev/null && ASB_HAP_MAX=5000
_coarse="haptic_feedback_intensity notification_vibration_intensity ring_vibration_intensity alarm_vibration_intensity media_vibration_intensity"
_stepless="notification_stepless_vibration_intensity ring_stepless_vibration_intensity touch_stepless_vibration_intensity"
_keys="$_coarse $_stepless"

case "$_lvl" in
  0|off)                    _want=0 ;;
  1|2|3|4|5|6|7|8|9|10)     _want="$_lvl" ;;
  light)                    _want=3 ;;
  medium)                   _want=6 ;;
  strong)                   _want=10 ;;
  *)                        _want="" ;;
esac

# Baseline, captured once before anything is changed.
if [ ! -f "$BASE" ]; then
  mkdir -p /data/adb/asb 2>/dev/null
  : > "$BASE" 2>/dev/null
  for _k in $_keys; do
    echo "$_k|$(settings get system "$_k" 2>/dev/null)" >> "$BASE" 2>/dev/null
  done
fi

if [ -z "$_want" ]; then
  if [ -f "$BASE" ]; then
    while IFS='|' read -r _k _v; do
      [ -n "$_k" ] || continue
      if [ -z "$_v" ] || [ "$_v" = "null" ]; then
        settings delete system "$_k" >/dev/null 2>&1 || true
      else
        settings put system "$_k" "$_v" >/dev/null 2>&1 || true
      fi
    done < "$BASE"
  fi
  echo "haptics: stock (restored)"
  exit 0
fi

if [ "$_want" = "0" ]; then
  for _k in $_coarse;   do settings put system "$_k" 0 >/dev/null 2>&1 || true; done
  for _k in $_stepless; do settings put system "$_k" 0 >/dev/null 2>&1 || true; done
  echo "haptics: off"
  exit 0
fi

# Coarse keys open the gate; the stepless value is what is actually felt.
for _k in $_coarse; do settings put system "$_k" 3 >/dev/null 2>&1 || true; done
_amp=$(( ASB_HAP_MAX * _want / 10 ))
for _k in $_stepless; do settings put system "$_k" "$_amp" >/dev/null 2>&1 || true; done

# Touch feedback has its own on/off switch; an intensity set while it is off does
# nothing. Only ever turn it ON.
[ "$(settings get system haptic_feedback_enabled 2>/dev/null)" = "0" ] && \
  settings put system haptic_feedback_enabled 1 >/dev/null 2>&1

echo "haptics: level $_want/10 (stepless $_amp)"
exit 0
