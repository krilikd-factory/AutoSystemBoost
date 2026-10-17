#!/bin/sh
# Runtime (fix137): the screen-off traffic line and the phase table add up.
#
# Capture 2830: "sleep ... rmnetMiB 168.7" in the phase table, "measured screen-off mobile
# traffic 45.7 MiB" below it. Both were right - the 122.9 MiB moved in the interval in which
# the morning screen came on, which the table counts and the measured line silently dropped.
# The REAL awk from asb_log_full_day.sh runs against a battery_trace fixture.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/tools/logkit/asb_log_full_day.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL logkit traffic edge: $*" >&2; exit 1; }
# The program between the quotes of  _meas="$(awk -F'|' -v A=.. -v Z=.. '<program>' file)".
awk '/_meas="\$\(awk -F.\|. -v A="\$_a" -v Z="\$_z" .\$1/ { on = 1 }
     on { print }
     on && /END \{ printf "%d %d %d", m \+ 0, e \+ 0, wf \+ 0 \}/ { exit }' "$SRC" \
  | sed -e "1s/^.*-v Z=\"\$_z\" '//" -e "\$s/' \"\$LK_OUT_DIR.*\$//" > "$TMP/meas.awk"
grep -q 'else if (ps != \$5) e += b - pb' "$TMP/meas.awk" || fail "edge accounting not found"
# epoch|...|screen(5)|...|wifi_rx(24)|wifi_tx(25)|rmnet_rx(26)|rmnet_tx(27): only the columns
# the program reads matter. fix148: Wi-Fi with the screen off is the third figure; a Wi-Fi
# counter that went backwards (interface restarted) adds nothing.
row() { printf '%s|x|x|x|%s|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|x|%s|0|%s|%s\n' "$1" "$2" "$5" "$3" "$4"; }
{ row 1000 1 100 0 0          # screen on before the phase
  row 1100 0 200 0 1000       # phase starts (screen off)
  row 1200 0 1048776 0 2098152  # +1 MiB mobile, +2 MiB Wi-Fi with the screen off
  row 1250 0 2097352 0 500    # +1 MiB mobile; Wi-Fi counter reset
  row 1300 0 3145928 0 1049076  # +1 MiB mobile, +1 MiB Wi-Fi
  row 1302 1 9437384 0 9999999; } > "$TMP/bt.txt"   # the morning: +6 MiB across the screen-on edge
out="$(awk -F'|' -v A=1100 -v Z=1301 -f "$TMP/meas.awk" "$TMP/bt.txt")"
[ "$out" = "3145728 6291456 3145728" ] || fail "measured/edge/Wi-Fi split wrong: $out"
grep -q 'in the interval the screen changed state' "$SRC" || fail "edge traffic not printed"
grep -q 'measured screen-off mobile traffic %.1f MiB, Wi-Fi %.1f MiB' "$SRC" || fail "Wi-Fi not printed beside mobile"
echo "PASS logkit traffic edge: screen-off measured and screen-change edge reported apart, adding up to the table, Wi-Fi beside mobile"
