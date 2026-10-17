#!/bin/sh
# Contract: the five wifi_scan_throttle rungs write a valid boolean plus an interval,
# and auto/unknown values write nothing.
#
# Field bug: the shipped default wifi_scan_throttle=2 fell into the "2|*)" branch, which
# wrote the rung number into the BOOLEAN key wifi_scan_throttle_enabled. A framework
# consumer reading getInt(...)==1 then saw throttling as disabled, so the default install
# ran Wi-Fi scanning unthrottled - the status screen on the reference device showed
# exactly that - while no wifi_scan_interval_ms was ever written for the rung either.
# A device that had previously been on rung 0 kept its day-long interval with throttling
# merely "on". Both keys must now be written together, per rung, and nothing at all for
# auto.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
NET="$ROOT/runtime/asb_net_apply.sh"
ACTION="$ROOT/action.sh"
CONF="$ROOT/config/governor.conf.shipped"
fail() { echo "FAIL wifi scan rungs: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in ${1#$ROOT/}"; }
absent() { grep -Fq "$2" "$1" && fail "forbidden [$2] in ${1#$ROOT/}" || true; }

[ -f "$NET" ] || fail "asb_net_apply.sh not found"

# Every rung writes the boolean and the interval together.
need "$NET" '_wt_write 1 86400000'   # 0: no background scanning
need "$NET" '_wt_write 1 600000'     # 1: every 10 minutes
need "$NET" '_wt_write 1 300000'     # 2: every 5 minutes (framework default)
need "$NET" '_wt_write 1 120000'     # 3: every 2 minutes
need "$NET" '_wt_write 0 300000'     # 4: unthrottled, interval reset for re-enable

# The rung number must never be written into the boolean key.
absent "$NET" 'wifi_scan_throttle_enabled "$_wt"'
absent "$NET" 'wifi_scan_throttle_enabled 2 '

# auto and unrecognised values touch nothing.
need "$NET" '*) : ;;'

# The write is verified by read-back, failures included.
need "$NET" 'scan_throttle=FAILED'
need "$NET" 'settings get global wifi_scan_throttle_enabled'

# The shipped default stays 2, and the documented scale matches the code.
need "$CONF" 'wifi_scan_throttle=2'
need "$CONF" '2 = every 5 minutes (framework default)'

# action.sh labels describe the rungs as they actually behave: 0 stops background
# scanning, 4 is the unthrottled one, the shipped default is named.
need "$ACTION" 'background scanning off'
need "$ACTION" 'every 5 min (framework default)'
need "$ACTION" 'unthrottled (roams sooner, costs battery)'

echo "PASS wifi scan rungs contract"
