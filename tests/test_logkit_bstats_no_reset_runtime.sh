#!/bin/sh
# Runtime: the capture no longer resets batterystats by default, and the per-app wakelock
# section shows the capture's own window as a difference against the start.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL logkit batterystats: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/out"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$2" = "--reset" ] && { echo reset >> "$RESETS"; exit 0; }
cat "$BS"
S
chmod +x "$T/bin/dumpsys"
cat > "$T/bs1" <<'B'
  Wake lock u0a493 PedometerLib:tag: 4m 4s 955ms (3 times) max=1 realtime
  Wake lock u0a700 SyncLoop: 10s 1ms (4 times) realtime
B
cat > "$T/bs2" <<'B'
  Wake lock u0a493 PedometerLib:tag: 9m 4s 955ms (9 times) max=1 realtime
  Wake lock u0a700 SyncLoop: 12s 1ms (5 times) realtime
  Wake lock u0a800 NewOne: 1m 0s 1ms (1 times) realtime
B
printf '10493|com.sec.android.app.shealth\n10800|com.example.new\n' > "$T/out/.uid_package_map.tsv"
out="$(PATH="$T/bin:$PATH" RESETS="$T/resets" LK_OUT_DIR="$T/out" BS="$T/bs1" sh -c '
  . "$0" >/dev/null 2>&1
  lk_have() { command -v "$1" >/dev/null 2>&1 || type "$1" >/dev/null 2>&1; }
  lk_dumpsys() { dumpsys "$@"; }
  LK_WAKELOCK_NAME=asb_logkit_self
  lk_wakelock_batterystats_reset
  BS="'"$T"'/bs2" lk_wakelock_batterystats_reset
  BS="'"$T"'/bs2" lk_wakelock_emit_report "'"$T"'/bs2"
  sed -n "/TOP APPS/,/^$/p" "$LK_OUT_DIR/_wakelock_report.txt"
' "$C" 2>&1)"
[ -f "$T/resets" ] && f "batterystats was reset without ASB_LK_BSTATS_RESET=1"
printf '%s\n' "$out" | grep -q 'during this capture' || f "section not labelled as the capture window: $out"
printf '%s\n' "$out" | grep -q '5m 00s  com.sec.android.app.shealth' || f "pedometer delta should be 5m 00s: $out"
printf '%s\n' "$out" | grep -q '1m 00s  com.example.new' || f "new holder missing: $out"
printf '%s\n' "$out" | grep -q 'uid 10700' && f "2 s delta must stay under the 5 s floor"
[ "$fail" = 0 ] && echo "PASS logkit batterystats no-reset runtime"
exit "$fail"
