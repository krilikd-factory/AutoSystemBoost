#!/bin/sh
# Runtime (fix161): one drain measurement for every profile, Stock included, kept per profile.
#
# Asked for: the Monitor's screen-on and screen-off drain on every profile, Stock too, so the
# profiles can be compared. Screen-on drain was only counted inside the Smart tick, and Stock
# runs no governor at all. The REAL runtime/asb_drain_meter.sh is sourced and its step function
# driven through a day: screen-on use, a night, music with the screen off, charging, a gap in
# sampling, a profile switch, the file round trip, and the screen read from the backlight when
# Android's display state is not there.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
M="$ROOT/runtime/asb_drain_meter.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL drain meter: $*" >&2; fail=1; }
grep -q 'sh "$MODDIR/runtime/asb_drain_meter.sh" run' "$ROOT/service.sh" || f "service.sh does not start the meter"
_svc_line="$(grep -n 'runtime/asb_drain_meter.sh" run' "$ROOT/service.sh" | cut -d: -f1)"
awk -v L="$_svc_line" 'NR < L && /^if \[ "\$\{ASB_STOCK_PROFILE:-0\}" != "1" \]; then$/ { open = 1 } NR < L && open && /^fi$/ { open = 0 } END { exit open }' "$ROOT/service.sh" \
  || f "the meter is started inside a non-Stock branch"
grep -q '"runtime/asb_drain_meter.sh"' "$ROOT/.github/workflows/build-debug.yml" || f "CI does not require the meter"

ASB_DM_DIR="$T/asb"; ASB_DM_LIVE="$T/live"; ASB_DM_BL="$T/bl"; ASB_DM_PS="$T/ps"
export ASB_DM_DIR ASB_DM_LIVE ASB_DM_BL ASB_DM_PS
. "$M"
dm_load
rate_on() { _s="$(dm_get "$1" on_s)"; _x="$(dm_get "$1" on_x)"; [ "$_s" -ge 600 ] && [ "$_x" -gt 0 ] && echo $((_x * 360 / _s)) || echo 0; }
rate_off() { _s="$(dm_get "$1" off_s)"; _x="$(dm_get "$1" off_x)"; [ "$(dm_get "$1" off_n)" -ge 1 ] && [ "$_s" -gt 0 ] && echo $((_x * 3600 / _s)) || echo 0; }

t=1000; pct=80
i=0; while [ $i -lt 40 ]; do
  i=$((i + 1)); t=$((t + 30))
  [ $i = 10 ] && pct=79; [ $i = 25 ] && pct=78; [ $i = 40 ] && pct=77
  dm_step "$t" "$pct" 0 1 smart 0
done
[ "$(dm_get smart on_s)" = 1170 ] || f "screen-on seconds: $(dm_get smart on_s), want 1170"
[ "$(rate_on smart)" = 92 ] || f "screen-on rate x10: $(rate_on smart), want 92 (3% in 19.5 min)"
t=$((t + 30)); dm_step "$t" 77 0 0 smart 0
t=$((t + 7200)); dm_step "$t" 76 0 0 smart 0
t=$((t + 30)); dm_step "$t" 76 0 1 smart 0
[ "$(dm_get smart off_n)" = 1 ] || f "a 2 h night was not counted"
[ "$(rate_off smart)" = 49 ] || f "screen-off rate x100: $(rate_off smart), want 49 (1% in 2 h 0.5 min)"
t=$((t + 30)); dm_step "$t" 76 0 0 smart 0
t=$((t + 30)); dm_step "$t" 76 0 0 smart 1
t=$((t + 5000)); dm_step "$t" 74 0 1 smart 0
[ "$(dm_get smart off_n)" = 1 ] || f "a screen-off stretch with music was counted"
t=$((t + 30)); dm_step "$t" 74 0 0 smart 0
t=$((t + 1800)); dm_step "$t" 74 0 1 smart 0
[ "$(dm_get smart off_n)" = 1 ] || f "a 30 min screen-off stretch was counted"
_before="$(dm_get smart on_s)"
t=$((t + 30)); dm_step "$t" 74 1 1 smart 0
t=$((t + 30)); dm_step "$t" 75 1 1 smart 0
t=$((t + 30)); dm_step "$t" 75 0 1 smart 0
[ "$(dm_get smart on_s)" = "$_before" ] || f "charging time was counted as screen-on drain"
t=$((t + 30)); dm_step "$t" 75 0 0 smart 0
t=$((t + 3000)); dm_step "$t" 80 1 0 smart 0
t=$((t + 3000)); dm_step "$t" 80 0 1 smart 0
[ "$(dm_get smart off_n)" = 1 ] || f "a night with the charger was counted"
_before="$(dm_get smart on_s)"
t=$((t + 600)); dm_step "$t" 79 0 1 smart 0
[ "$(dm_get smart on_s)" = "$_before" ] || f "a 10 min gap between samples was counted as screen time"
t=$((t + 30)); dm_step "$t" 79 0 1 stock 0
i=0; while [ $i -lt 30 ]; do i=$((i + 1)); t=$((t + 30)); [ $i = 15 ] && dm_step "$t" 78 0 1 stock 0 || dm_step "$t" 79 0 1 stock 0; done
[ "$(dm_get stock on_s)" -gt 0 ] || f "Stock got no screen-on time"
[ "$(dm_get smart on_s)" = "$_before" ] || f "Stock time was booked to Smart"
dm_step "$((t + 30))" 79 0 1 none 0
[ -z "$dm_prof" ] || f "an unknown profile was measured"
dm_flush "$t"
grep -q '^smart 1170 300 7230 100 1$' "$T/asb/drain_meter" || f "file line for smart: $(grep '^smart' "$T/asb/drain_meter")"
printf '%s\n' 'smart 99 x 1 1 1' 'bogus 1 1 1 1 1' >> "$T/asb/drain_meter"
dm_load
[ "$(dm_get smart on_s)" = 1170 ] && [ "$(dm_get stock on_s)" -gt 0 ] || f "file round trip lost values"
dm_set balanced on_s 14390; dm_set balanced on_x 2000; dm_prof=balanced; dm_add_on 30 1
[ "$(dm_get balanced on_s)" = 7210 ] && [ "$(dm_get balanced on_x)" = 1050 ] || f "screen-on window not halved past 4 h: $(dm_get balanced on_s)/$(dm_get balanced on_x)"
dm_publish
grep -q '^current balanced$' "$T/live" || f "live file does not name the profile"
mkdir -p "$T/bl/panel0-backlight"; echo 0 > "$T/bl/panel0-backlight/brightness"
dm_screen && f "a dark backlight read as screen on"
echo 412 > "$T/bl/panel0-backlight/brightness"
dm_screen || f "a lit backlight read as screen off"
mkdir -p "$T/ps"; echo Discharging > "$T/ps/status"; dm_charging && f "Discharging read as charging"
echo Charging > "$T/ps/status"; dm_charging || f "Charging not seen"
echo "Not charging" > "$T/ps/status"; dm_charging || f "a plugged-in full battery counted as discharging"
H="$ROOT/webroot/index.html"
grep -q "function lvMeterParse(text)" "$H" || f "the Monitor does not read the meter"
grep -q "const isCharging = batteryStatus === 'charging' || batteryStatus === 'full' || ma < 0;" "$H" || f "Stock still reads Discharging as charging"
[ "$fail" = 0 ] && echo "PASS drain meter: screen-on and screen-off drain per profile with one method, Stock included; music, charging, gaps and short nights left out"
exit "$fail"
