#!/bin/sh
# Runtime (fix159): when SystemUI misses frames in every interval, the report names the
# status-bar settings that redraw every second.
#
# The owner's OP15 shows SystemUI at about one janky frame a second in every screen-on interval
# of four captures, at 60, 90 and 120 Hz alike - against 0.05-0.2 a second on two other OP15s
# and an OP15R. The report already says "a steady redraw, turn off what updates every second",
# but not what is switched on. The REAL capture function records the status-bar settings once
# (fake `settings` here), and the REAL report prints them under the steady-redraw line - only
# when SystemUI is the steady source, and nothing when the phone has none of those settings.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL sysui redraw: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/a" "$T/b"
cat > "$T/bin/settings" <<'S'
#!/bin/sh
[ "$1" = list ] || exit 0
case "$2" in
  system) printf '%s\n' 'peak_refresh_rate=165.0' 'show_network_speed=1' 'status_bar_show_battery_percent=1' 'screen_off_timeout=30000' ;;
  secure) printf '%s\n' 'clock_seconds=1' 'doze_always_on=0' ;;
  global) printf '%s\n' 'wifi_on=1' ;;
esac
S
printf '#!/bin/sh\nexit 0\n' > "$T/bin/dumpsys"
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_display_config_capture' "$C" "$T/a"
D="$T/a/display_config.txt"
grep -qx '## status bar redraw settings' "$D" || f "no status-bar section in display_config"
grep -qx 'system: show_network_speed=1' "$D" || f "network speed meter not recorded"
grep -qx 'secure: clock_seconds=1' "$D" || f "seconds on the clock not recorded"
grep -q 'screen_off_timeout\|doze_always_on\|wifi_on' "$D" && f "unrelated settings recorded"
J="$T/a/jank_trace.tsv"
echo "# epoch|iso_time|phase|fsm_state|interval_s|main_at_cap|prime_at_cap|touches|frames|janky|deadline_missed|slow_ui|high_input|main_cap_pct|prime_cap_pct|fg_pkg|jank_pkgs" > "$J"
i=0
while [ $i -lt 10 ]; do
  i=$((i + 1))
  printf '%s|t|active|MODERATE|48|0|0|1|4000|60|60|10|5|1|0|com.twitter.android|com.android.systemui:48:200,com.twitter.android:12:3800\n' "$i" >> "$J"
done
out="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/a" 2>&1)"
printf '%s\n' "$out" | grep -q '^com.android.systemui missed deadlines in 10 of 10 screen-on intervals' || f "steady redraw line missing: $out"
printf '%s\n' "$out" | grep -q '^status-bar settings read on this phone at the start of the capture:$' || f "settings heading missing: $out"
printf '%s\n' "$out" | grep -qx '  system: show_network_speed=1' || f "network speed not listed: $out"
printf '%s\n' "$out" | grep -qx '  secure: clock_seconds=1' || f "clock seconds not listed: $out"
cp "$J" "$T/b/jank_trace.tsv"
out2="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/b" 2>&1)"
printf '%s\n' "$out2" | grep -q 'missed deadlines in 10 of 10' || f "steady redraw line missing without a config file"
printf '%s\n' "$out2" | grep -q 'status-bar settings read' && f "a settings heading printed with nothing recorded: $out2"
sed 's/com.android.systemui:48:200,com.twitter.android:12:3800/com.twitter.android:60:4000/' "$J" > "$T/a/j2" && mv "$T/a/j2" "$J"
out3="$(sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_jank_summary' "$C" "$T/a" 2>&1)"
printf '%s\n' "$out3" | grep -q 'status-bar settings read' && f "status-bar settings printed for an app that is not SystemUI: $out3"
[ "$fail" = 0 ] && echo "PASS sysui redraw: the status-bar settings that redraw every second are recorded and named under a steady SystemUI redraw"
exit "$fail"
