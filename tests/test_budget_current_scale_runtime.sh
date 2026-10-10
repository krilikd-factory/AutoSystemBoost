#!/bin/sh
# fix85: the thermal-budget mA gates were tuned on OP15 readings (gauge x0.38 of real drain).
# A CPH2769 gauge reads x0.88, so the same workload crossed every gate 2.3x earlier. The
# reading is converted to the reference scale once the phone's own ratio is on record.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL budget current scale: $*" >&2; exit 1; }
n="$(awk '/^static int asb_adaptive_budget_trim_pct/,/caps->uclamp_bg_max = target;/' "$G" | grep -c 'asb_ma_ref(m->bat.current_ma) >=')"
[ "$n" -ge 6 ] || fail "only $n budget mA gates use the reference scale"
awk '/^static int asb_adaptive_budget_trim_pct/,/caps->uclamp_bg_max = target;/' "$G" | grep -E 'm->bat\.current_ma >= [0-9c]' && fail "a budget mA gate still compares raw current"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS budget current scale (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  echo '#include <stdio.h>'
  echo 'static int g_curscale_x100 = -1, g_curscale_n = 0;'
  sed -n '/^#define ASB_CURSCALE_REF_X100/p; /^static int asb_ma_ref(/,/^}$/p' "$G"
  cat <<'X'
int main(void) {
    int bad = 0;
    if (asb_ma_ref(880) != 880) { puts("no ratio yet must be raw"); bad = 1; }
    g_curscale_x100 = 88; g_curscale_n = 3;
    if (asb_ma_ref(880) != 880) { puts("too few windows must be raw"); bad = 1; }
    g_curscale_n = 14;
    if (asb_ma_ref(880) != 380) { printf("CPH2769 880 -> %d, want 380\n", asb_ma_ref(880)); bad = 1; }
    g_curscale_x100 = 38;
    if (asb_ma_ref(450) != 450) { puts("OP15 must be unchanged"); bad = 1; }
    g_curscale_x100 = 900;
    if (asb_ma_ref(450) != 450) { puts("nonsense ratio must be raw"); bad = 1; }
    return bad;
}
X
} > "$T/t.c"
"$CC" -O2 -Wall -Werror -o "$T/t" "$T/t.c" || fail "fixture did not compile"
"$T/t" || fail "conversion wrong"
echo "PASS budget mA gates use the reference gauge scale"
