#!/usr/bin/env bash
# Runtime (fix134): "Leave bad Wi-Fi" works on every rung, with or without the cellular master.
#
# Field report on V65-debug6: "leave bad Wi-Fi does not seem to work - tried different
# settings, it holds the Wi-Fi to the last". The watcher only ran on "aggressive" AND only
# with radio_policy_enable=1; "weak" (card: "leave when the signal falls below -80 dBm")
# never left anything, and "unusable" never even wrote Android's avoid-bad-Wi-Fi switch from
# the card. The REAL script runs here against mocked Android commands.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wifi_fallback.sh"
fail() { echo "FAIL wifi leave rungs: $*" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_wifi_fallback.sh" stop >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/mod/runtime" "$TMP/mod/config" "$TMP/bin" "$TMP/state"
cp "$SRC" "$TMP/mod/runtime/asb_wifi_fallback.sh"
cat > "$TMP/bin/dumpsys" <<'EOF'
#!/bin/sh
case "$1" in
  power) printf '%s\n' 'mWakefulness=Awake' ;;
  wifi) cat "$ASB_WIFI_DUMP" ;;
esac
EOF
cat > "$TMP/bin/settings" <<'EOF'
#!/bin/sh
case "$1:$2:$3" in
  get:global:airplane_mode_on) echo 0 ;;
  get:global:mobile_data) echo 1 ;;
  get:*) echo null ;;
esac
EOF
cat > "$TMP/bin/ip" <<'EOF'
#!/bin/sh
[ "$1" = route ] && [ "$2" = get ] && printf '%s\n' '1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.9'
EOF
cat > "$TMP/bin/svc" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ASB_SVC_LOG"
EOF
chmod 0755 "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" ASB_WIFI_DUMP="$TMP/wifi.dump" ASB_SVC_LOG="$TMP/svc.log"
export ASB_WIFI_FALLBACK_STATE_DIR="$TMP/state" ASB_GOV_STATE="$TMP/gov_state"
run() {
  MODDIR="$TMP/mod" ASB_WIFI_FALLBACK_INTERVAL_S=1 ASB_WIFI_FALLBACK_RELEASE_S=2 \
    ASB_WIFI_FALLBACK_COOLDOWN_S=2 ASB_WIFI_FALLBACK_IDLE_INTERVAL_S=1 \
    sh "$TMP/mod/runtime/asb_wifi_fallback.sh" "$@"
}
count() { local c; c="$(grep -cx "$1" "$TMP/svc.log" 2>/dev/null || true)"; echo "${c:-0}"; }
wait_count() {   # line, at least n, tries (0.1 s)
  local n=0; while [ "$(count "$1")" -lt "$2" ] && [ "$n" -lt "${3:-150}" ]; do sleep 0.1; n=$((n + 1)); done
  [ "$(count "$1")" -ge "$2" ]
}
dump() { printf 'mWifiInfo SSID: "home", RSSI: %s, Link speed: 6Mbps\nNetworkInfo: VALIDATED=%s\n' "$1" "$2" > "$TMP/wifi.dump"; }
screen() { printf 'state=MODERATE\nscreen=%s\n' "$1" > "$TMP/gov_state"; }
# /proc/net/wireless on the host has no wlan line, so the RSSI comes from the dump fallback.

# 1. weak, cellular master OFF: a validated link at -85 dBm is left after three weak passes.
printf 'radio_policy_enable=0\nnet_wifi_leave=weak\nnet_wifi_leave_dbm=-80\n' > "$TMP/mod/config/governor.conf"
screen 1; dump -85 true
run reconcile
wait_count 'wifi disable' 1 || fail "weak rung with the master off never left a -85 dBm link"
wait_count 'wifi enable' 1 || fail "Wi-Fi not given back after the release window"
grep -q 'out of range (rssi=-85) - releasing Wi-Fi default route for 2s' "$TMP/state/wifi_fallback.log" \
  || fail "first release window is not RELEASE_S"

# 2. It comes straight back to the same weak link: the next window doubles.
wait_count 'wifi disable' 2 || fail "second release did not happen"
grep -q 'releasing Wi-Fi default route for 4s' "$TMP/state/wifi_fallback.log" || fail "release window did not double"

# 3. A new threshold applies without restarting the watcher (it was frozen at the first pass).
printf 'radio_policy_enable=0\nnet_wifi_leave=weak\nnet_wifi_leave_dbm=-90\n' > "$TMP/mod/config/governor.conf"
wait_count 'wifi enable' 2 || fail "second window not closed"
before="$(count 'wifi disable')"
sleep 4
[ "$(count 'wifi disable')" -eq "$before" ] || fail "-85 dBm released with the threshold at -90 (stale threshold)"

# 4. Screen off (governor says so): nothing is decided.
printf 'radio_policy_enable=0\nnet_wifi_leave=weak\nnet_wifi_leave_dbm=-80\n' > "$TMP/mod/config/governor.conf"
screen 0
sleep 4
[ "$(count 'wifi disable')" -eq "$before" ] || fail "released with the screen off"
# A stale governor state (older than 5 min) is not trusted: dumpsys answers (Awake).
touch -d '@1' "$TMP/gov_state" 2>/dev/null || touch -t 197001010000 "$TMP/gov_state"
wait_count 'wifi disable' $((before + 1)) || fail "a stale screen=0 kept the watcher blind"
screen 1

# 5. weak never reads validation; a strong link is kept.
run stop
rm -f "$TMP/svc.log" "$TMP/state/wifi_fallback.log"
dump -50 false
run reconcile
sleep 4
[ ! -s "$TMP/svc.log" ] || fail "weak rung acted on validation"
run stop

# 6. unusable, master OFF: an attachment that validated and then lost validation is released.
printf 'radio_policy_enable=0\nnet_wifi_leave=unusable\nnet_wifi_leave_dbm=-80\n' > "$TMP/mod/config/governor.conf"
rm -f "$TMP/svc.log" "$TMP/state/wifi_fallback.log"
dump -50 true
run reconcile
n=0; while ! grep -q 'fallback armed' "$TMP/state/wifi_fallback.log" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
dump -50 false
wait_count 'wifi disable' 1 200 || fail "unusable rung did not release an unvalidated link"
grep -q 'released unvalidated Wi-Fi default route' "$TMP/state/wifi_fallback.log" || fail "validation release not logged"

# 7. off stops the watcher.
printf 'radio_policy_enable=0\nnet_wifi_leave=off\n' > "$TMP/mod/config/governor.conf"
run reconcile
n=0; while [ -e "$TMP/state/wifi_fallback.pid" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ ! -e "$TMP/state/wifi_fallback.pid" ] || fail "off did not stop the watcher"
[ "$(run status)" = off ] || fail "status after off: $(run status)"
echo "PASS wifi leave rungs: weak/unusable work without the cellular master, windows escalate, threshold is live"
