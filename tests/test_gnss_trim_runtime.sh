#!/bin/sh
# Runtime: GNSS trim reads current location-dump formats and real process state.
#
# Android 12+ names location callers as "10234/com.foo[tag]", not "package=com.foo", and
# `dumpsys activity processes` prints "cached=false" on every record, so the old parse
# found nothing and the old state check said "cached" for apps in any state. Stubs replay
# both formats plus an event log that must be ignored.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL gnss runtime: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/mod/runtime" "$T/d"
cp "$ROOT/runtime/asb_procstate.sh" "$T/mod/runtime/"
echo "gnss_trim=1" > "$T/mod/config/governor.conf"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1" in
  deviceidle) echo false ;;
  location) cat <<'L'
  gps provider:
    registrations:
      10700/com.example.weather[loc] (fine) Request[@+10m0s HIGH_ACCURACY]
      10701/com.example.walk Request[@+1s HIGH_ACCURACY]
      10702/com.example.navi.app Request[@+1s HIGH_ACCURACY]
      10703/com.example.foobar Request[@+1m]
    package=com.example.legacy
  Event Log:
    10:00:01 +registration 10704/com.example.gone Request[...]
L
  ;;
  activity) cat <<'A'
  #40: fg     TOP  LCMNFU  ---- 1111:com.example.walk/u0a701
  #20: cch+5  CEM  ----    ---- 2222:com.example.weather/u0a700
  #19: cch+7  CEM  ----    ---- 3333:com.example.legacy/u0a705
  #18: cch+9  CEM  ----    ---- 4444:com.example.gone/u0a704
  #17: cch+9  CEM  ----    ---- 5555:com.example.navi.app/u0a702
A
  ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
printf 'package:com.example.weather\npackage:com.example.walk\npackage:com.example.navi.app\npackage:com.example.foo\npackage:com.example.legacy\npackage:com.example.gone\n'
S
cat > "$T/bin/appops" <<'S'
#!/bin/sh
case "$1" in
  get) echo "$3: allow" ;;
  set) echo "$*" >> "$OPLOG" ;;
esac
S
chmod +x "$T/bin/"*
OPLOG="$T/ops" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_GNSS_DIR="$T/d" \
  sh "$ROOT/runtime/asb_gnss_trim.sh" >/dev/null 2>&1
touch "$T/ops"
grep -q 'set com.example.weather FINE_LOCATION foreground' "$T/ops" || f "cached caller in uid/pkg form not trimmed"
grep -q 'set com.example.legacy COARSE_LOCATION foreground' "$T/ops" || f "legacy package= form not read"
grep -q 'com.example.walk' "$T/ops" && f "foreground app trimmed"
grep -q 'com.example.navi' "$T/ops" && f "navigation app trimmed"
grep -q 'com.example.gone' "$T/ops" && f "event-log entry treated as a live request"
grep -q 'com.example.foobar' "$T/ops" && f "substring third-party match"
[ "$fail" = 0 ] && echo "PASS gnss trim runtime"
exit "$fail"
