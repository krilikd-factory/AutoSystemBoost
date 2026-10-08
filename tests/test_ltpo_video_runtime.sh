#!/bin/sh
# Runtime: ltpo_video lowers the peak refresh only during quiet video playback and gives
# it back at once - on the first touch, when playback stops, when switched off, and after
# a crash. Stubs replay the field formats (SurfaceFlinger requestedFrameRate, display
# modes) and a touchscreen that "touches" when a flag file appears.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
fail=0; f() { echo "FAIL ltpo video: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/mod/runtime" "$T/d" "$T/snd/card0/pcm0p/sub0" "$T/bl/panel0"
cp "$ROOT/runtime/asb_ltpo_video.sh" "$T/mod/runtime/"
echo 900 > "$T/bl/panel0/brightness"
echo "state: RUNNING" > "$T/snd/card0/pcm0p/sub0/status"
printf 'screen=1\nstate=MODERATE\n' > "$T/rstate"
echo "165.0" > "$T/peak"
cat > "$T/sf" <<'X'
 │  └─ com.google.android.youtube/Shell$HomeActivity#3372 requestedFrameRate: {0.00 Hz FrameRateCompatibility::Default FrameRateCategory::NoPreference} pid=5401 uid=10658 z=0
 │     └─ 435dddb SurfaceView[com.google.andro[...]](BLAST)#3377 requestedFrameRate: {30.00 Hz FrameRateCompatibility::ExactOrMultiple FrameRateCategory::Default} pid=5401 uid=10658 z=0
 │  └─ StatusBar#105 requestedFrameRate: {0.00 Hz FrameRateCompatibility::Default FrameRateCategory::Normal} pid=10675 uid=10283 z=0
X
cat > "$T/disp" <<'X'
      DisplayMode{id=0, width=1272, height=2772, peakRefreshRate=120.00001, vsyncRate=120.00001, group=0}
      DisplayMode{id=1, width=1272, height=2772, peakRefreshRate=60.000004, vsyncRate=60.000004, group=0}
      DisplayMode{id=2, width=1272, height=2772, peakRefreshRate=90.0, vsyncRate=90.0, group=0}
      DisplayMode{id=5, width=1272, height=2772, peakRefreshRate=165.0, vsyncRate=165.0, group=0}
X
cat > "$T/bin/settings" <<'S'
#!/bin/sh
case "$1" in
  get) [ -f "$PEAK" ] && cat "$PEAK" || echo null ;;
  put) echo "$4" > "$PEAK" ;;
  delete) rm -f "$PEAK" ;;
esac
S
cat > "$T/bin/getevent" <<'S'
#!/bin/sh
if [ "$1" = -pl ]; then
  echo "add device 1: /dev/input/event9"; echo "    ABS (0003): ABS_MT_POSITION_X : value 0"; exit 0
fi
while [ ! -f "$TOUCH" ]; do sleep 0.1; done
rm -f "$TOUCH"
exit 0
S
cat > "$T/bin/getprop" <<'S'
#!/bin/sh
echo 1
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" PEAK="$T/peak" TOUCH="$T/touch" MODDIR="$T/mod" \
  ASB_LTPO_STATE_DIR="$T/d" ASB_LTPO_RSTATE="$T/rstate" ASB_LTPO_ASOUND="$T/snd" \
  ASB_LTPO_BACKLIGHT="$T/bl" ASB_LTPO_SF_DUMP="$T/sf" ASB_LTPO_DISPLAY_DUMP="$T/disp" ASB_LTPO_QUIET_S=1
V="$T/mod/runtime/asb_ltpo_video.sh"
cleanup() { echo ltpo_video=0 > "$T/mod/config/governor.conf"; sh "$V" stop >/dev/null 2>&1; touch "$T/touch"; sleep 0.3; rm -rf "$T"; }
trap cleanup EXIT
wait_for() {   # $1 = expected peak, $2 = tenths of a second
  _i=0
  while [ "$_i" -lt "$2" ]; do
    [ "$(cat "$T/peak" 2>/dev/null)" = "$1" ] && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}

# Decision on the field formats.
[ "$(sh "$V" decide)" = 60 ] || f "30 fps ExactOrMultiple should pick 60 Hz, got $(sh "$V" decide)"
sed 's/30.00 Hz/24.00 Hz/' "$T/sf" > "$T/sf24"
[ "$(ASB_LTPO_SF_DUMP="$T/sf24" sh "$V" decide)" = none ] || f "24 fps must be left alone"
sed 's/FrameRateCategory::Normal/FrameRateCategory::High/' "$T/sf" > "$T/sfhi"
[ "$(ASB_LTPO_SF_DUMP="$T/sfhi" sh "$V" decide)" = veto_high ] || f "a High category must veto"

echo ltpo_video=1 > "$T/mod/config/governor.conf"
sh "$V" reconcile
wait_for 60.0 200 || f "did not lower during quiet playback (peak $(cat "$T/peak"))"
grep -q '^orig=165.0$' "$T/d/ltpo_video.lowered" 2>/dev/null || f "original not recorded before lowering"

# First touch: back at once, from the guard itself.
touch "$T/touch"
wait_for 165.0 10 || f "first touch did not restore within 1 s (peak $(cat "$T/peak"))"
# Quiet again: lowered again.
wait_for 60.0 200 || f "did not lower again after the touch went quiet"

# Playback stops: restored.
echo "state: SETUP" > "$T/snd/card0/pcm0p/sub0/status"
wait_for 165.0 150 || f "end of playback did not restore"
echo "state: RUNNING" > "$T/snd/card0/pcm0p/sub0/status"
wait_for 60.0 200 || f "did not lower when playback resumed"

# Someone else changes the peak while lowered: left as they set it.
echo "120.0" > "$T/peak"
sleep 2.5
[ "$(cat "$T/peak")" = 120.0 ] || f "a value set by someone else was overwritten"

# Switched off: stopped and restored.
echo ltpo_video=0 > "$T/mod/config/governor.conf"
sh "$V" reconcile
[ -f "$T/d/ltpo_video.lowered" ] && f "record kept after off"

# Crash/reboot mid-video: the record is repaired by reconcile without a watcher.
printf 'orig=144.0\nset=60.0\ncontent=30\nsince=1\n' > "$T/d/ltpo_video.lowered"
echo "60.0" > "$T/peak"
sh "$V" reconcile
[ "$(cat "$T/peak")" = 144.0 ] || f "reconcile did not repair a lowered peak left by a crash"

grep -q 'asb_ltpo_video.sh" stop' "$ROOT/uninstall.sh" || f "uninstall does not stop the watcher"
grep -q 'asb_ltpo_video.sh" reconcile' "$ROOT/service.sh" || f "boot does not reconcile the watcher"

[ "$fail" = 0 ] && echo "PASS ltpo video runtime"
exit "$fail"
