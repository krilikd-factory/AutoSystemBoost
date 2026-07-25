#!/system/bin/sh
# asb_dsp_abi_apply.sh - switch the audio-effect ABI without reinstalling the module.
#
# Whether a device binds effects through the AIDL factory (createEffect) or the legacy
# HIDL one (AUDIO_EFFECT_LIBRARY_INFO_SYM) depends on what that OEM's audioserver was
# built against, not on the Android version. The installer probes VINTF and is usually
# right, but when it is wrong the symptom is total silence from dsp_loudness with the
# attach daemon reporting set=-19 initCheck=-19 (NO_INIT).
#
# Telling a user to "edit governor.conf and reinstall" is not a real answer: the file
# lives inside the module directory, and a reinstall of the same zip would just re-run
# the same probe. Both library variants are already in the module, so the switch is a
# file copy plus a reboot - which is what this does, and what the WebUI card calls.
#
# The overlay lives on /data and is magic-mounted at boot, so the copy takes effect on
# the next boot; the effect itself is loaded by audioserver at start and cannot be
# swapped under a running one.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -f "$CONF" ] || { echo "config not found: $CONF"; exit 1; }

_want="${1:-}"
if [ -z "$_want" ]; then
  _want="$(grep -E '^[[:space:]]*dsp_effect_abi=' "$CONF" 2>/dev/null \
           | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]')"
fi
case "$_want" in
  aidl|legacy) : ;;
  auto|'')
    echo "dsp_effect_abi=auto - the installer's probe decides; nothing to switch here."
    echo "Set aidl or legacy to override it."
    exit 0 ;;
  *) echo "unknown value: $_want (expected auto, aidl or legacy)"; exit 1 ;;
esac

if [ "$_want" = "legacy" ]; then
  _s64="$MODDIR/bin/libasbdsp_legacy.so"
  _s32="$MODDIR/bin/libasbdsp_legacy_32.so"
else
  _s64="$MODDIR/bin/libasbdsp.so"
  _s32="$MODDIR/bin/libasbdsp_32.so"
fi
if [ ! -f "$_s64" ]; then
  echo "the $_want library is not in this build ($_s64 missing) - reinstall a build that ships both"
  exit 1
fi

_n=0
for _pair in "$_s64|$MODDIR/system/vendor/lib64/soundfx|/vendor/lib64/soundfx" \
             "$_s32|$MODDIR/system/vendor/lib/soundfx|/vendor/lib/soundfx"; do
  _src="${_pair%%|*}"; _rest="${_pair#*|}"
  _dir="${_rest%%|*}"; _live="${_rest##*|}"
  [ -f "$_src" ] || continue
  mkdir -p "$_dir" 2>/dev/null || continue
  cp -f "$_src" "$_dir/libasbdsp.so" 2>/dev/null || continue
  chmod 0644 "$_dir/libasbdsp.so" 2>/dev/null
  # Borrow the label from a real library in the matching live soundfx dir - without a
  # vendor context audioserver is not allowed to dlopen it and the effect never loads.
  _ref=""
  for _c in "$_live"/*.so; do [ -f "$_c" ] && { _ref="$_c"; break; }; done
  if [ -n "$_ref" ]; then
    _ctx="$(ls -Zd "$_ref" 2>/dev/null | awk '{print $1}')"
    case "$_ctx" in
      ?*:?*:?*:?*) chcon "$_ctx" "$_dir/libasbdsp.so" 2>/dev/null || true ;;
    esac
  fi
  _n=$((_n + 1))
done

[ "$_n" -gt 0 ] || { echo "could not stage the $_want library"; exit 1; }
echo "$_want" > /data/adb/asb/dsp_effect_abi_active 2>/dev/null
echo "staged the $_want effect ($_n lib(s)) - reboot to apply"
exit 0
