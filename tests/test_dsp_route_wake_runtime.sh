#!/bin/sh
# Runtime (fix159): the DSP route watcher follows the route on phones whose kernel exposes no
# PCM state, and the screen coming on is noticed in seconds.
#
# Owner's OP15 (AudioReach): music went to Bluetooth while persist.asb.dsp.route still read
# "speaker" - asbdiag at 19:13:57 and the action screen at 19:14:45 both said "playing on
# speaker -> not processed" while STREAM_MUSIC was on bt_a2dp, and the capture's "alsa pcm
# status" section is empty in all 22 audio snapshots of the day, speaker playback included.
# The watcher's only cheap playback signal is that PCM state, so on this phone it never dumped
# the audio service with the screen off, slept through its 60 s nap after the screen came on and
# then waited out a 30 s back-off: about 80 s of unboosted Bluetooth, then +25 dB mid-track.
#
# The REAL watcher loop is cut out of service.sh and run in virtual time (fake sleep advances
# SECONDS), with fake dumpsys / getprop / resetprop, a fake /proc with an audioserver whose
# AudioOut threads count their runs in schedstat, and the REAL runtime/asb_audio_activity.sh.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SVC="${ASB_TEST_SERVICE:-$ROOT/service.sh}"
T="${ASB_TEST_KEEP:-$(mktemp -d)}"; [ -n "${ASB_TEST_KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL dsp route wake: $*" >&2; fail=1; }

body="$T/watch.sh"
awk '/^  _prev_route=""$/ { on = 1 } on && /^\) >\/dev\/null 2>&1 &$/ { exit } on { print }' "$SVC" > "$body"
grep -q 'dsp route changed' "$body" || { echo "FAIL dsp route wake: watcher block not found" >&2; exit 1; }

# ---- 1. the activity detector on its own -------------------------------------------------
. "$ROOT/runtime/asb_audio_activity.sh"
P="$T/p1"; mkdir -p "$P/1/task/1" "$P/77/task/77" "$P/77/task/80" "$P/77/task/81" "$P/77/task/82"
echo init > "$P/1/comm"; echo init > "$P/1/task/1/comm"; echo 5 > "$P/1/task/1/schedstat"
echo audioserver > "$P/77/comm"
echo audioserver > "$P/77/task/77/comm"; echo "1 2 900" > "$P/77/task/77/schedstat"
echo AudioOut_D  > "$P/77/task/80/comm"; echo "1 2 1000" > "$P/77/task/80/schedstat"
echo AudioOut_85 > "$P/77/task/81/comm"; echo "1 2 400" > "$P/77/task/81/schedstat"
echo binder:77_2 > "$P/77/task/82/comm"; echo "1 2 50" > "$P/77/task/82/schedstat"
ASB_AUDIO_PROC="$P"; ASB_AUDIO_ASOUND="$T/no_asound"; export ASB_AUDIO_PROC ASB_AUDIO_ASOUND
asb_audio_sig
[ "$_aa_pid" = 77 ] || f "audioserver not found in /proc (pid=$_aa_pid)"
[ -z "$_aa_mode" ] || f "a mode claimed before any baseline: $_aa_mode"
[ -z "$_aa_sig" ] || f "activity claimed on the first look: $_aa_sig"
echo "1 2 460" > "$P/77/task/81/schedstat"; echo "1 2 9000" > "$P/77/task/77/schedstat"; echo "1 2 999" > "$P/77/task/82/schedstat"
asb_audio_sig
[ "$_aa_mode" = threads ] || f "thread mode not reached on the second look: $_aa_mode"
[ "$_aa_sig" = "AudioOut_85 " ] || f "active output not named (only AudioOut threads count): '$_aa_sig'"
asb_audio_sig
[ -z "$_aa_sig" ] || f "a thread that stopped running still reads as playing: '$_aa_sig'"
mkdir -p "$P/77/task/90"; echo AudioOut_95 > "$P/77/task/90/comm"; echo "1 2 30" > "$P/77/task/90/schedstat"
asb_audio_sig
[ "$_aa_sig" = "AudioOut_95 " ] || f "an output thread that just opened and runs is not seen: '$_aa_sig'"
rm -f "$P/77/task/90/schedstat"
printf 'Name:\tAudioOut_95\nvoluntary_ctxt_switches:\t100\nnonvoluntary_ctxt_switches:\t7\n' > "$P/77/task/90/status"
asb_audio_sig
printf 'Name:\tAudioOut_95\nvoluntary_ctxt_switches:\t140\nnonvoluntary_ctxt_switches:\t9\n' > "$P/77/task/90/status"
asb_audio_sig
[ "$_aa_sig" = "AudioOut_95 " ] || f "context switches not used where schedstat is missing: '$_aa_sig'"
mkdir -p "$P/99/task/99" "$P/99/task/101"; echo audioserver > "$P/99/comm"; echo audioserver > "$P/99/task/99/comm"
echo AudioOut_D > "$P/99/task/101/comm"; echo "1 2 10" > "$P/99/task/101/schedstat"
rm -rf "$P/77"
asb_audio_sig
[ "$_aa_pid" = 99 ] || f "audioserver restart not followed (pid=$_aa_pid)"
[ -z "$_aa_sig" ] && [ -z "$_aa_mode" ] || f "a restarted audioserver compared against the old one: mode=$_aa_mode sig='$_aa_sig'"
mkdir -p "$T/asound/card0/pcm0p/sub0" "$T/asound/card0/pcm1p/sub0"
echo closed > "$T/asound/card0/pcm0p/sub0/status"; printf 'state: RUNNING\nowner_pid   : 1\n' > "$T/asound/card0/pcm1p/sub0/status"
ASB_AUDIO_ASOUND="$T/asound" asb_audio_sig
[ "$_aa_mode" = pcm ] || f "PCM state not preferred where the kernel has it: $_aa_mode"
[ "$_aa_sig" = "$T/asound/card0/pcm1p/sub0/status " ] || f "PCM signature changed format: '$_aa_sig'"
echo "screen=1" > "$T/st"; echo "capacity=50" >> "$T/st"
ASB_AUDIO_STATE="$T/st" asb_audio_screen; [ "$_aa_s" = 1 ] || f "screen state not read from the governor's file"
ASB_AUDIO_STATE="$T/none" asb_audio_screen; [ -z "$_aa_s" ] || f "a missing state file read as a screen state"
unset ASB_AUDIO_PROC ASB_AUDIO_ASOUND

# ---- 2. the real watcher loop in virtual time --------------------------------------------
# $1 = scenario name. Scenario timeline (virtual seconds):
#   t=0..   screen on, nothing playing, route published "speaker"
#   t=300   screen off
#   t=600   Bluetooth music starts (STREAM_MUSIC -> bt_a2dp, AudioOut_85 running)
#   t=873   screen on (between two 5 s slices on purpose)
run() {
  S="$T/run_$1"; rm -rf "$S"; mkdir -p "$S/mod/config" "$S/mod/runtime" "$S/props" "$S/proc/50/task/50" "$S/proc/50/task/51" "$S/proc/50/task/52"
  cp "$ROOT/runtime/asb_audio_activity.sh" "$S/mod/runtime/" 2>/dev/null || true
  printf 'dsp_outputs=bt\ndsp_loudness=25\n' > "$S/mod/config/governor.conf"
  echo 1 > "$S/props/persist.asb.dsp.enable"; echo speaker > "$S/props/persist.asb.dsp.route"
  echo audioserver > "$S/proc/50/comm"; echo audioserver > "$S/proc/50/task/50/comm"
  echo AudioOut_D > "$S/proc/50/task/51/comm"; echo AudioOut_85 > "$S/proc/50/task/52/comm"
  echo "0 0 100" > "$S/proc/50/task/50/schedstat"; echo "0 0 100" > "$S/proc/50/task/51/schedstat"; echo "0 0 100" > "$S/proc/50/task/52/schedstat"
  [ "$1" = nodetect ] && rm -rf "$S/proc/50"
  cat > "$S/run.sh" <<EOF
S="$S"; MODDIR="\$S/mod"; SC="$1"
ASB_AUDIO_PROC="\$S/proc"; ASB_AUDIO_ASOUND="\$S/no_asound"; ASB_AUDIO_STATE="\$S/state"
export ASB_AUDIO_PROC ASB_AUDIO_ASOUND ASB_AUDIO_STATE
SECONDS=0; _runs=100
_scr() { if [ "\$SECONDS" -ge 300 ] && [ "\$SECONDS" -lt 873 ]; then echo 0; else echo 1; fi; }
_play() { [ "\$SECONDS" -ge 600 ]; }
_world() {
  printf 'screen=%s\n' "\$(_scr)" > "\$S/state"
  if _play && [ -d "\$S/proc/50" ]; then _runs=\$((_runs + 120)); echo "0 0 \$_runs" > "\$S/proc/50/task/52/schedstat"; fi
  if [ "\$SC" = desync ] && [ "\$SECONDS" -ge 1000 ] && [ ! -e "\$S/desynced" ]; then
    echo speaker > "\$S/props/persist.asb.dsp.route"; : > "\$S/desynced"
  fi
}
sleep() { SECONDS=\$((SECONDS + \$1)); _world; [ "\$SECONDS" -gt 1300 ] && exit 0; return 0; }
asb_screen_state() { [ "\$(_scr)" = 1 ] && echo true || echo false; }
asb_log() { :; }
getprop() { cat "\$S/props/\$1" 2>/dev/null; }
resetprop() { [ "\$1" = -n ] && shift; printf '%s' "\$2" > "\$S/props/\$1"; [ "\$1" = persist.asb.dsp.route ] && echo "\$SECONDS \$2" >> "\$S/routes"; return 0; }
setprop() { resetprop -n "\$@"; }
pkill() { return 0; }
killall() { return 0; }
dumpsys() {
  echo "\$SECONDS" >> "\$S/dumps"
  [ "\$1" = audio ] || return 0
  printf '%s\n' '- STREAM_VOICE_CALL:' '   Devices: earpiece(1)'
  if _play; then
    printf '%s\n' '- STREAM_MUSIC:' '   Muted: false' '   Devices: bt_a2dp(80)' '- STREAM_ALARM:' '   Devices: speaker(2)'
    printf '%s\n' '  AudioPlaybackConfiguration piid:10279 deviceIds:[1298] type:android.media.AudioTrack u/pid:10483/18501 state:started attr:AudioAttributes: usage=USAGE_MEDIA'
  else
    printf '%s\n' '- STREAM_MUSIC:' '   Muted: false' '   Devices: speaker(2)' '- STREAM_ALARM:' '   Devices: speaker(2)'
  fi
}
_world
EOF
  cat "$body" >> "$S/run.sh"
  sh "$S/run.sh" >/dev/null 2>&1
}
first_bt() { awk '$2 == "bt" && $1 >= '"${2:-0}"' { print $1; exit }' "$T/run_$1/routes" 2>/dev/null; }
dumps_between() { awk -v a="$2" -v b="$3" '$1 >= a && $1 < b { n++ } END { print n + 0 }' "$T/run_$1/dumps" 2>/dev/null; }

run detect
t="$(first_bt detect)"
[ -n "$t" ] || f "Bluetooth route never published (phone without PCM state)"
[ -n "$t" ] && [ "$t" -le 680 ] || f "Bluetooth playback started with the screen off at t=600 was published at t=${t:-never}, want by t=680 (screen still off)"
n="$(dumps_between detect 60 300)"
[ "$n" -le 2 ] || f "$n audio dumps in 4 idle screen-on minutes - nothing plays, the thread signal should hold them off"

run nodetect
t="$(first_bt nodetect)"
[ -n "$t" ] && [ "$t" -le 885 ] || f "screen came on at t=873 with the route stale, published at t=${t:-never}, want by t=885"

run desync
t="$(first_bt desync 1000)"
[ -n "$t" ] && [ "$t" -le 1060 ] || f "route overwritten to speaker at t=1000 while Bluetooth plays was not put back (t=${t:-never})"

[ "$fail" = 0 ] && echo "PASS dsp route wake: Bluetooth route followed with the screen off on a phone without PCM state, screen-on noticed within seconds, an overwritten route republished"
exit "$fail"
