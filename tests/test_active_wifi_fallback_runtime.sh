#!/usr/bin/env bash
# Runtime fixture for the bounded poor-Wi-Fi fallback. Android commands are mocked so this
# verifies framework-validation gates and lifecycle ownership without touching a real radio.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wifi_fallback.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'if [[ -n "${WPID:-}" ]]; then kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/mod/runtime" "$TMP/mod/config" "$TMP/bin" "$TMP/state"
cp "$SRC" "$TMP/mod/runtime/asb_wifi_fallback.sh"
printf 'radio_policy_enable=1\nnet_handover_active=1\n' > "$TMP/mod/config/governor.conf"
cat > "$TMP/bin/dumpsys" <<'EOF'
#!/bin/sh
case "$1" in
  power) printf '%s\n' 'mWakefulness=Awake' ;;
  wifi) cat "$ASB_WIFI_DUMP" ;;
  *) : ;;
esac
EOF
cat > "$TMP/bin/settings" <<'EOF'
#!/bin/sh
case "$1:$2" in
  get:global)
    case "$3" in airplane_mode_on) echo 0 ;; mobile_data) echo 1 ;; *) echo null ;; esac ;;
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
chmod 0755 "$TMP/bin/dumpsys" "$TMP/bin/settings" "$TMP/bin/ip" "$TMP/bin/svc"
export PATH="$TMP/bin:$PATH" ASB_WIFI_DUMP="$TMP/wifi.dump" ASB_SVC_LOG="$TMP/svc.log"
export ASB_WIFI_FALLBACK_STATE_DIR="$TMP/state"
run() {
  MODDIR="$TMP/mod" ASB_WIFI_FALLBACK_INTERVAL_S=1 ASB_WIFI_FALLBACK_RELEASE_S=2 ASB_WIFI_FALLBACK_COOLDOWN_S=4 \
    sh "$TMP/mod/runtime/asb_wifi_fallback.sh" "$@"
}
wait_for() {
  local f="$1" n="${2:-50}"
  while (( n > 0 )); do [ -e "$f" ] && return 0; sleep 0.1; ((n--)); done
  return 1
}
wait_for_line() {
  local want="$1" f="$2" n="${3:-80}"
  while (( n > 0 )); do grep -qx "$want" "$f" 2>/dev/null && return 0; sleep 0.1; ((n--)); done
  return 1
}
wait_for_absent() {
  local f="$1" n="${2:-50}"
  while (( n > 0 )); do [ ! -e "$f" ] && return 0; sleep 0.1; ((n--)); done
  return 1
}

# A healthy Wi-Fi default route never gets released merely because it is default. reconcile
# starts one detached watcher and a second reconcile must preserve the exact same watcher.
printf '%s\n' 'NetworkInfo: VALIDATED=true' > "$TMP/wifi.dump"
run reconcile
wait_for "$TMP/state/wifi_fallback.pid" || fail 'reconcile did not start watcher'
WPID="$(cat "$TMP/state/wifi_fallback.pid")"
kill -0 "$WPID" 2>/dev/null || fail 'recorded watcher is not alive'
# A shell may exec this script and omit the literal `sh` token from cmdline. Lifecycle
# ownership must depend on the exact ASB script and watch argument, not its interpreter name.
_cmdline="$(tr '\000' ' ' < "/proc/$WPID/cmdline" 2>/dev/null)"
case "$_cmdline" in *"$TMP/mod/runtime/asb_wifi_fallback.sh watch"*) : ;; *) fail 'watcher argv lacks exact script plus watch argument' ;; esac
sleep 0.3
[ ! -s "$TMP/svc.log" ] || fail 'released validated Wi-Fi'
run reconcile
wait_for "$TMP/state/wifi_fallback.pid" || fail 'reconcile lost watcher PID'
[ "$(cat "$TMP/state/wifi_fallback.pid")" = "$WPID" ] || fail 'reconcile spawned duplicate watcher'
[ "$(find "$TMP/state" -maxdepth 1 -type d -name 'wifi_fallback.watch.lock' | wc -l | tr -d ' ')" = 1 ] || fail 'watcher lock missing or duplicated'

# Android-owned non-validation evidence while wlan0 is default releases once, then restores.
printf '%s\n' 'NetworkInfo: VALIDATED=false' > "$TMP/wifi.dump"
wait_for_line 'wifi disable' "$TMP/svc.log" || fail 'did not release unvalidated default Wi-Fi'
wait_for_line 'wifi enable' "$TMP/svc.log" || fail 'did not restore Wi-Fi after bounded release'
[ "$(grep -cx 'wifi disable' "$TMP/svc.log")" -eq 1 ] || fail 'repeated Wi-Fi release during cooldown'

# Turning the feature off via reconcile terminates its watcher and clears only ASB state.
printf 'radio_policy_enable=1\nnet_handover_active=0\n' > "$TMP/mod/config/governor.conf"
run reconcile
wait_for_absent "$TMP/state/wifi_fallback.pid" || fail 'stale watcher PID after OFF'
wait_for_absent "$TMP/state/wifi_fallback.watch.lock" || fail 'stale watcher lock after OFF'
kill -0 "$WPID" 2>/dev/null && fail 'reconcile OFF did not stop watcher'
[ "$(grep -cx 'wifi disable' "$TMP/svc.log")" -eq 1 ] || fail 'fallback acted after explicit off'
unset WPID

# If OFF happens during an ASB-owned release window, reconcile returns Wi-Fi immediately.
printf 'radio_policy_enable=1\nnet_handover_active=1\n' > "$TMP/mod/config/governor.conf"
run reconcile
wait_for "$TMP/state/wifi_fallback.action" || fail 'did not enter owned release window'
WPID="$(cat "$TMP/state/wifi_fallback.pid")"
printf 'radio_policy_enable=1\nnet_handover_active=0\n' > "$TMP/mod/config/governor.conf"
run reconcile
wait_for_absent "$TMP/state/wifi_fallback.action" || fail 'OFF did not clear ASB action marker after restore'
wait_for_absent "$TMP/state/wifi_fallback.pid" || fail 'watcher PID remained after active-window OFF'
wait_for_absent "$TMP/state/wifi_fallback.watch.lock" || fail 'watcher lock remained after active-window OFF'
[ "$(grep -cx 'wifi enable' "$TMP/svc.log")" -ge 2 ] || fail 'OFF did not return ASB-owned Wi-Fi'
kill -0 "$WPID" 2>/dev/null && fail 'watcher survived active-window OFF'
unset WPID

# Model an Android shell that execs the script directly: no literal `sh` argument precedes
# the script, yet the ASB-owned exact path and `watch` role remain verifiable through /proc.
mkdir -p "$TMP/proc/4242"
printf '%s\0' "$TMP/mod/runtime/asb_wifi_fallback.sh" watch > "$TMP/proc/4242/cmdline"
sed -n '/^_pid_is_our_watcher() {/,/^}/p' "$SRC" > "$TMP/pid_identity.sh"
PROC_ROOT="$TMP/proc" MODDIR="$TMP/mod"
. "$TMP/pid_identity.sh"
_pid_is_our_watcher 4242 || fail 'direct-exec watcher identity was not accepted'
printf '%s\0' '/data/local/tmp/asb_wifi_fallback.sh' watch > "$TMP/proc/4242/cmdline"
if _pid_is_our_watcher 4242; then
  fail 'same-basename non-module watcher was accepted'
fi

# Source-visible bounds prevent malformed host overrides from becoming a production busy loop.
grep -Fq '_valid_seconds "$_raw_interval" 1 120' "$SRC" || fail 'interval override is not bounded'
grep -Fq '_valid_seconds "$_raw_release" 1 120' "$SRC" || fail 'release override is not bounded'
grep -Fq '_valid_seconds "$_raw_cooldown" 1 3600' "$SRC" || fail 'cooldown override is not bounded'
grep -Fq 'PROC_ROOT="${ASB_WIFI_FALLBACK_PROC_ROOT:-/proc}"' "$SRC" || fail 'watcher proc root is not injectable for portability fixtures'
grep -Fq '*"$MODDIR/runtime/asb_wifi_fallback.sh watch"*) return 0 ;;' "$SRC" || fail 'watcher identity is not exact script plus watch argument'
if grep -Fq '*"sh $MODDIR/runtime/asb_wifi_fallback.sh watch"*)' "$SRC"; then
  fail 'watcher identity still requires a literal sh interpreter token'
fi
echo 'PASS: active Wi-Fi fallback runtime'
