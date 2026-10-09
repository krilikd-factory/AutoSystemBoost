#!/bin/sh
# fix74: the ceiling ASB wrote to scaling_max_freq is classified as ASB's, not as a vendor
# clamp. The classifier compared the live ceiling with the msm_performance cap, which the
# writer only touches in HEAVY/GAMING - so every Smart cap in LIGHT/MODERATE read as
# "vendor_clamp" (field OP15, 35 C: vendor_clamp_1h=424, holddown active on its own writes).
# Executable fixture: the REAL cap_source_classify() cut out of asb_governor.c.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL cap source own-write: $*" >&2; exit 1; }

grep -q 'real_max_p0, hw_ceil_p0,' "$G" || fail "status builder call changed shape"
grep -q 'g_wcache.cpu_max\[0\]);' "$G" || fail "little cluster classified without ASB's written cap"
grep -q 'g_wcache.cpu_max\[1\]);' "$G" || fail "prime cluster classified without ASB's written cap"

awk '/^static inline const char \*cap_source_classify\(/{on=1} on{print} on&&/^}/{exit}' "$G" > "$T/fn.c"
[ -s "$T/fn.c" ] || fail "cap_source_classify not found"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <string.h>
#include "fn.c"
static int bad;
static void eq(const char *got, const char *want, const char *what) {
    if (strcmp(got, want)) { printf("%s: got %s want %s\n", what, got, want); bad = 1; }
}
int main(void) {
    // OP15 LIGHT_IDLE: profile ceiling 3628800, msm cap at hw max, ASB wrote 1440000
    eq(cap_source_classify(3628800, 3628800, 1440000, 3628800, 1440000), "asb_dynamic", "own smart cap");
    eq(cap_source_classify(1440000, 3628800, 1440000, 3628800, 1440000), "asb", "own cap = profile");
    // something below what ASB wrote is still a clamp
    eq(cap_source_classify(3628800, 3628800, 1209600, 3628800, 1440000), "vendor_clamp", "real clamp");
    // somebody rewrote the node above ours
    eq(cap_source_classify(3628800, 1440000, 2000000, 3628800, 1440000), "vendor_raised", "raised");
    // no msm_performance node: ASB's own write is not a shell override
    eq(cap_source_classify(3628800, 0, 1440000, 3628800, 1440000), "asb_dynamic", "no msm, own cap");
    eq(cap_source_classify(3628800, 0, 3628800, 3628800, 0), "shell_applied", "nothing written yet");
    return bad;
}
X
cc -std=gnu11 -Wall -Werror -I"$T" "$T/t.c" -o "$T/t" || fail "fixture does not compile"
"$T/t" || fail "classification wrong"
echo "PASS cap source recognises ASB's own writes"
