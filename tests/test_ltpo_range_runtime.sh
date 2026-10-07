#!/bin/sh
# Runtime: ltpo_force=1 opens the Android refresh range at both ends (no floor, peak = the
# panel's highest mode), records what it found first, and gives exactly that back on off.
# A video lowering in progress is never recorded as the user's own peak.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL ltpo range: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/mod/runtime" "$T/d" "$T/s"
cp "$ROOT/runtime/asb_ltpo_apply.sh" "$T/mod/runtime/"
touch "$T/mod/module.prop"
cat > "$T/disp" <<'X'
      DisplayMode{id=1, width=1272, height=2772, peakRefreshRate=60.000004, vsyncRate=60.000004, group=0}
      DisplayMode{id=2, width=1272, height=2772, peakRefreshRate=90.0, vsyncRate=90.0, group=0}
      DisplayMode{id=4, width=1272, height=2772, peakRefreshRate=144.00002, vsyncRate=144.00002, group=0}
      DisplayMode{id=5, width=1272, height=2772, peakRefreshRate=165.0, vsyncRate=165.0, group=0}
X
cat > "$T/bin/settings" <<'S'
#!/bin/sh
case "$1" in
  get) [ -f "$SD/$3" ] && cat "$SD/$3" || echo null ;;
  put) echo "$4" > "$SD/$3" ;;
  delete) rm -f "$SD/$3" ;;
esac
S
chmod +x "$T/bin/settings"
export PATH="$T/bin:$PATH" SD="$T/s" MODDIR="$T/mod" ASB_LTPO_STATE_DIR="$T/d" ASB_LTPO_DISPLAY_DUMP="$T/disp"
A="$T/mod/runtime/asb_ltpo_apply.sh"
echo 120.0 > "$T/s/peak_refresh_rate"; echo 60.0 > "$T/s/min_refresh_rate"

echo ltpo_force=1 > "$T/mod/config/governor.conf"; sh "$A" apply
[ "$(cat "$T/s/peak_refresh_rate")" = 165.0 ] || f "peak not raised to the panel maximum: $(cat "$T/s/peak_refresh_rate")"
[ -f "$T/s/min_refresh_rate" ] && f "refresh floor not removed"
grep -qx 'peak=120.0' "$T/d/ltpo_range.orig" && grep -qx 'min=60.0' "$T/d/ltpo_range.orig" || f "baseline not recorded"
# Re-apply must not overwrite the baseline with ASB's own values.
sh "$A" apply
grep -qx 'peak=120.0' "$T/d/ltpo_range.orig" || f "baseline overwritten on re-apply"

echo ltpo_force=0 > "$T/mod/config/governor.conf"; sh "$A" apply
[ "$(cat "$T/s/peak_refresh_rate")" = 120.0 ] && [ "$(cat "$T/s/min_refresh_rate")" = 60.0 ] || f "off did not restore peak/min"
[ -f "$T/d/ltpo_range.orig" ] && f "baseline kept after restore"

# Unset values come back as unset.
rm -f "$T/s/peak_refresh_rate" "$T/s/min_refresh_rate"
echo ltpo_force=1 > "$T/mod/config/governor.conf"; sh "$A" apply
grep -qx 'peak=__unset' "$T/d/ltpo_range.orig" || f "unset peak not recorded as unset"
echo ltpo_force=0 > "$T/mod/config/governor.conf"; sh "$A" apply
[ -f "$T/s/peak_refresh_rate" ] && f "unset peak not deleted on restore"

# Booting into a lowered video peak: the video record's original is the user's peak.
echo 60.0 > "$T/s/peak_refresh_rate"
printf 'orig=144.0\nset=60.0\ncontent=30\nsince=1\n' > "$T/d/ltpo_video.lowered"
echo ltpo_force=1 > "$T/mod/config/governor.conf"; sh "$A" apply
grep -qx 'peak=144.0' "$T/d/ltpo_range.orig" || f "a lowered video peak was recorded as the user's"
[ "$(cat "$T/s/peak_refresh_rate")" = 60.0 ] || f "range fought the video watcher while lowered"
grep -qx 'orig=165.0' "$T/d/ltpo_video.lowered" || f "open peak not handed to the video record"

[ "$fail" = 0 ] && echo "PASS ltpo range runtime"
exit "$fail"
