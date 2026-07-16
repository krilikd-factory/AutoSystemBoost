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
    setprop af.resampler.quality 255 2>/dev/null || true
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
echo "audioserver restarted - playback resumes in a second"
exit 0
