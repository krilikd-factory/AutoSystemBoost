#!/bin/sh
# Runtime (fix151): once Wi-Fi starts failing, the watcher looks again in 3 s, not 8.
#
# Tester on fix150: "it leaves Wi-Fi about 10 s sooner than before, but not all the way - it
# still holds a dead access point for about 10 s". Three weak passes 8 s apart are 16-24 s
# from the first weak reading to the release. The confirmation itself is unchanged (three
# readings in a row); only the wait between them is short once a streak has begun. A strong
# link that lost validation on "unusable" keeps the 8 s cadence: that is the captive-portal
# grace. The REAL watcher runs on mocked Android commands and a sleep that records its
# argument.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wifi_fallback.sh"
fail() { echo "FAIL wifi leave fast confirm: $*" >&2; exit 1; }
T="$(mktemp -d)"
REAL_SLEEP="$(command -v sleep)"
cleanup() { [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/mod/runtime" "$T/mod/config" "$T/bin" "$T/state"
cp "$SRC" "$T/mod/runtime/asb_wifi_fallback.sh"
cat > "$T/bin/dumpsys" <<'X'
#!/bin/sh
case "$1" in power) echo 'mWakefulness=Awake' ;; wifi) cat "$ASB_WIFI_DUMP" ;; esac
X
cat > "$T/bin/settings" <<'X'
#!/bin/sh
case "$1:$2:$3" in get:global:airplane_mode_on) echo 0 ;; get:global:mobile_data) echo 1 ;; get:*) echo null ;; esac
X
cat > "$T/bin/ip" <<'X'
#!/bin/sh
[ "$1" = route ] && [ "$2" = get ] && echo '1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.9'
X
cat > "$T/bin/svc" <<'X'
#!/bin/sh
printf '%s\n' "$*" >> "$ASB_SVC_LOG"
X
cat > "$T/bin/sleep" <<X
#!/bin/sh
printf '%s\n' "\$1" >> "$T/sleeps"
exec "$REAL_SLEEP" 0.02
X
chmod 0755 "$T/bin/"*
export PATH="$T/bin:$PATH" ASB_WIFI_DUMP="$T/wifi.dump" ASB_SVC_LOG="$T/svc.log"
export ASB_WIFI_FALLBACK_STATE_DIR="$T/state" ASB_GOV_STATE="$T/gov"
printf 'state=MODERATE\nscreen=1\n' > "$T/gov"
watch_until_disable() {   # rung dump-rssi dump-validated
  printf 'radio_policy_enable=0\nnet_wifi_leave=%s\nnet_wifi_leave_dbm=-80\n' "$1" > "$T/mod/config/governor.conf"
  printf 'mWifiInfo SSID: "home", RSSI: %s, Link speed: 6Mbps\nNetworkInfo: VALIDATED=%s\n' "$2" "$3" > "$T/wifi.dump"
  rm -f "$T/svc.log" "$T/sleeps" "$T/state/"wifi_fallback.* 2>/dev/null; rm -rf "$T/state/wifi_fallback.watch.lock"
  MODDIR="$T/mod" sh "$T/mod/runtime/asb_wifi_fallback.sh" watch </dev/null >/dev/null 2>&1 &
  WPID=$!
  if [ "$1" != weak ]; then
    printf 'mWifiInfo SSID: "home", RSSI: %s, Link speed: 6Mbps\nNetworkInfo: VALIDATED=true\n' "$2" > "$T/wifi.dump"
    n=0; while ! grep -q 'fallback armed' "$T/state/wifi_fallback.log" 2>/dev/null && [ "$n" -lt 200 ]; do "$REAL_SLEEP" 0.05; n=$((n + 1)); done
    : > "$T/sleeps"
    printf 'mWifiInfo SSID: "home", RSSI: %s, Link speed: 6Mbps\nNetworkInfo: VALIDATED=%s\n' "$2" "$3" > "$T/wifi.dump"
  fi
  n=0; while ! grep -qx 'wifi disable' "$T/svc.log" 2>/dev/null && [ "$n" -lt 300 ]; do "$REAL_SLEEP" 0.05; n=$((n + 1)); done
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null || true; WPID=""
  grep -qx 'wifi disable' "$T/svc.log" 2>/dev/null
}
# 1. Walking out of range: -85 dBm, still validated. Passes 3 s apart, then the release.
watch_until_disable weak -85 true || fail "weak rung did not leave a -85 dBm link"
[ "$(head -2 "$T/sleeps" | tr '\n' ' ')" = "3 3 " ] || fail "out-of-range passes not 3 s apart: $(tr '\n' ' ' < "$T/sleeps")"
grep -q 'out of range (rssi=-85) pass 2/3' "$T/state/wifi_fallback.log" || fail "the confirmation got shorter than three readings"
# 2. aggressive, strong link without internet: also 3 s apart.
watch_until_disable aggressive -50 false || fail "aggressive rung did not leave an unvalidated link"
grep -q 'unvalidated Wi-Fi pass 1/3' "$T/state/wifi_fallback.log" || fail "aggressive skipped its confirmation"
grep -qx 3 "$T/sleeps" || fail "aggressive confirmation not fast: $(tr '\n' ' ' < "$T/sleeps")"
# 3. unusable, strong link without internet (a captive portal, a dead router): the 8 s grace stays.
watch_until_disable unusable -50 false || fail "unusable rung did not leave an unvalidated link"
grep -qx 3 "$T/sleeps" && fail "unusable lost its captive-portal grace: $(tr '\n' ' ' < "$T/sleeps")"
echo "PASS wifi leave fast confirm: 3 s between failing readings (out of range, aggressive), 8 s grace on unusable"
