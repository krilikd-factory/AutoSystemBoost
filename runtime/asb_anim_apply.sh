#!/system/bin/sh
# asb_anim_apply.sh - animation speed, as a user choice rather than a profile side effect.
#
# The scales were only ever set by the active profile (performance 0.8, balanced 0.9,
# battery 1.0), which meant the speed of the UI was decided by a power setting. Someone
# who likes a snappy phone on Battery, or a calm one on Performance, had no way to say so.
#
# No reboot: WindowManager reads these per animation, so the next transition already uses
# the new value. UX_ANIM_FORCE_RESTART existed to make that immediate and is not needed.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -f "$CONF" ] || exit 0
[ -r "$MODDIR/runtime/asb_baseline.sh" ] && . "$MODDIR/runtime/asb_baseline.sh"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]'
}
_put() {
  if command -v asb_settings_put >/dev/null 2>&1; then asb_settings_put global "$1" "$2"
  else settings put global "$1" "$2" >/dev/null 2>&1 || true; fi
}

_sp="$(_cfg anim_speed)"
# Numeric positions from the slider, words from older configs. -1 is "let the profile
# decide", which is the shipped default and the only value that changes nothing.
case "$_sp" in
  -1|profile|'') _v="" ;;
  0|off)         _v=0    ;;
  1|fastest)     _v=0.5  ;;
  2|faster)      _v=0.7  ;;
  3|fast)        _v=0.85 ;;
  4)             _v=0.9  ;;
  5)             _v=0.95 ;;
  6|stock)       _v=1    ;;
  7|slow)        _v=1.25 ;;
  8|slower)      _v=1.5  ;;
  *)             _v="" ;;
esac
[ -z "$_v" ] && { echo "animations: following the profile"; exit 0; }

for _k in window_animation_scale transition_animation_scale animator_duration_scale; do
  _put "$_k" "$_v"
done
echo "animations: scale ${_v}x (applies to the next transition)"
exit 0
