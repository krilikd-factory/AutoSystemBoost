#!/bin/sh
# Runtime + contract: fix67 field reports.
#  1. A capture started from the manager app escapes the app's cgroup (frozen/killed with
#     the app on KernelSU: a "24 h" capture held ten minutes of samples).
#  2. bt_sco is classified as the call link - in the logkit (was route=none) and in the DSP
#     route publishers (was "bt", so a Bluetooth boost processed a VoIP call).
#  3. A SystemUI restart during a capture is recorded with the crash/ANR evidence.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL logkit detach/sysui/sco: $*" >&2; fail=1; }
C="$ROOT/tools/logkit/_asb_logkit_common.sh"

run_fn() {   # source the common file in a subshell and run one function
  ( set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$C" >/dev/null 2>&1; "$@" )
}

# --- 1. cgroup escape -------------------------------------------------------------------
printf '0::/uid_10853/pid_4242\n' > "$T/cg"
true > "$T/root1"; true > "$T/root2"
out="$(ASB_LK_CG_FILE="$T/cg" ASB_LK_CG_ROOTS="$T/root1 $T/root2 $T/absent" run_fn lk_escape_app_cgroup 777)"
[ "$(cat "$T/root1")" = 777 ] && [ "$(cat "$T/root2")" = 777 ] || f "pid not written to the root groups"
# The fake cgroup file still says uid_ (nothing moved it for real) -> must report failed,
# never claim success it cannot see.
[ "$out" = failed ] || f "escape claimed '$out' while the process is still in uid_"
printf '0::/\n' > "$T/cg2"
out="$(ASB_LK_CG_FILE="$T/cg2" ASB_LK_CG_ROOTS="$T/root1" run_fn lk_escape_app_cgroup 778)"
[ "$out" = not_needed ] || f "a process outside any app group should not be moved ($out)"
grep -Fq 'LK_CGROUP_ESCAPE="$(lk_escape_app_cgroup $$)"' "$C" || f "lk_init does not escape the app cgroup"
grep -q '_recorder_cgroup.txt' "$C" || f "capture does not record its cgroup"

# --- 2. bt_sco classification ---------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/dumpsys" <<'X'
#!/bin/sh
cat <<'D'
Audio mode:
- mode (internal) = MODE_IN_COMMUNICATION
- mode (external) = MODE_IN_COMMUNICATION
mode owner: pid: 5555 uid: 10499
  AudioPlaybackConfiguration piid:1 deviceIds:[3] type:android.media.AudioTrack u/pid:10499/5555 state:started attr:x
- STREAM_MUSIC:
   Muted: false
   Devices: bt_sco
- STREAM_ALARM:
   Devices: speaker
D
X
chmod +x "$T/bin/dumpsys"
res="$(PATH="$T/bin:$PATH" run_fn sh -c 'true' ; ( set +u; PATH="$T/bin:$PATH"; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$C" >/dev/null 2>&1; lk_dumpsys() { dumpsys "$@"; }; lk_sample_audio; echo "$LK_AUDIO_ROUTE|$LK_AUDIO_MODE|$LK_AUDIO_MODE_OWNER" ))"
case "$res" in
  "bt_sco|MODE_IN_COMMUNICATION|mode owner: pid: 5555 uid: 10499"*) : ;;
  *) f "bt_sco/mode not classified: '$res'" ;;
esac
grep -q 'bt|bt_le|bt_sco) _apn="audio_bt"' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "bt_sco not mapped to a Bluetooth audio phase"
grep -q '\*bt_sco\*|\*BLUETOOTH_SCO\*) _now="call"' "$ROOT/service.sh" || f "live DSP route watcher still calls SCO bt"
grep -q '\*bt_sco\*|\*BLUETOOTH_SCO\*) _asb_route="call"' "$ROOT/runtime/asb_audio_apply.sh" || f "audio apply still calls SCO bt"
grep -q 'call:\*) _dsp_ra=0' "$ROOT/runtime/asb_audio_apply.sh" || f "call route not excluded from processing"

# --- 3. SystemUI restart recorder -------------------------------------------------------
cat > "$T/bin/pidof" <<'X'
#!/bin/sh
cat "$SYSUI_PIDF"
X
cat > "$T/bin/logcat" <<'X'
#!/bin/sh
echo "10-08 19:54:30 E AndroidRuntime: FATAL EXCEPTION: main Process: com.android.systemui"
X
chmod +x "$T/bin/"*
mkdir -p "$T/out"
echo 1000 > "$T/pid"
( set +u; PATH="$T/bin:$PATH"; SYSUI_PIDF="$T/pid"; export SYSUI_PIDF
  LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$C" >/dev/null 2>&1
  lk_dumpsys() { echo "dropbox $*"; }
  LK_OUT_DIR="$T/out"
  lk_sysui_watch_row; lk_sysui_watch_row
  echo 2000 > "$T/pid"; lk_sysui_watch_row; lk_sysui_watch_row
  echo "$LK_SYSUI_RESTARTS" > "$T/count" )
[ "$(cat "$T/count")" = 1 ] || f "restart count $(cat "$T/count") (want 1)"
grep -q 'SYSTEMUI RESTART .* pid 1000 -> 2000' "$T/out/sysui_restarts.txt" || f "restart not recorded"
grep -q 'FATAL EXCEPTION' "$T/out/sysui_restarts.txt" || f "crash evidence not captured"
grep -q 'dropbox --print system_app_anr' "$T/out/sysui_restarts.txt" || f "ANR dropbox not captured"
grep -q 'lk_sysui_watch_row' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "full-day capture does not watch SystemUI"
grep -q 'SYSTEMUI RESTARTS' "$ROOT/tools/logkit/asb_log_full_day.sh" || f "report has no SystemUI section"

[ "$fail" = 0 ] && echo "PASS logkit detach/sysui/sco runtime"
exit "$fail"
