#!/bin/sh
# Runtime (fix135): the DSP gain no longer sinks when the volume is changed.
#
# Field report: "loudness, gain and voice only work after I open the WebUI; when I change the
# volume the sound sinks and goes flat; open the WebUI again and it is back". The gain's heat
# back-off read cpu_max_c - the hottest core at that instant - whenever the Smart tuner ran,
# and the tuner runs exactly when that number has just jumped (the volume panel animating) or
# the foreground changed (opening the WebUI). +25 dB became +12 or +8 dB on a cool phone and
# stayed there until the next app switch.
#
# The REAL asb_audio_apply.sh (mirror mode, which the tuner calls) and the REAL helpers run
# here against a mocked property store and mocked Android commands.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL dsp heat back-off: $*" >&2; exit 1; }
MOD="$TMP/mod"; BIN="$TMP/bin"
mkdir -p "$MOD/config" "$MOD/runtime" "$BIN"
cp "$ROOT_DIR/runtime/asb_audio_apply.sh" "$ROOT_DIR/runtime/asb_dsp_thermal.sh" \
   "$ROOT_DIR/runtime/asb_dsp_live.sh" "$MOD/runtime/"
printf 'dsp_loudness=25\ndsp_bass=2\ndsp_voice=4\ndsp_outputs=speaker\n' > "$MOD/config/governor.conf"
PROPS="$TMP/props"; : > "$PROPS"
cat > "$BIN/getprop" <<'EOF'
#!/bin/sh
echo "$1" >> "$GP_LOG"
grep -m1 "^$1=" "$PROPS" 2>/dev/null | cut -d= -f2-
EOF
cat > "$BIN/resetprop" <<'EOF'
#!/bin/sh
[ "$1" = "-n" ] && shift
grep -v "^$1=" "$PROPS" > "$PROPS.t" 2>/dev/null || true
printf '%s=%s\n' "$1" "$2" >> "$PROPS.t"; mv "$PROPS.t" "$PROPS"
EOF
cp "$BIN/resetprop" "$BIN/setprop"
cat > "$BIN/pkill" <<'EOF'
#!/bin/sh
echo "$*" >> "$PK_LOG"
EOF
cat > "$BIN/dumpsys" <<'EOF'
#!/bin/sh
case "$1" in audio) cat "$AUDIO_DUMP" 2>/dev/null ;; media.audio_flinger) cat "$AF_DUMP" 2>/dev/null ;; esac
EOF
chmod 0755 "$BIN"/*
export PATH="$BIN:$PATH" PROPS GP_LOG="$TMP/gp.log" PK_LOG="$TMP/pk.log" \
       AUDIO_DUMP="$TMP/audio.dump" AF_DUMP="$TMP/af.dump" \
       ASB_DSP_TH_STATE="$TMP/dsp_thermal" ASB_DSP_TH_BAT="$TMP/bat_temp"
prop() { grep -m1 "^$1=" "$PROPS" | cut -d= -f2-; }
setp() { resetprop -n "$1" "$2"; }
mirror() { MODDIR="$MOD" sh "$MOD/runtime/asb_audio_apply.sh" mirror >/dev/null; }
bat() { echo "$1" > "$TMP/bat_temp"; }
setp persist.asb.dsp.enable 1
setp persist.asb.dsp.outputs speaker
setp persist.asb.dsp.route speaker
setp persist.asb.dsp.gain_mb 800        # what the old CPU rule left behind

# 1. Cool phone (battery 29.5 C): full gain, whatever the CPU did a second ago. The old rule
#    gave 800 here with cpu_max_c=70.
bat 295
mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "cool phone: gain $(prop persist.asb.dsp.gain_mb), want 2500"
[ "$(prop persist.vendor.asb.dsp.gain_mb)" = 2500 ] || fail "vendor copy not updated"
grep -q 'USR1' "$PK_LOG" || fail "the attach daemon was not woken for the restored gain"
grep -qx 'reason=cool' "$ASB_DSP_TH_STATE" || fail "decision not recorded"

# 2. Hot on the speaker: one step at 42 C, and it holds until 40 C (hysteresis).
: > "$PK_LOG"
bat 425; mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 1200 ] || fail "42.5 C on the speaker: $(prop persist.asb.dsp.gain_mb), want 1200"
grep -qx 'reason=hot_speaker' "$ASB_DSP_TH_STATE" || fail "hot_speaker not recorded"
bat 410; mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 1200 ] || fail "41 C dropped the back-off (no hysteresis)"
: > "$PK_LOG"; mirror
[ -s "$PK_LOG" ] && fail "the daemon was woken although nothing changed"
bat 395; mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "39.5 C: back-off not released"

# 3. Two steps at 45 C; back to one step only under 43 C.
bat 455; mirror; [ "$(prop persist.asb.dsp.gain_mb)" = 800 ] || fail "45.5 C: want 800"
bat 440; mirror; [ "$(prop persist.asb.dsp.gain_mb)" = 800 ] || fail "44 C left step 2 too early"
bat 425; mirror; [ "$(prop persist.asb.dsp.gain_mb)" = 1200 ] || fail "42.5 C after step 2: want 1200"

# 4. Bluetooth and wired are never reduced - the amplifier is not in the phone / drives mW.
setp persist.asb.dsp.outputs bt; setp persist.asb.dsp.route bt
bat 470; mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "Bluetooth reduced at 47 C"
grep -qx 'reason=hot_not_speaker' "$ASB_DSP_TH_STATE" || fail "hot_not_speaker not recorded"
# outputs=all: nothing keeps the route property fresh, so the music stream's own line decides.
setp persist.asb.dsp.outputs all; setp persist.asb.dsp.route bt
printf '%s\n' '- STREAM_VOICE_CALL:' '   Devices: earpiece' '- STREAM_MUSIC:' '   Muted: false' \
  '   Devices: speaker' '- STREAM_ALARM:' '   Devices: speaker' > "$AUDIO_DUMP"
mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 800 ] || fail "outputs=all on the speaker at 47 C: want 800 (stale route used)"

# 5. Unknown temperature never reduces.
rm -f "$TMP/bat_temp" "$ASB_DSP_TH_STATE"; mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "unreadable battery temperature reduced the gain"

# 6. The once-a-minute check: cool twice in a row costs no property reads past "enable".
. "$MOD/runtime/asb_dsp_thermal.sh"
bat 300; setp persist.asb.dsp.gain_requested_mb 2500; setp persist.asb.dsp.gain_mb 1200
rm -f "$ASB_DSP_TH_STATE"
MODDIR="$MOD" asb_dsp_thermal_tick
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "first check after boot did not release a held gain"
: > "$GP_LOG"
MODDIR="$MOD" asb_dsp_thermal_tick
[ "$(grep -c '' "$GP_LOG")" = 1 ] || fail "cool tick read $(grep -c '' "$GP_LOG") properties, want 1 (enable)"
setp persist.asb.dsp.enable 0; : > "$GP_LOG"; bat 480
MODDIR="$MOD" asb_dsp_thermal_tick
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "DSP off: the check touched the gain"

# 7. The step table itself.
for c in '300 0 0' '420 0 1' '450 0 2' '419 1 1' '399 1 0' '449 1 1' '450 1 2' '430 2 2' '429 2 1' '399 2 0' ' 0 0' 'x 2 0'; do
  set -- $c
  if [ $# = 3 ]; then got="$(asb_dsp_th_step "$1" "$2")"; want="$3"; else got="$(asb_dsp_th_step "" "$1")"; want="$2"; fi
  [ "$got" = "$want" ] || fail "step table: '$c' gave $got"
done
[ "$(asb_dsp_th_cap 3000 0 speaker)" = 2500 ] || fail "cap above +25 dB"
[ "$(asb_dsp_th_cap 900 1 speaker)" = 900 ] || fail "a gain under the step was raised"
[ "$(asb_dsp_th_cap 2500 2 unknown)" = 800 ] || fail "unknown route is not treated as the speaker"
[ "$(asb_dsp_th_cap 2500 2 wired)" = 2500 ] || fail "wired reduced"

# 8. Wiring: every gain writer uses the same rule; the CPU rule is gone.
A="$ROOT_DIR/runtime/asb_audio_apply.sh"
grep -q 'cpu_max_c=' "$A" && fail "asb_audio_apply.sh still reads the CPU temperature"
[ "$(grep -c 'asb_dsp_thermal_decide' "$A")" -ge 2 ] || fail "the WebUI apply path skips the heat rule"
grep -q 'asb_dsp_thermal_tick' "$ROOT_DIR/service.sh" || fail "no once-a-minute re-check"
echo "PASS dsp heat back-off: battery-based, hysteresis, loudspeaker only, re-checked and pushed at once"
