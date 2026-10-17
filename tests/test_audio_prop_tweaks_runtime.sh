#!/bin/sh
# Runtime (fix155): the two audio tweaks applied through system properties.
#
# Resampler Quality and Media Volume Steps are read by Android only when the audio server
# and the audio service start, so ASB sets them before Android starts (post-fs-data) and the
# cards say "reboot to apply". The REAL blocks run here with a fake resetprop / getprop /
# dumpsys:
#   - stock writes nothing at all, and neither does an unknown value;
#   - high and max write the full filter set, max the stronger one, from 44.1 kHz up;
#   - 30 and 50 write the volume steps, any other number does not;
#   - with the audio category off nothing is written;
#   - the action screen and asbdiag tell "live", "after the next reboot" and "this ROM
#     ignores it" apart, reading the media steps from the STREAM_MUSIC block only.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL audio prop tweaks: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PFD="$ROOT/post-fs-data.sh"
_s="$(grep -n "_rs_q=\"\$(grep -E '\^\[\[:space:\]\]\*audio_resampler='" "$PFD" | head -1 | cut -d: -f1)"
[ -n "$_s" ] || fail "post-fs-data does not read audio_resampler"
_s=$((_s - 2))
_e="$(awk -v s="$_s" 'NR>s && /^fi$/ {print NR; exit}' "$PFD")"
sed -n "${_s},${_e}p" "$PFD" > "$T/block.sh"
grep -q 'asb_feature_enabled AUDIO' "$T/block.sh" || fail "the prop block is not gated on the audio category"
grep -q 'asb_device_pack_allows properties' "$T/block.sh" || fail "the prop block ignores the device pack"
mkdir -p "$T/bin" "$T/mod/config"
cat > "$T/bin/resetprop" <<'S'
#!/bin/sh
echo "$*" >> "$RP_LOG"
S
chmod +x "$T/bin/resetprop"
run_pfd() {
  : > "$T/rp"
  printf '%s\n' "$1" > "$T/mod/config/governor.conf"
  PATH="$T/bin:$PATH" MODDIR="$T/mod" RP_LOG="$T/rp" AUDIO_ON="${2:-1}" sh -c '
    asb_feature_enabled() { [ "$1" = AUDIO ] && [ "$AUDIO_ON" = 1 ]; }
    asb_device_pack_allows() { return 0; }
    . "$0"' "$T/block.sh"
}
run_pfd "audio_resampler=stock
media_vol_steps=stock"
[ ! -s "$T/rp" ] || fail "stock wrote properties: $(cat "$T/rp")"
run_pfd "audio_resampler=ultra
media_vol_steps=250"
[ ! -s "$T/rp" ] || fail "an unknown value wrote properties: $(cat "$T/rp")"
run_pfd "audio_resampler=stock
media_vol_steps=12"
[ ! -s "$T/rp" ] || fail "fewer steps than stock were written: $(cat "$T/rp")"
run_pfd "audio_resampler=stock
media_vol_steps=7x"
[ ! -s "$T/rp" ] || fail "a malformed step count was written: $(cat "$T/rp")"
run_pfd "audio_resampler=stock
media_vol_steps=75"
[ "$(cat "$T/rp")" = "-n ro.config.media_vol_steps 75" ] || fail "a slider value (75) not written: $(cat "$T/rp")"
run_pfd "audio_resampler=stock
media_vol_steps=100"
[ "$(cat "$T/rp")" = "-n ro.config.media_vol_steps 100" ] || fail "the slider maximum (100) not written: $(cat "$T/rp")"
run_pfd "audio_resampler=high
media_vol_steps=stock"
[ "$(cat "$T/rp")" = "-n ro.audio.resampler.psd.enable_at_samplerate 44100
-n ro.audio.resampler.psd.stopband 140
-n ro.audio.resampler.psd.halflength 160
-n ro.audio.resampler.psd.cutoff_percent 100" ] || fail "high: $(cat "$T/rp")"
run_pfd "  audio_resampler=max
media_vol_steps=30"
grep -qx -- '-n ro.audio.resampler.psd.stopband 179' "$T/rp" || fail "max stopband: $(cat "$T/rp")"
grep -qx -- '-n ro.audio.resampler.psd.halflength 320' "$T/rp" || fail "max length: $(cat "$T/rp")"
grep -qx -- '-n ro.audio.resampler.psd.cutoff_percent 99' "$T/rp" || fail "max cutoff: $(cat "$T/rp")"
grep -qx -- '-n ro.config.media_vol_steps 30' "$T/rp" || fail "30 steps not written: $(cat "$T/rp")"
for hl in 160 320; do [ $((hl % 4)) -eq 0 ] || fail "half length $hl is not a multiple of 4"; done
run_pfd "audio_resampler=stock
media_vol_steps=50"
[ "$(cat "$T/rp")" = "-n ro.config.media_vol_steps 50" ] || fail "50 steps: $(cat "$T/rp")"
run_pfd "audio_resampler=max
media_vol_steps=50" 0
[ ! -s "$T/rp" ] || fail "audio category off still wrote: $(cat "$T/rp")"
cat > "$T/dumpsys_audio" <<'S'
Stream volumes (device: index)
- STREAM_VOICE_CALL:
   Muted: false
   Min: 1
   Max: 5
- STREAM_RING:
   Muted: false
   Min: 0
   Max: 7
- STREAM_MUSIC:
   Muted: false
   Muted Internally: false
   Min: 0
   Max: __MAX__
   streamVolume:6
   Current: 2 (speaker): 6, 4 (headset): 9
- STREAM_ALARM:
   Muted: false
   Min: 1
   Max: 7
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = audio ] && sed "s/__MAX__/$FAKE_MAX/" "$FAKE_DUMP"
exit 0
S
cat > "$T/bin/getprop" <<'S'
#!/bin/sh
case "$1" in
  ro.audio.resampler.psd.stopband) printf '%s\n' "${FAKE_SB:-}" ;;
  ro.audio.resampler.psd.halflength) printf '%s\n' "${FAKE_HL:-}" ;;
  ro.audio.resampler.psd.enable_at_samplerate) printf '%s\n' "${FAKE_EN:-}" ;;
  ro.config.media_vol_steps) printf '%s\n' "${FAKE_VS:-}" ;;
esac
S
chmod +x "$T/bin/dumpsys" "$T/bin/getprop"
A="$ROOT/action.sh"
_as="$(grep -n '^_a_rs="$(_cfg audio_resampler)"$' "$A" | cut -d: -f1)"
[ -n "$_as" ] || fail "action screen does not report the resampler"
_ae="$(awk -v s="$_as" 'NR>s && /^_a_vs=/ {f=1} f && /^esac$/ {print NR; exit}' "$A")"
sed -n "${_as},${_ae}p" "$A" > "$T/action_block.sh"
{
  grep -E '^T_A_(RS|VS)_[A-Z]+=' "$A"
  echo '_f() { _sfmt="$1"; shift; printf "$_sfmt\n" "$@"; }'
  echo '_cfg() { sed -n "s/^$1=//p" "$T_CONF" | head -1; }'
  cat "$T/action_block.sh"
} > "$T/action_run.sh"
act() {
  printf '%s\n' "$1" > "$T/act.conf"
  PATH="$T/bin:$PATH" T_CONF="$T/act.conf" FAKE_DUMP="$T/dumpsys_audio" FAKE_MAX="$2" \
    FAKE_SB="$3" FAKE_VS="$4" sh "$T/action_run.sh"
}
o="$(act "audio_resampler=high
media_vol_steps=30" 30 140 30)"
printf '%s\n' "$o" | grep -q 'resampler: high (active)' || fail "action: live resampler not confirmed: $o"
printf '%s\n' "$o" | grep -q 'media volume: 30 steps (Android confirms)' || fail "action: live steps not confirmed: $o"
o="$(act "audio_resampler=max
media_vol_steps=50" 15 140 "")"
printf '%s\n' "$o" | grep -q 'resampler: max - takes effect after the next reboot' || fail "action: pending resampler: $o"
printf '%s\n' "$o" | grep -q 'media volume: 50 steps - takes effect after the next reboot' || fail "action: pending steps: $o"
o="$(act "audio_resampler=stock
media_vol_steps=50" 16 "" 50)"
printf '%s\n' "$o" | grep -q 'media volume: 16 steps - this ROM ignores the 50 asked for' || fail "action: ignored steps: $o"
printf '%s\n' "$o" | grep -q resampler && fail "action: stock resampler reported: $o"
o="$(act "audio_resampler=stock
media_vol_steps=stock" 15 "" "")"
[ -z "$o" ] || fail "action: stock printed lines: $o"
for l in ar de es fr hy id it pt ru tr uk zh; do
  for k in T_A_RS_OK T_A_RS_WAIT T_A_VS_OK T_A_VS_IGN T_A_VS_WAIT; do
    grep -q "^$k=" "$ROOT/runtime/i18n/action_$l.sh" || fail "action_$l.sh lacks $k"
  done
  [ "$(sed -n 's/^T_A_VS_IGN=//p' "$ROOT/runtime/i18n/action_$l.sh" | grep -o '%s' | wc -l)" -eq 2 ] || fail "action_$l.sh T_A_VS_IGN must keep two values"
done
D="$ROOT/tools/asb_diag.sh"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
_ds="$(grep -n '^_rs_c="$(cfg audio_resampler)"$' "$D" | cut -d: -f1)"
[ -n "$_ds" ] || fail "asbdiag does not check the resampler"
_de="$(awk -v s="$_ds" 'NR>s && /^_mv_c=/ {f=1} f && /^esac$/ {print NR; exit}' "$D")"
{
  echo 'V() { echo "V|$1|$2|$3"; }'
  echo 'NOTE() { echo "NOTE|$1"; }'
  echo 'OFF() { echo "OFF|$1|$2"; }'
  echo 'gp() { getprop "$1"; }'
  echo 'cfg() { sed -n "s/^$1=//p" "$T_CONF" | head -1; }'
  sed -n "${_ds},${_de}p" "$D"
} > "$T/diag_run.sh"
diag() {
  printf '%s\n' "$1" > "$T/diag.conf"
  PATH="$T/bin:$PATH" T_CONF="$T/diag.conf" FAKE_DUMP="$T/dumpsys_audio" FAKE_MAX="$2" \
    FAKE_SB="$3" FAKE_HL="$4" FAKE_EN=44100 FAKE_VS="$5" sh "$T/diag_run.sh"
}
o="$(diag "audio_resampler=max
media_vol_steps=50" 50 179 320 50)"
printf '%s\n' "$o" | grep -q '^V|resampler max .*|179/320|179/320$' || fail "asbdiag: live max not verified: $o"
printf '%s\n' "$o" | grep -q '^V|media volume steps (STREAM_MUSIC Max)|50|50$' || fail "asbdiag: live steps not verified: $o"
o="$(diag "audio_resampler=high
media_vol_steps=30" 15 "" "" "")"
printf '%s\n' "$o" | grep -q '^NOTE|audio_resampler=high is not live yet (stopband/halflength <ROM default>)' || fail "asbdiag: pending resampler: $o"
printf '%s\n' "$o" | grep -q '^NOTE|media_vol_steps=30 is not live yet (Android uses 15 steps)' || fail "asbdiag: pending steps: $o"
printf '%s\n' "$o" | grep -q '^V|' && fail "asbdiag: a pending setting counted as a check: $o"
o="$(diag "audio_resampler=stock
media_vol_steps=30" 16 90 32 30)"
printf '%s\n' "$o" | grep -q '^NOTE|ro.config.media_vol_steps=30 is set, yet the audio service uses 16 steps' || fail "asbdiag: ignored steps: $o"
printf '%s\n' "$o" | grep -q '^OFF|resampler quality - audio_resampler=stock, stopband/halflength 90/32|audio_resampler$' || fail "asbdiag: stock resampler: $o"
o="$(diag "audio_resampler=stock
media_vol_steps=stock" 15 "" "" "")"
printf '%s\n' "$o" | grep -q '^OFF|media volume steps - media_vol_steps=stock, Android uses 15 steps|media_vol_steps$' || fail "asbdiag: stock steps: $o"
echo "PASS audio prop tweaks: stock writes nothing, high/max/30/50 write exactly their props before Android starts, action and asbdiag tell live, pending and ignored apart"
