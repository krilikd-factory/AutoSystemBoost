#!/bin/sh
# Contract: byte counters and other values past 2^31 are not summed or compared with
# shell arithmetic in device scripts.
#
# Android's /system/bin/sh is mksh, whose arithmetic is 32-bit signed (a built mksh R59:
# $((2147483647+1)) = -2147483648, and [ 3000000000 -gt 2000000000 ] is false). Host
# shells are 64-bit, so host tests never saw it. Field effects: the screen-off class lost
# "network" after 2 GiB received since boot, the opt-in zram rebuild compared against a
# wrapped 8 GiB and ran every boot. These go through awk now.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; f() { echo "FAIL mksh 32-bit: $*" >&2; fail=1; }
grep -nE '\$\(\([^)]*(rx_bytes|tx_bytes)' "$ROOT"/runtime/*.sh "$ROOT"/action.sh "$ROOT"/tools/logkit/*.sh && f 'byte counter in $(( ))'
grep -Fq '_rx1=$(( _rx1 +' "$ROOT/runtime/asb_screenoff_class.sh" && f 'screen-off class sums rx bytes in shell arithmetic'
grep -Fq '_mrx=$(( _mrx + _a ))' "$ROOT/tools/logkit/_asb_logkit_common.sh" && f 'logkit sums mobile bytes in shell arithmetic'
grep -Fq '$((ZRAM_SIZE_MB * 1024 * 1024))' "$ROOT/service.sh" && f 'zram bytes computed in shell arithmetic'
grep -Fq '_wf_rate * 125000 * 60' "$ROOT/runtime/asb_net_routes.sh" && f 'BDP product overflows 32 bits above ~286 Mbit/s'
grep -Fq '_ma * 100 / _mt' "$ROOT/runtime/smart_dynamic_tune.sh" && f 'memory share overflows on 24 GB phones'
if command -v mksh >/dev/null 2>&1; then
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/net/rmnet_data0/statistics"
  echo 3000000000 > "$T/net/rmnet_data0/statistics/rx_bytes"
  _s="$(cat "$T"/net/rmnet_data*/statistics/rx_bytes | awk '{ s += $1 } END { printf "%.0f", s + 0 }')"
  [ "$_s" = 3000000000 ] || f "awk sum under mksh gave $_s"
fi
[ "$fail" = 0 ] && echo "PASS mksh 32-bit arithmetic contract"
exit "$fail"
