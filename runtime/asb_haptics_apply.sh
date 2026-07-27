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
case "$_lvl" in
  off)    _want=0 ;;
  light)  _want=1 ;;
  strong) _want=3 ;;
  medium) _want=2 ;;
  stock|'') _want="" ;;
  *)      _want="" ;;
esac

# Baseline, captured once before anything is changed - the same rule the OEM-toggle and
# tracking paths follow. Re-reading it later would record our own value and make the
# restore meaningless.
_keys="haptic_feedback_intensity notification_vibration_intensity ring_vibration_intensity alarm_vibration_intensity media_vibration_intensity"
if [ ! -f "$BASE" ]; then
  mkdir -p /data/adb/asb 2>/dev/null
  : > "$BASE" 2>/dev/null
  for _k in $_keys; do
    echo "$_k|$(settings get system "$_k" 2>/dev/null)" >> "$BASE" 2>/dev/null
  done
fi

if [ -z "$_want" ]; then
  # stock: put back exactly what was there, including "null" for keys that were never set.
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

for _k in $_keys; do
  settings put system "$_k" "$_want" >/dev/null 2>&1 || true
done
# Touch feedback has its own on/off switch, and setting an intensity while it is off
# does nothing. Only ever turn it ON - a user who deliberately disabled touch feedback
# and then asked for stronger haptics is telling us about notifications, not keypresses,
# so "off" is left alone.
[ "$_want" -gt 0 ] 2>/dev/null && \
  [ "$(settings get system haptic_feedback_enabled 2>/dev/null)" = "0" ] && \
  settings put system haptic_feedback_enabled 1 >/dev/null 2>&1

case "$_want" in
  0) echo "haptics: off" ;;
  1) echo "haptics: light" ;;
  2) echo "haptics: medium (Android default)" ;;
  3) echo "haptics: strong" ;;
esac
exit 0
