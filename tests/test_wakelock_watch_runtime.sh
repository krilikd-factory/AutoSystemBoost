#!/bin/sh
# Runtime: the wakelock watcher resolves holders by uid on current Android formats.
#
# dumpsys power writes "(uid=10493 pid=...)" and batterystats "Wake lock u0a493 Tag: ...";
# the parsers this guards once read the tag as a package and never matched anything.
# Stubs replay those exact formats and check the ranking, the protected classes, the
# in-use exemption, the WorkSource attribution and that nothing acts while switched off.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wakelock runtime: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/d"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1" in
  batterystats) cat <<'B'
  All partial wake locks:
  Wake lock u0a493 PedometerLib:tag: 4m 4s 955ms (3 times) max=150727 actual=296015 realtime
  Wake lock u0a432 *job*e/@androidx.work.systemjobscheduler@com.duolingo/androidx.work.impl.background.systemjob.SystemJobService: 3m 10s 2ms (9 times) realtime
  Wake lock u0a700 SyncLoop: 1h 2m 0s 1ms (40 times) realtime
  Wake lock u0a800 Tiny: 30s 1ms (2 times) realtime
  Wake lock u0a147 CollectionLib-SigCollector: 9m 868ms (3 times) realtime
  Wake lock 1000 *alarm*: 5m 1ms (3 times) realtime
  Total WiFi Multicast wakelock time: 1h 2m 3s 4ms
B
  ;;
  power) cat <<'P'
    PARTIAL_WAKE_LOCK                 '*job*r/com.example.player/x.Job' ACQ=-2m2s223ms LONG (uid=1000 pid=6599 ws=WorkSource{ chains=WorkChain{(10901), (1000, JobScheduler)}})
    PARTIAL_WAKE_LOCK                 'Short' ACQ=-3s (uid=10800 pid=1)
P
  ;;
  activity) cat <<'A'
  #45: fg     TOP  LCMNFU  ---- 1234:com.android.launcher/u0a12
  #30: prcp   FGS  ----    ---- 4567:com.example.player/u0a901
  #20: cch+ 5 CEM  ----    ---- 5678:com.example.sync/u0a700
A
  ;;
  deviceidle) echo false ;;
  wifi) cat <<'W'
Multicast Locks held:
    Multicaster{mdns-discovery uid=10700}
    Multicaster{CastDiscovery uid=10950}
    Multicaster{NearbyMediums uid=1000}
W
  ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
cat <<'L'
package:com.sec.android.app.shealth uid:10493
package:com.duolingo uid:10432
package:com.example.sync uid:10700
package:com.example.tiny uid:10800
package:com.example.player uid:10901
package:com.example.cast uid:10950
L
S
cat > "$T/bin/am" <<'S'
#!/bin/sh
echo "$*" >> "$AM_LOG"
S
cat > "$T/bin/appops" <<'S'
#!/bin/sh
# Stateful (fix100): get answers what set stored, so a denial that is still in force is
# not re-asserted, and a reset one is.
echo "appops $*" >> "$AM_LOG"
case "$1" in
  get) m="$(sed -n "s/^$2 $3 //p" "$AM_LOG.ops" 2>/dev/null | tail -1)"
       if [ -n "$m" ]; then echo "$3: $m; time=+1h"; else echo "No operations."; fi ;;
  set) echo "$2 $3 $4" >> "$AM_LOG.ops" ;;
esac
S
chmod +x "$T/bin/"*
run() {
  echo "wakelock_action=$1" > "$T/mod/config/governor.conf"
  printf 'awake_pct_screenoff=%s\nawake_window_min=90\n' "$2" > "$T/state"
  AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
    sh "$SRC" >/dev/null 2>&1
}

# Switched off: ranks and reports, changes nothing.
run 0 60
A="$T/d/wakelock_apps"
[ -s "$A" ] || f "no wakelock_apps written while report-only"
[ ! -s "$T/am.log" ] || f "acted while wakelock_action=0"
head -1 "$A" | grep -q '^com.example.sync|3720|0|report$' || f "top row wrong: $(head -1 "$A")"
grep -q '^com.sec.android.app.shealth|244|0|protected$' "$A" || f "pedometer not ranked as protected"
grep -q '^com.duolingo|190|0|report$' "$A" || f "job wakelock not charged to its app"
grep -q '^com.example.player|0|1|in_use$' "$A" || f "WorkSource LONG holder not attributed or not exempt"
grep -q 'com.example.tiny' "$A" && f "a 30 s holder must not be listed"
grep -q 'gms\|1000' "$A" && f "system or non-third-party uid listed"

M="$T/d/wakelock_multicast"
grep -qx 'total|3723' "$M" || f "multicast total over an hour not parsed: $(head -1 "$M")"
grep -qx 'com.example.sync|report' "$M" || f "cached multicast holder not resolved by uid"
grep -qx 'com.example.cast|protected' "$M" || f "cast app not protected"
grep -qx 'uid 1000|system' "$M" || f "system multicast holder not named"

# Switched on, awake share below the 25% bar: still nothing.
run 1 20
[ ! -s "$T/am.log" ] || f "acted below the awake bar"

# Switched on and over the bar: only the eligible apps are restricted, once.
run 1 40
grep -q 'set-standby-bucket com.example.sync restricted' "$T/am.log" || f "cached heavy holder not restricted"
grep -q 'set-standby-bucket com.duolingo restricted' "$T/am.log" || f "job holder not restricted"
grep -q 'shealth\|player' "$T/am.log" && f "protected or in-use app restricted"
grep -q 'appops set com.example.sync WIFI_MULTICAST ignore' "$T/am.log" || f "cached multicast holder not denied"
grep -q 'appops set com.example.cast' "$T/am.log" && f "cast app denied multicast"
grep -qx 'com.example.sync|restricted' "$M" || f "multicast verdict not restricted"
run 1 40
[ "$(grep -c 'bucket com.example.sync' "$T/am.log")" = 1 ] && [ "$(grep -c 'appops set com.example.sync' "$T/am.log")" = 1 ] || f "restricted the same app twice"
# The system resets the op: the next pass re-asserts the denial instead of trusting the record.
echo "com.example.sync WIFI_MULTICAST default" >> "$T/am.log.ops"
run 1 40
[ "$(grep -c 'appops set com.example.sync WIFI_MULTICAST ignore' "$T/am.log")" = 2 ] || f "reset multicast denial not re-applied"
grep -q '^com.example.sync|3720|0|restricted$' "$A" || f "verdict not updated to restricted"

# Switched off again: everything ASB restricted is handed back and the records cleared.
: > "$T/am.log"
run 0 40
grep -q 'set-standby-bucket com.example.sync active' "$T/am.log" || f "off did not release the restricted bucket"
grep -q 'appops set com.example.sync WIFI_MULTICAST allow' "$T/am.log" || f "off did not give multicast back"
[ -f "$T/d/wakelock_restricted" ] && f "restricted record kept after off"

[ "$fail" = 0 ] && echo "PASS wakelock watcher runtime"
exit "$fail"
