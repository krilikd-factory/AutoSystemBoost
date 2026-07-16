#!/system/bin/sh
# asb_audio_apply.sh — apply the audio tweaks that do NOT need a reboot.
#
# Which tweaks can land live, and why:
#   audio_profile   - plain properties + an audioserver restart re-reads them.
#   bt_absvol_mode  - settings rows + properties, same restart picks them up.
#   dsp_loudness    - libasbdsp.so reads its gain from persist.asb.dsp.* at
#                     INIT/ENABLE (never inside process()), so a restart re-creates
#                     the effect with the new gain. NOTE: only the GAIN is live --
#                     switching from "off" installs the .so into the overlay, and that
#                     is a file mount, so the first enable still needs a reboot.
#
# Deliberately NOT here (a reboot is unavoidable, not laziness):
#   media_loudness  - the volume curves live in an overlay XML that audiopolicy parses
#                     once at boot.
#   audio_dac_hifi  - patches mixer files in the overlay; same reason.
#
# Restarting audioserver briefly cuts audio, so this is only ever run on demand from
# the WebUI, never automatically.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -f "$CONF" ] || { echo "config not found: $CONF"; exit 1; }

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]'
}
_has() { command -v "$1" >/dev/null 2>&1; }
_persist() { _has resetprop && resetprop -n "$1" "$2" >/dev/null 2>&1 || setprop "$1" "$2" 2>/dev/null; }

changed=""

# ---- audio_profile ---------------------------------------------------------------
_ap="$(_cfg audio_profile)"
case "$_ap" in eq_compat|stock|hifi) : ;; *) _ap="stock" ;; esac
setprop ro.audio.bt.connect.disable.mute true 2>/dev/null || true
if [ "$_ap" = "eq_compat" ]; then
  _persist persist.audio.uhqa 0
  _persist persist.vendor.audio.uhqa false
  setprop af.resampler.quality 0 2>/dev/null || true
else
  _persist persist.audio.hifi.int_codec true
  _persist persist.vendor.audio.hifi.int_codec true
  _persist persist.vendor.audio.aec_ref.enable false
  setprop vendor.audio.feature.aec_ref.enable false 2>/dev/null || true
  if [ "$_ap" = "hifi" ]; then
    setprop ro.audio.hifi true 2>/dev/null || true
    setprop ro.vendor.audio.hifi true 2>/dev/null || true
    _persist persist.audio.hifi true
    _persist persist.vendor.audio.hifi true
    _persist persist.audio.uhqa 1
    _persist persist.vendor.audio.uhqa true
    # af.resampler.quality is an ENUM (AOSP AudioResampler src_quality), not a scale:
    # 0=DEFAULT 1=LOW 2=MED 3=HIGH 4=VERY_HIGH 5=DYN_LOW 6=DYN_MED 7=DYN_HIGH.
    # This used to write 255 for "maximum", which is out of range and gets thrown away -
    # so hifi silently fell back to DEFAULT, i.e. byte-identical to stock. Two testers
    # independently reported "no difference when switching, like stock is running", and
    # this is why. 4 = VERY_HIGH_QUALITY is the real top of the enum.
    # (0 stays correct for the other profiles: it means DEFAULT and also RESETS the prop
    # when switching back from hifi without a reboot.)
    setprop af.resampler.quality 4 2>/dev/null || true
  else
    _persist persist.audio.uhqa 0
    _persist persist.vendor.audio.uhqa false
    setprop af.resampler.quality 0 2>/dev/null || true
  fi
fi
changed="${changed}profile=${_ap} "

# ---- bt_absvol_mode --------------------------------------------------------------
_bt="$(_cfg bt_absvol_mode)"
case "$_bt" in on|disabled) _bt="disabled" ;; *) _bt="stock" ;; esac
if [ "$_bt" = "disabled" ]; then _dav=1; _dp="true"; else _dav=0; _dp="false"; fi
if _has settings; then
  settings put global bluetooth_disable_absolute_volume "$_dav" >/dev/null 2>&1 || true
  settings put secure bluetooth_disable_absolute_volume "$_dav" >/dev/null 2>&1 || true
fi
_persist persist.bluetooth.disableabsvol "$_dp"
_persist persist.vendor.bluetooth.disableabsvol "$_dp"
changed="${changed}bt_absvol=${_bt} "

# ---- dsp_loudness (gain only) ----------------------------------------------------
_dsp="$(_cfg dsp_loudness)"
case "$_dsp" in
  3|6|9)
    if [ -f /vendor/lib64/soundfx/libasbdsp.so ]; then
      _persist persist.asb.dsp.enable 1
      _persist persist.asb.dsp.gain_mb "$((_dsp * 100))"
      _persist persist.asb.dsp.ceiling_mb -100
      changed="${changed}dsp=+${_dsp}dB "
    else
      # The library is only mounted after the overlay comes up.
      _persist persist.asb.dsp.enable 0
      changed="${changed}dsp=needs-reboot "
    fi
    ;;
  *)
    _persist persist.asb.dsp.enable 0
    changed="${changed}dsp=off "
    ;;
esac

# ---- re-init the audio stack so all of the above goes live ------------------------
setprop ctl.restart audioserver 2>/dev/null || true
echo "applied: $changed"

# ---- read back what is ACTUALLY live ----------------------------------------------
# Testers reasonably ask "how do I know any of this took effect?" - printing what we
# wrote proves nothing, because a property can be rejected (out-of-range values are
# silently dropped) or overwritten by the platform. So wait for audioserver to come
# back and report what the system really holds now. If a line below does not match what
# you selected, that tweak did NOT apply - that is the log to send.
_n=0
while [ "$_n" -lt 20 ]; do
  [ "$(getprop init.svc.audioserver 2>/dev/null)" = "running" ] && break
  sleep 1; _n=$((_n + 1))
done
sleep 1
echo ""
echo "live state after audioserver restart:"
printf '  %-42s = %s\n' "audio_profile (config)"          "$_ap"
printf '  %-42s = %s\n' "af.resampler.quality"            "$(getprop af.resampler.quality 2>/dev/null)"
printf '  %-42s = %s\n' "persist.audio.uhqa"              "$(getprop persist.audio.uhqa 2>/dev/null)"
printf '  %-42s = %s\n' "persist.vendor.audio.uhqa"       "$(getprop persist.vendor.audio.uhqa 2>/dev/null)"
printf '  %-42s = %s\n' "persist.audio.hifi.int_codec"    "$(getprop persist.audio.hifi.int_codec 2>/dev/null)"
printf '  %-42s = %s\n' "bt_absvol_mode (config)"         "$_bt"
printf '  %-42s = %s\n' "persist.bluetooth.disableabsvol" "$(getprop persist.bluetooth.disableabsvol 2>/dev/null)"
printf '  %-42s = %s\n' "dsp_loudness (config)"           "$_dsp"
printf '  %-42s = %s\n' "persist.asb.dsp.enable"          "$(getprop persist.asb.dsp.enable 2>/dev/null)"
printf '  %-42s = %s\n' "persist.asb.dsp.gain_mb"         "$(getprop persist.asb.dsp.gain_mb 2>/dev/null)"
printf '  %-42s = %s\n' "libasbdsp.so present"            "$([ -f /vendor/lib64/soundfx/libasbdsp.so ] && echo yes || echo no)"
printf '  %-42s = %s\n' "audioserver"                     "$(getprop init.svc.audioserver 2>/dev/null)"
echo ""
echo "note: af.resampler.quality is an enum 0-7 (0=DEFAULT, 4=VERY_HIGH). Anything"
echo "      outside that range is dropped by AudioFlinger and you get DEFAULT."
exit 0
