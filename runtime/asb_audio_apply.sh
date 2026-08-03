#!/system/bin/sh
# asb_audio_apply.sh — apply the audio tweaks that do NOT need a reboot.
#
# Which tweaks can land live, and why: audio_profile - plain properties + an audioserver
# restart re-reads them.
# dsp_loudness - libasbdsp.so reads its gain from persist.asb.dsp.* at INIT/ENABLE (never
# inside process()), so a restart re-creates the effect with the new gain.
#
# Deliberately NOT here (a reboot is unavoidable, not laziness): media_loudness - the volume
# curves live in an overlay XML that audiopolicy parses once at boot.
#
# Restarting audioserver briefly cuts audio, so this is only ever run on demand from
# the WebUI, never automatically.

# Settings wrapper: falls back to the content provider where the `settings` command
# cannot reach the service. On a OnePlus 15R every call returned "Failure calling
# service settings" while exiting 0, so writes looked successful and reads returned the
# error text as a value - this makes those calls work without changing any of them.
[ -f "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh" ] && \
  . "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh"

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -f "$CONF" ] || { echo "config not found: $CONF"; exit 1; }

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]'
}
_has() { command -v "$1" >/dev/null 2>&1; }
_persist() { _has resetprop && resetprop -n "$1" "$2" >/dev/null 2>&1 || setprop "$1" "$2" 2>/dev/null; }

# The vendor-namespace copy is created through property_service rather than with resetprop -n,
# so it picks up its SELinux context from property_contexts.
_persist_ctx() {
  _has resetprop && resetprop "$1" "$2" >/dev/null 2>&1 && return 0
  setprop "$1" "$2" 2>/dev/null
}

# Every DSP tunable is written twice, under the legacy name and under the vendor namespace.
# The effect runs inside the vendor HAL process, and persist.asb.* lands in the default_prop
# SELinux context which a vendor domain generally cannot read - the vendor namespace is the one
# vendor code is meant to read.
_dspp() { _persist "persist.asb.dsp.$1" "$2"; _persist_ctx "persist.vendor.asb.dsp.$1" "$2"; }

# "dsp" restricts this run to the DSP values and skips the audioserver restart: the attach
# daemon hands the new gain to the live effect over binder, so there is no need to tear the
# audio stack down and no momentary drop-out when the slider moves.
_mode="${1:-all}"

# "mirror" republishes whatever the DSP properties currently hold under the vendor namespace
# and does nothing else.
if [ "$_mode" = "mirror" ]; then
  # Reconcile the VALUE properties against the config before republishing.
  #
  # Mirror deliberately does not touch `enable` - see above.
  # But it used to republish every property verbatim, including gain, and that left the gain
  # frozen forever: the boot path only calls the full "dsp" mode when persist.asb.dsp.enable is
  # not 1, and `enable` is a PERSIST property, so once the DSP has been on once, boot goes to
  # mirror every time from then on and nothing ever re-derives gain from the config.
  #
  # Observed on a real device: governor.conf said dsp_loudness=1 (+1 dB) while the daemon
  # attached at gain_mb=1800 (+18 dB) - a stale value from an earlier setting, surviving a
  # fresh reinstall because the config is restored but the property is not recomputed.
  #
  # Recomputing just the scalar gain here is safe: it needs no library present, it
  # cannot switch the DSP off, and it makes the property track the config the way the
  # user already believes it does.
  _mdsp="$(_cfg dsp_loudness)"
  case "$_mdsp" in
    ''|off|0|*[!0-9]*) : ;;
    *)
      if [ "$_mdsp" -ge 1 ] 2>/dev/null && [ "$_mdsp" -le 25 ] 2>/dev/null; then
        _mwant="$(( _mdsp * 100 ))"
        _mhave="$(getprop persist.asb.dsp.gain_mb 2>/dev/null)"
        if [ "$_mhave" != "$_mwant" ]; then
          _persist persist.asb.dsp.gain_mb "$_mwant"
          echo "dsp gain reconciled from config: ${_mhave:-unset} -> $_mwant mB"
        fi
      fi
      ;;
  esac
  # Same story for bass: it is a plain scalar read from the config, and leaving it
  # stale produces the same silent divergence.
  _mbass="$(_cfg dsp_bass)"
  case "$_mbass" in
    ''|off|*[!0-9]*) : ;;
    *)
      if [ "$_mbass" -ge 0 ] 2>/dev/null && [ "$_mbass" -le 12 ] 2>/dev/null; then
        _mbhave="$(getprop persist.asb.dsp.bass_db 2>/dev/null)"
        [ "$_mbhave" != "$_mbass" ] && _persist persist.asb.dsp.bass_db "$_mbass"
      fi
      ;;
  esac
  for _k in enable gain_mb ceiling_mb comp comp_ratio_x10 comp_thresh_mb softclip postgain_x100 bass_db; do
    _v="$(getprop "persist.asb.dsp.$_k" 2>/dev/null)"
    [ -n "$_v" ] && _persist_ctx "persist.vendor.asb.dsp.$_k" "$_v"
  done
  echo "mirrored dsp props into the vendor namespace"
  exit 0
fi

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
    # DO NOT set af.resampler.quality here.
    # 7=DYN_HIGH), and this line used to write 255 - out of range, silently dropped, so hifi
    # always ran at DEFAULT.
    setprop af.resampler.quality 0 2>/dev/null || true
  else
    _persist persist.audio.uhqa 0
    _persist persist.vendor.audio.uhqa false
    setprop af.resampler.quality 0 2>/dev/null || true
  fi
fi
changed="${changed}profile=${_ap} "

# ---- bt_absvol_mode -------------------------------------------------------------- A2DP
# offload.
# system.prop pins the four offload properties to "enabled" at boot, which is right for on|auto
# but silently ignores off - the key documented three values and honoured one.
#
# Offload hands A2DP encoding to the DSP: better battery, but effect engines (ViPER, and our
# own DSP) never see the stream, because it bypasses the framework mixer.
# That is exactly why someone would want it off, and it has to be a live settings write rather
# than a system.prop line, since system.prop cannot express "leave it alone".
_a2dp="$(_cfg bt_a2dp_offload)"
case "$_a2dp" in
  off|0|false)
    settings put global bluetooth_a2dp_offload_enabled 0 >/dev/null 2>&1 || true
    if _has resetprop; then
      resetprop -n persist.bluetooth.a2dp_offload.disabled true >/dev/null 2>&1 || true
      resetprop -n persist.vendor.bluetooth.a2dp_offload.disabled true >/dev/null 2>&1 || true
    fi
    changed="${changed}a2dp_offload=off " ;;
  on|1|true)
    settings put global bluetooth_a2dp_offload_enabled 1 >/dev/null 2>&1 || true
    if _has resetprop; then
      resetprop -n persist.bluetooth.a2dp_offload.disabled false >/dev/null 2>&1 || true
      resetprop -n persist.vendor.bluetooth.a2dp_offload.disabled false >/dev/null 2>&1 || true
    fi ;;
  *) : ;;   # auto: leave whatever the ROM and other modules decided
esac

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

# ---- dsp_loudness (gain only) ---------------------------------------------------- Slider
# gives any integer 0..25 now (not just 3/6/9), so accept the whole range.
# The DSP effect re-reads persist.asb.dsp.* on ENABLE, and the audioserver restart below
# triggers that ENABLE - which is why gain changes here apply live, no reboot.
_dsp="$(_cfg dsp_loudness)"
_dsp_ok=0
case "$_dsp" in
  ''|off|0) _dsp_ok=0 ;;
  *[!0-9]*) _dsp_ok=0 ;;
  *) [ "$_dsp" -ge 1 ] 2>/dev/null && [ "$_dsp" -le 25 ] 2>/dev/null && _dsp_ok=1 ;;
esac
# The eq_compat profile exists to hand the stream to an external engine (ViPER and friends).
# Our own effect sits on the same output and the external driver then does not see the stream
# at all, so the two cannot share it: eq_compat wins and the DSP is turned off outright.
_dsp_eq_off=0
if [ "$_ap" = "eq_compat" ] && [ "$_dsp_ok" = "1" ]; then
  _dsp_ok=0
  _dsp_eq_off=1
fi
if [ "$_dsp_ok" = "1" ]; then
    if [ -f /vendor/lib64/soundfx/libasbdsp.so ] || [ -f /vendor/lib/soundfx/libasbdsp.so ]; then
      _dspp enable 1
      _dspp gain_mb "$((_dsp * 100))"
      # Output routing. The library reads this and skips the effect on any sink whose
      # name does not match - previously it attached to everything, so a Bluetooth-only
      # boost also lifted the loudspeaker, which is the driver least able to take it.
      _dsp_out="$(_cfg dsp_outputs)"
      case "$_dsp_out" in
        ''|all) _dsp_out="all" ;;
        speaker|wired|bt|speaker+wired|speaker+bt|wired+bt) : ;;
        *) _dsp_out="all" ;;
      esac
      _dspp outputs "$_dsp_out"
      # Publish the CURRENT route as well.
      #
      # The library filters on the device the framework hands it, but on the global mix
      # that information does not always arrive - and an effect that never learns its
      # route was treating "bt" as permission to process the speaker. Reading the live
      # route here and exposing it as a property gives the library something to check
      # when the framework tells it nothing.
      #
      # dumpsys is the source of truth for what audio is coming out of right now; the
      # order matters, because a phone with headphones connected AND a BT device paired
      # routes to whichever was selected last, not to both.
      _asb_route=""
      if _has dumpsys; then
        _rt_dump="$(dumpsys audio 2>/dev/null | grep -m1 -iE 'Device[s]?: *(speaker|bt|usb|wired|headset|headphone)')"
        case "$_rt_dump" in
          *bt_a2dp*|*BLUETOOTH_A2DP*|*bt_le*|*bt_sco*) _asb_route="bt" ;;
          *usb*|*USB*|*wired_headset*|*wired_headphone*|*HEADSET*|*HEADPHONE*) _asb_route="wired" ;;
          *speaker*|*SPEAKER*) _asb_route="speaker" ;;
        esac
      fi
      # Fall back to the A2DP connection state: if something is connected over A2DP and
      # playing, the route is bt whatever the dump said.
      if [ -z "$_asb_route" ] && _has dumpsys; then
        dumpsys bluetooth_manager 2>/dev/null | grep -qiE 'A2DP.*(connected|playing)' \
          && _asb_route="bt"
      fi
      [ -n "$_asb_route" ] || _asb_route="speaker"
      _dspp route "$_asb_route"
      _dspp ceiling_mb -15
      # Compressor, on unless the user asked for it off.
      #
      # It exists so that large gain does not simply slam into the limiter: 6:1 above -24 dBFS
      # holds the body of the track down while the peaks stay clean.
      # At +2..+4 dB it is the wrong one - peaks barely reach the ceiling anyway, so all the
      # compressor does is squash dynamics that never needed squashing, which is exactly what
      # someone listening to a mastered recording hears as "processed".
      #
      # Turning it off does NOT remove the limiter: true peaks are still caught at the
      # ceiling, so this cannot clip. What it can do at high gain is make the limiter work
      # continuously instead of occasionally, which sounds worse than the compressor did.
      _dsp_comp="$(_cfg dsp_compressor)"
      case "$_dsp_comp" in
        off|0|false) _dspp comp 0; changed="${changed}comp=off " ;;
        *)           _dspp comp 1 ;;
      esac
      _dspp comp_ratio_x10 60
      _dspp comp_thresh_mb -2400
      changed="${changed}dsp=+${_dsp}dB "
    else
      # The library is only mounted after the overlay comes up.
      _dspp enable 0
      changed="${changed}dsp=needs-reboot "
    fi
elif [ "$_dsp_eq_off" = "1" ]; then
    _dspp enable 0
    changed="${changed}dsp=off(eq_compat) "
else
    _dspp enable 0
    changed="${changed}dsp=off "
fi

# ---- saturation: permanently off -------------------------------------------------- The tanh
# saturator is gone from the UI: at every drive it audibly buzzed on real material, which is
# not a trade worth offering.
_dspp softclip 0
_dspp postgain_x100 300

# ---- dsp_bass (low-shelf boost) --------------------------------------------------- A shelf
# at 90 Hz: full lift at DC, half of it at the corner, nothing above ~1 kHz.
# It runs at the head of the chain so the compressor and limiter see the boosted low end -
# which also means the extra bass eats headroom and the limiter engages sooner.
_bs="$(_cfg dsp_bass)"
case "$_bs" in
  ''|off|0)  _bsx=0 ;;
  *[!0-9]*)  _bsx=0 ;;
  *) if [ "$_bs" -ge 1 ] 2>/dev/null && [ "$_bs" -le 10 ] 2>/dev/null; then _bsx="$_bs"; else _bsx=0; fi ;;
esac
_dspp bass_db "$_bsx"
[ "$_bsx" = "0" ] && changed="${changed}bass=off " || changed="${changed}bass=+${_bsx}dB "

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

# ---- read back what is ACTUALLY live ---------------------------------------------- Testers
# reasonably ask "how do I know any of this took effect?" - printing what we wrote proves
# nothing, because a property can be rejected (out-of-range values are silently dropped) or
# overwritten by the platform.
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
