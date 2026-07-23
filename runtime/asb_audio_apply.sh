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

# The vendor-namespace copy is created through property_service rather than with
# resetprop -n, so it picks up its SELinux context from property_contexts. Verified on
# device: persist.vendor.* lands in vendor_default_prop, the context a vendor process is
# allowed to read, while persist.asb.* lands in default_prop, which it is not.
_persist_ctx() {
  _has resetprop && resetprop "$1" "$2" >/dev/null 2>&1 && return 0
  setprop "$1" "$2" 2>/dev/null
}

# Every DSP tunable is written twice, under the legacy name and under the vendor
# namespace. The effect runs inside the vendor HAL process, and persist.asb.* lands in the
# default_prop SELinux context which a vendor domain generally cannot read - the vendor
# namespace is the one vendor code is meant to read. Writing both keeps older installs and
# the diagnostics in action.sh working unchanged.
_dspp() { _persist "persist.asb.dsp.$1" "$2"; _persist_ctx "persist.vendor.asb.dsp.$1" "$2"; }

# "dsp" restricts this run to the DSP values and skips the audioserver restart: the attach
# daemon hands the new gain to the live effect over binder, so there is no need to tear the
# audio stack down and no momentary drop-out when the slider moves.
_mode="${1:-all}"

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
    # DO NOT set af.resampler.quality here. History, so nobody re-adds it:
    # it is an enum (0=DEFAULT 1=LOW .. 4=VERY_HIGH .. 7=DYN_HIGH), and this line used to
    # write 255 - out of range, silently dropped, so hifi always ran at DEFAULT. That is
    # why testers reported "no difference, like stock". Setting the real enum top (4 =
    # VERY_HIGH_QUALITY) made it engage for the first time and BROKE PLAYBACK: a huge FIR
    # per buffer starves the audio thread, so Signal calls went silent both ways, Poweramp
    # glitched out, and YouTube dropped the moment anything else touched the CPU. The
    # feature never worked, and when made to work it was harmful - so it stays off.
    # 0 = DEFAULT is written below for every profile, which also RESETS the property if an
    # earlier build left 4 or 255 in the property store without a reboot.
    setprop af.resampler.quality 0 2>/dev/null || true
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
# Slider gives any integer 0..18 now (not just 3/6/9), so accept the whole range. The
# DSP effect re-reads persist.asb.dsp.* on ENABLE, and the audioserver restart below
# triggers that ENABLE - which is why gain changes here apply live, no reboot. Values
# mirror post-fs-data exactly (ceiling -15, comp 6:1 @ -24 dBFS) so live and boot agree.
_dsp="$(_cfg dsp_loudness)"
_dsp_ok=0
case "$_dsp" in
  ''|off|0) _dsp_ok=0 ;;
  *[!0-9]*) _dsp_ok=0 ;;
  *) [ "$_dsp" -ge 1 ] 2>/dev/null && [ "$_dsp" -le 18 ] 2>/dev/null && _dsp_ok=1 ;;
esac
if [ "$_dsp_ok" = "1" ]; then
    if [ -f /vendor/lib64/soundfx/libasbdsp.so ] || [ -f /vendor/lib/soundfx/libasbdsp.so ]; then
      _dspp enable 1
      _dspp gain_mb "$((_dsp * 100))"
      _dspp ceiling_mb -15
      _dspp comp 1
      _dspp comp_ratio_x10 60
      _dspp comp_thresh_mb -2400
      changed="${changed}dsp=+${_dsp}dB "
    else
      # The library is only mounted after the overlay comes up.
      _dspp enable 0
      changed="${changed}dsp=needs-reboot "
    fi
else
    _dspp enable 0
    changed="${changed}dsp=off "
fi

# ---- dsp_postgain (saturation drive) ----------------------------------------------
# off keeps the brick-wall limiter. 1..10 switches the chain to the bounded tanh
# saturator with that drive, which fits more average level into the same headroom at the
# cost of colouring the waveform on purpose.
_pg="$(_cfg dsp_postgain)"
case "$_pg" in
  ''|off|0)  _soft=0; _pgx=300 ;;
  *[!0-9]*)  _soft=0; _pgx=300 ;;
  *) if [ "$_pg" -ge 1 ] 2>/dev/null && [ "$_pg" -le 10 ] 2>/dev/null; then
       _soft=1; _pgx=$((_pg * 100))
     else
       _soft=0; _pgx=300
     fi ;;
esac
_dspp softclip "$_soft"
_dspp postgain_x100 "$_pgx"
[ "$_soft" = "1" ] && changed="${changed}postgain=x${_pg} " || changed="${changed}postgain=off "

# ---- go live ----------------------------------------------------------------------
if [ "$_mode" = "dsp" ]; then
  # No audioserver restart: the attach daemon hands the new gain to the already-running
  # effect over binder, so the change is immediate and the audio never drops out. The
  # signal only cuts the daemon's poll sleep short so it does not wait up to 30 s.
  pkill -USR1 -f asb_dsp_attach 2>/dev/null \
    || killall -USR1 asb_dsp_attach 2>/dev/null || true
  echo "applied: $changed (live - no audioserver restart)"
  exit 0
fi
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
printf '  %-42s = %s\n' "persist.asb.dsp.comp"            "$(getprop persist.asb.dsp.comp 2>/dev/null)"
printf '  %-42s = %s\n' "persist.asb.dsp.comp_ratio_x10"  "$(getprop persist.asb.dsp.comp_ratio_x10 2>/dev/null)"
printf '  %-42s = %s\n' "libasbdsp.so present"            "$({ [ -f /vendor/lib64/soundfx/libasbdsp.so ] || [ -f /vendor/lib/soundfx/libasbdsp.so ]; } && echo yes || echo no)"
printf '  %-42s = %s\n' "audioserver"                     "$(getprop init.svc.audioserver 2>/dev/null)"
echo ""
echo "note: af.resampler.quality must read 0 (DEFAULT). ASB deliberately does not raise"
echo "      it: forcing VERY_HIGH starves the audio thread and breaks calls/playback."
exit 0
