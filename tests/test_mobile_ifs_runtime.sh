#!/bin/sh
# Runtime (fix122): the governor counts mobile data on every rmnet_data* and ccmni* link,
# not a fixed rmnet_data0..2 + rmnet_ipa0 list - an OP15 moved its internet PDN to
# rmnet_data3 overnight and the radio went invisible; MediaTek names them ccmni*.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
M="$ROOT/src/asb_metrics.h"
fail() { echo "FAIL mobile ifs: $*" >&2; exit 1; }
grep -q '"rmnet_data0", "rmnet_data1", "rmnet_data2", "rmnet_ipa0"' "$M" && fail "fixed interface list still in use"
grep -q 'if (m->rmnet_rx_bps < 0) m->rmnet_rx_bps = 0;' "$M" || fail "a vanished link can make the rate negative"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS mobile ifs (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk() { mkdir -p "$T/net/$1/statistics"; echo "$2" > "$T/net/$1/statistics/rx_bytes"; echo "$3" > "$T/net/$1/statistics/tx_bytes"; }
mk rmnet_data0 100 200
mk rmnet_data3 5000000 70000
mk rmnet_ipa0 900000 900000          # transport underneath: must not be added
mk ccmni2 3000 4000
mk wlan0 99999999 99999999
mk r_rmnet_data0 7777 7777           # IWLAN reverse link: not a cellular data link
{
  cat <<X
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dirent.h>
#define ASB_NET_CLASS_DIR "$T/net"
static long sysfs_read_long(const char *path, long def) {
    FILE *f = fopen(path, "r"); long v = def;
    if (!f) return def;
    if (fscanf(f, "%ld", &v) != 1) v = def;
    fclose(f); return v;
}
X
  awk '/^#ifndef ASB_NET_CLASS_DIR/{on=1} on{print} on&&/^static long rmnet_read_total/{f=1} f&&/^}/{exit}' "$M"
  cat <<'X'
int main(void) {
    long rx = rmnet_read_total("rx_bytes"), tx = rmnet_read_total("tx_bytes");
    if (rx != 100 + 5000000 + 3000) { printf("rx %ld\n", rx); return 1; }
    if (tx != 200 + 70000 + 4000)   { printf("tx %ld\n", tx); return 1; }
    return 0;
}
X
} > "$T/t.c"
"$CC" -O2 -Wall -Werror -o "$T/t" "$T/t.c" || fail "fixture did not compile"
"$T/t" || fail "wrong interfaces counted"
echo "PASS mobile data counted on every rmnet_data*/ccmni* link (not ipa0, not wlan)"
