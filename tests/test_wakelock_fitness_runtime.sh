#!/bin/sh
# Runtime: wakelock_fitness=limit denies WAKE_LOCK to fitness apps seen holding one, and
# protect gives back exactly the mode each had before. Watch companions are never touched,
# and the choice works without wakelock_action and below the awake-share bar.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wakelock fitness: $*" >&2; fail=1; }
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
# Stateful: get answers what set stored, so the recorded "previous mode" is real.
echo "appops $*" >> "$AM_LOG"
case "$1" in
  get) m="$(sed -n "s/^$2 $3 //p" "$OPS" 2>/dev/null | tail -1)"
       if [ -n "$m" ]; then echo "$3: $m; time=+1h"; else echo "No operations."; fi ;;
  set) echo "$2 $3 $4" >> "$OPS" ;;
esac
S
chmod +x "$T/bin/"*
cat >> "$T/bin/pm" <<'S'
echo "package:com.google.android.apps.wearables.watch uid:10960"
S
# A watch companion holding a long wakelock too.
sed -i 's/^  Wake lock u0a700 SyncLoop/  Wake lock u0a960 WatchSync: 5m 0s 1ms (4 times) realtime\n  Wake lock u0a700 SyncLoop/' "$T/bin/dumpsys"
run() {
  printf 'wakelock_action=0\nwakelock_fitness=%s\n' "$1" > "$T/mod/config/governor.conf"
  printf 'awake_pct_screenoff=5\nawake_window_min=90\n' > "$T/state"
  OPS="$T/ops" AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
    sh "$SRC" >/dev/null 2>&1
}
A="$T/d/wakelock_apps"

run protect
grep -q 'WAKE_LOCK' "$T/am.log" 2>/dev/null && f "protect touched WAKE_LOCK"
grep -q '^com.sec.android.app.shealth|244|0|protected$' "$A" || f "pedometer not protected under protect"

# The user had already set the pedometer to allow explicitly: that mode must come back.
echo "com.sec.android.app.shealth WAKE_LOCK allow" > "$T/ops"
run limit
grep -q 'appops set com.sec.android.app.shealth WAKE_LOCK ignore' "$T/am.log" || f "limit did not deny the pedometer"
grep -q '^com.sec.android.app.shealth|244|0|limited$' "$A" || f "verdict not limited"
grep -qx 'com.sec.android.app.shealth|allow' "$T/d/wakelock_fitness_limited" || f "previous mode not recorded"
grep -q 'wearables.watch WAKE_LOCK' "$T/am.log" && f "watch companion touched"
grep -q 'set-standby-bucket' "$T/am.log" && f "generic restriction ran with wakelock_action=0"
run limit
[ "$(grep -c 'set com.sec.android.app.shealth WAKE_LOCK ignore' "$T/am.log")" = 1 ] || f "denied twice"

: > "$T/am.log"
run protect
grep -q 'appops set com.sec.android.app.shealth WAKE_LOCK allow' "$T/am.log" || f "protect did not restore the recorded mode"
[ -f "$T/d/wakelock_fitness_limited" ] && f "record kept after protect"

# An app someone else already set to ignore is not ours to record or undo.
echo "com.sec.android.app.shealth WAKE_LOCK ignore" > "$T/ops"; : > "$T/am.log"
run limit
[ -s "$T/d/wakelock_fitness_limited" ] && f "recorded an app that was already ignored"
grep -q 'set com.sec.android.app.shealth WAKE_LOCK' "$T/am.log" && f "re-set an externally ignored app"

grep -q 'wakelock_fitness_limited' "$ROOT/uninstall.sh" || f "uninstall does not restore limited fitness apps"

[ "$fail" = 0 ] && echo "PASS wakelock fitness runtime"
exit "$fail"
