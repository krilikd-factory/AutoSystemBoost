#!/bin/sh
# Runtime (fix133): a vendor hold defers the request that was held, not a new one.
#
# After three readbacks above ASB's request (a vendor boost holding the CPU minimum up, so
# the ceiling reads back higher), writer_write_int_confirmed backs the node off for five
# minutes. That is right for the held value - it stays in the kernel's QoS set and takes
# effect when the boost ends. It was wrong for every OTHER value: a PLQ110 capture shows
# MODERATE wanting the main ceiling at 1785600 while the node was still backed off from
# three holds of the light-idle 1555200 - desired 1785600, requested 1555200, live 1555200
# for minutes. The REAL writer function is cut out of asb_writer.h and run against a fake
# node whose readback is max(request, vendor floor).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
fail() { echo "FAIL writer hold bypass: $*" >&2; exit 1; }
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "SKIP writer hold bypass: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Enum, health struct, counters and helpers up to and including the confirmed write.
sed -n '/^typedef enum {$/,/^static void writer_write_health_dump(FILE \*f) {$/p' "$W" | sed '$d' > "$T/w.c"
grep -q '^static int writer_write_int_confirmed(asb_write_node_t node, const char \*path, int requested) {$' "$T/w.c" \
  || fail "writer function not found"

: > "$T/node"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <time.h>
#include <unistd.h>
static int g_live = 0, g_vendor_floor = 0, g_writes = 0;
static int sysfs_read_int(const char *p, int d) { (void)p; return g_live ? g_live : d; }
static int sysfs_write_int(const char *p, int v) { (void)p; g_writes++; g_live = v > g_vendor_floor ? v : g_vendor_floor; return 0; }
static int sysfs_read_str(const char *p, char *b, size_t n) { (void)p; (void)b; (void)n; return -1; }
#include "w.c"
static const char *NODE;
static int put(int v) { return writer_write_int_confirmed(ASB_WRITE_CPU_MAX0, NODE, v); }
int main(int argc, char **argv) {
    int bad = 0;
    NODE = argc > 1 ? argv[1] : "/dev/null";
    asb_write_health_t *h = &g_write_health[ASB_WRITE_CPU_MAX0];
    /* A boost holds the floor at 1785600: three holds of 1555200 -> five-minute back-off. */
    g_vendor_floor = 1785600; g_live = 1785600;
    for (int i = 0; i < 3; i++) put(1555200);
    if (h->retry_at <= time(NULL)) { printf("no back-off after three holds\n"); bad = 1; }
    /* The held value itself waits. */
    int w0 = g_writes;
    if (put(1555200) != 1 || g_writes != w0) { printf("held value re-sent during the back-off\n"); bad = 1; }
    /* The boost ends; MODERATE wants 1785600 - a new request is sent at once. */
    g_vendor_floor = 0; g_live = 1555200;
    if (put(1785600) != 0 || g_live != 1785600) { printf("new ceiling swallowed by the back-off (live %d)\n", g_live); bad = 1; }
    if (h->hold_bypass != 1) { printf("bypass not counted\n"); bad = 1; }
    /* A clean write ends the run of holds: one later hold must not back off at once. */
    g_vendor_floor = 1996800;
    put(1555200);
    if (h->retry_at > time(NULL)) { printf("one hold after a clean write started the back-off\n"); bad = 1; }
    /* A failing node still waits, whatever it is asked: holddown is not a vendor hold. */
    h->retry_at = time(NULL) + 90; snprintf(h->status, sizeof(h->status), "%s", "external_policy_holddown");
    w0 = g_writes;
    if (put(1900800) != 1 || g_writes != w0) { printf("a holddown node was written\n"); bad = 1; }
    /* Not a CPU node: no bypass even on a vendor-hold status. */
    asb_write_health_t *u = &g_write_health[ASB_WRITE_UCL_TOP];
    u->retry_at = time(NULL) + 300; u->requested = 50; snprintf(u->status, sizeof(u->status), "%s", "kernel_floor_higher");
    w0 = g_writes;
    if (writer_write_int_confirmed(ASB_WRITE_UCL_TOP, NODE, 60) != 1 || g_writes != w0) { printf("non-CPU node bypassed\n"); bad = 1; }
    return bad;
}
X
"$CC" -O1 -Wall -Wno-unused-function -I"$T" -o "$T/t" "$T/t.c" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail "harness did not compile"; }
"$T/t" "$T/node" || fail "hold bypass wrong"
echo "PASS writer hold bypass: a held request waits, a new one is sent, a clean write ends the hold run"
