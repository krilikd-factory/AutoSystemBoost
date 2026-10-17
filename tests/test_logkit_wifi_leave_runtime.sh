#!/bin/sh
# Runtime (fix152): the full-day capture keeps the Wi-Fi leave watcher's events and says how
# long leaving took.
#
# Testers: "it leaves Wi-Fi about 10 s sooner, but still holds a dead access point for about
# 10 s". The watcher's own log keeps 80 lines and no capture copied it, so neither that nor
# the fix151 change could be measured. The REAL collector copies new lines each poll -
# nothing from before the capture, nothing twice, also after the watcher trims its log - and
# the REAL report section counts releases by reason and the time from the first failing
# reading to the release.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/tools/logkit/asb_log_full_day.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL logkit wifi leave: $*" >&2; fail=1; }
mkdir -p "$T/out" "$T/mod/config"
{ sed -n '/^lk_wifi_leave_collect() {$/,/^}$/p' "$S"; sed -n '/^lk_emit_wifi_leave_summary() {$/,/^}$/p' "$S"; } > "$T/f.sh"
grep -q '^lk_emit_wifi_leave_summary() {$' "$T/f.sh" || f "summary function not found"
grep -q '^  lk_wifi_leave_collect$' "$S" || f "the poll loop does not collect"
grep -q '^    lk_emit_wifi_leave_summary$' "$S" || f "the report has no Wi-Fi leave section"
printf 'net_wifi_leave=aggressive\nnet_wifi_leave_dbm=-80\n' > "$T/mod/config/governor.conf"
L="$T/wifi_fallback.log"
w() { printf '%s wifi_fallback: %s\n' "$1" "$2" >> "$L"; }
w '2026-10-20 08:00:00' 'out of range (rssi=-88) pass 1/3'
w '2026-10-20 08:00:03' 'out of range (rssi=-88) pass 2/3'
w '2026-10-20 08:00:06' 'out of range (rssi=-88) - releasing Wi-Fi default route for 30s'
run() { LK_OUT_DIR="$T/out" LK_MODDIR="$T/mod" LK_WIFI_FALLBACK_LOG="$L" LK_WIFI_SINCE='2026-10-20 09:00:00' sh -c '. "$1"; '"$1" x "$T/f.sh"; }
run lk_wifi_leave_collect
[ -s "$T/out/wifi_leave_events.log" ] && f "events from before the capture were copied"
w '2026-10-20 09:10:00' 'out of range (rssi=-86) pass 1/3'
w '2026-10-20 09:10:03' 'out of range (rssi=-86) pass 2/3'
w '2026-10-20 09:10:06' 'out of range (rssi=-86) - releasing Wi-Fi default route for 30s'
run lk_wifi_leave_collect
run lk_wifi_leave_collect
[ "$(grep -c . "$T/out/wifi_leave_events.log")" = 3 ] || f "first copy wrong: $(cat "$T/out/wifi_leave_events.log")"
w '2026-10-20 09:10:36' 'Wi-Fi re-enabled after ASB fallback window'
w '2026-10-20 09:10:36' 'cooldown started (300s)'
w '2026-10-20 09:30:00' 'out of range (rssi=-84) pass 1/3'
w '2026-10-20 09:40:00' 'unvalidated Wi-Fi pass 1/3 (rssi=-50) - waiting'
w '2026-10-20 09:40:03' 'unvalidated Wi-Fi pass 2/3 (rssi=-50) - waiting'
w '2026-10-20 09:40:09' 'released unvalidated Wi-Fi default route for 60s'
tail -n 4 "$L" > "$L.t"; mv "$L.t" "$L"
w '2026-10-20 10:00:00' 'could not disable Wi-Fi; no route action taken'
run lk_wifi_leave_collect
[ "$(grep -c 'released unvalidated' "$T/out/wifi_leave_events.log")" = 1 ] || f "line after a trimmed log lost or doubled"
[ "$(grep -c 'pass 1/3' "$T/out/wifi_leave_events.log")" -ge 2 ] || f "streak starts lost"
run lk_emit_wifi_leave_summary > "$T/rep"
grep -qx 'rung now: aggressive, threshold -80 dBm' "$T/rep" || f "rung line: $(cat "$T/rep")"
grep -q '^releases: 2 (out of range 1, no internet 1) - Wi-Fi given back after the window: 0, could not disable: 1$' "$T/rep" || f "counts: $(cat "$T/rep")"
grep -qx 'first failing reading to the release: median 7 s, longest 9 s (2 release(s))' "$T/rep" || f "timing: $(cat "$T/rep")"
grep -qx 'failing streaks that recovered before a release: 1' "$T/rep" || f "recovered: $(cat "$T/rep")"
rm -f "$T/out/wifi_leave_events.log"
run lk_emit_wifi_leave_summary > "$T/rep"
grep -qx 'no watcher events in this capture' "$T/rep" || f "empty capture: $(cat "$T/rep")"
[ "$fail" = 0 ] && echo "PASS logkit wifi leave: watcher events kept for the whole capture, releases timed from the first failing reading"
exit "$fail"
