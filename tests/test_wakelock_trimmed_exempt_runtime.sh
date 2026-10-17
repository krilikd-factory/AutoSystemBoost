#!/bin/sh
# Runtime (fix152): an app the Doze trim took off the exemption list is still the user's
# exempted app to the wakelock watcher.
#
# The watcher never restricts an app on Android's exemption list (fix136): the user put it
# there. The Doze trim removes exactly those apps from the list at night, so with both
# tweaks on, a VPN or a mail client the user had marked unrestricted lost that protection
# and could be moved to the restricted standby bucket - a much harsher state than Doze. The
# REAL watcher runs on mocked dumpsys / pm / am; the trim's record names the app.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wakelock trimmed exempt: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/d"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1:${2:-}" in
  batterystats:*) cat <<'B'
  All partial wake locks:
  Wake lock u0a700 SyncLoop: 1h 2m 0s 1ms (40 times) realtime
  Wake lock u0a750 Tunnel: 55m 0s 1ms (9 times) realtime
B
  ;;
  power:*) : ;;
  activity:*) cat <<'A'
  #20: cch+ 5 CEM  ----    ---- 5678:com.example.sync/u0a700
  #18: cch+ 5 CEM  ----    ---- 5680:com.user.vpnclient/u0a750
A
  ;;
  deviceidle:whitelist) cat <<'W'
system-excidle,com.android.providers.downloads,10035
system,com.google.android.gms,10146
W
  ;;
  deviceidle:*) echo false ;;
  wifi:*) : ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
cat <<'L'
package:com.example.sync uid:10700
package:com.user.vpnclient uid:10750
L
S
cat > "$T/bin/am" <<'S'
#!/bin/sh
echo "$*" >> "$AM_LOG"
S
cat > "$T/bin/appops" <<'S'
#!/bin/sh
echo "No operations."
S
chmod +x "$T/bin/"*
echo "wakelock_action=1" > "$T/mod/config/governor.conf"
printf 'awake_pct_screenoff=40\nawake_window_min=90\n' > "$T/state"
printf '%s\n' com.user.vpnclient 'bad;name' > "$T/d/doze_whitelist_removed"
run() { AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" sh "$SRC" > "$T/out" 2>&1; }
run
grep -q 'set-standby-bucket com.user.vpnclient restricted' "$T/am.log" && f "an app the Doze trim took off the list was restricted"
grep -qx 'set-standby-bucket com.example.sync restricted' "$T/am.log" || f "an ordinary cached holder was no longer restricted"
echo com.user.vpnclient > "$T/d/wakelock_restricted"; : > "$T/am.log"
run
grep -qx 'set-standby-bucket com.user.vpnclient active' "$T/am.log" || f "an earlier restriction of a trimmed app was not given back"
rm -f "$T/d/doze_whitelist_removed"; : > "$T/am.log"; rm -f "$T/d/wakelock_restricted"
run
grep -q 'set-standby-bucket com.user.vpnclient restricted' "$T/am.log" || f "without the trim record the guard protects nothing - the test no longer tells the two apart"
[ "$fail" = 0 ] && echo "PASS wakelock trimmed exempt: apps the Doze trim removed keep the user's exemption in the wakelock watcher"
exit "$fail"
