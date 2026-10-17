#!/bin/sh
# fix76: msm_performance ceilings follow the real CPU topology, ASB's own registration is
# not read back as lost headroom, and the boost-time registration is released.
#
# Before: cpus 0-5 got the little cap and 6-7 the big one (a 6+2 layout). On a 1+3+2+1
# part (OP12 / Ace 5: 0-1, 2-4, 5-6, 7) that capped four mid cores at the little ceiling
# and the prime at the mid ceiling in HEAVY/GAMING, and the governor then read its own cap
# back as "headroom 34% - kernel thermal cap detected" and entered SUSTAINED.
# Executable fixture: the REAL functions cut out of asb_metrics.h / asb_writer.h, run
# against a fake sysfs tree.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/src/asb_metrics.h"; W="$ROOT/src/asb_writer.h"; G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL msm topology: $*" >&2; exit 1; }

grep -q 'msm_perf_write_all_max' "$W" "$G" && fail "the fixed 6+2 writer is still referenced"
grep -q 'msm_perf_release();' "$W" || fail "boost-time registration is never released"
grep -q '"own_cap"' "$M" || fail "headroom still reads ASB's own msm cap as a kernel clamp"
grep -q 'fsm.current_caps.cpu_max\[2\]);' "$G" || fail "anti-clamp reassert drops the prime slot"

awk '/^static int g_asb_msm_written\[3\]/{on=1} on{print} on&&/^static int cpu_slot_of\(/{f=1} f&&/^}/{exit}' "$M" > "$T/topo.c"
awk '/^#define PATH_MSM_PERF_CPU_MAX/{on=1} on{print} on&&/^static void msm_perf_release\(/{f=1} f&&/^}/{exit}' "$W" > "$T/msm.c"
[ -s "$T/topo.c" ] && [ -s "$T/msm.c" ] || fail "functions not found"

mk() {  # mk <root> <policy> <cpus...>
  r="$1"; p="$2"; shift 2
  mkdir -p "$r/sys/devices/system/cpu/cpufreq/policy$p"
  echo "$*" > "$r/sys/devices/system/cpu/cpufreq/policy$p/related_cpus"
}
R="$T/op12"; mk "$R" 0 0 1; mk "$R" 2 2 3 4; mk "$R" 5 5 6; mk "$R" 7 7
mkdir -p "$R/sys/kernel/msm_performance/parameters"; : > "$R/sys/kernel/msm_performance/parameters/cpu_max_freq"

cat > "$T/t.c" <<X
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int fake_open(const char *p, int fl) {
    char b[512]; snprintf(b, sizeof(b), "%s%s", "$R", p); return open(b, fl | (fl & O_WRONLY ? O_TRUNC : 0));
}
#define open(p, f) fake_open(p, f)
static int g_cpu_all_ids[16]  = {0, 2, 5, 7};
static int g_cpu_all_slot[16] = {0, 1, 1, 2};
static int g_cpu_all_count = 4;
static int g_cpu_slot_hwmax[3] = {2265600, 3014400, 3302400};
#include "topo.c"
#include "msm.c"
static void node(char *b) { FILE *f = fopen("$R/sys/kernel/msm_performance/parameters/cpu_max_freq", "r"); b[0]=0; if (f) { if (!fgets(b, 400, f)) b[0]=0; fclose(f); } }
int main(void) {
    char b[400];
    if (msm_perf_write_caps(1363200, 2035200, 2496000) != 0) { puts("write failed"); return 1; }
    node(b);
    if (strcmp(b, "0:1363200 1:1363200 2:2035200 3:2035200 4:2035200 5:2035200 6:2035200 7:2496000")) { printf("layout: %s\n", b); return 1; }
    if (g_asb_msm_written[0] != 1363200 || g_asb_msm_written[2] != 2496000) { puts("own-cap record"); return 1; }
    // prime unmanaged (0): it gets the hardware maximum, not the mid cap
    g_msm_cur_max[2] = 0;
    msm_perf_write_caps(1363200, 2035200, 0); node(b);
    if (!strstr(b, "7:3302400")) { printf("unmanaged prime: %s\n", b); return 1; }
    msm_perf_release(); node(b);
    if (strcmp(b, "0:2265600 1:2265600 2:3014400 3:3014400 4:3014400 5:3014400 6:3014400 7:3302400")) { printf("release: %s\n", b); return 1; }
    if (g_msm_holding) { puts("still holding"); return 1; }
    return 0;
}
X
cc -std=gnu11 -Wall -Wno-unused-function -I"$T" "$T/t.c" -o "$T/t" || fail "fixture does not compile"
"$T/t" || fail "runtime check failed"
echo "PASS msm_performance follows the CPU topology"
