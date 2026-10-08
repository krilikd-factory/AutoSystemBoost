#!/bin/sh
# Smart caps the separate prime core of a 3/4-cluster part (slot 2), which nothing held
# before (field OP12 diag in Smart: "prime ceiling: none from ASB", policy7 at 2496000 of
# 3302400). Executable fixture: the REAL helper, plus source pins for where it is applied
# and for the HEAVY prime escape being able to lift it.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"
fail() { echo "FAIL smart prime slot cap: $*" >&2; exit 1; }

grep -q 'int _pc = asb_smart_prime_slot_cap_khz((int)state, g_cpu_slot_hwmax\[2\],' "$F" || fail "helper not applied in fsm_interpolate_caps"
grep -q 'if (_pc > 0 && (out->cpu_max\[2\] <= 0 || out->cpu_max\[2\] > _pc))' "$F" || fail "an unmanaged (0) prime is not capped"
grep -q 'if (_lim <= 0) _lim = _hw;' "$F" || fail "HEAVY prime escape cannot lift a prime Balanced leaves unmanaged"

CC_BIN=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC_BIN="$c"; break; }; done
[ -n "$CC_BIN" ] || { echo "PASS smart prime slot cap contract (no C compiler: source pins only)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
{
  echo '#include <stdio.h>'
  echo 'enum { ASB_STATE_DEEP_IDLE = 0, ASB_STATE_LIGHT_IDLE, ASB_STATE_MODERATE, ASB_STATE_HEAVY, ASB_STATE_SUSTAINED, ASB_STATE_GAMING };'
  sed -n '/^static int asb_smart_prime_slot_cap_khz(/,/^}$/p' "$F"
  cat <<'EOF'
static int bad = 0;
#define EQ(a, b, m) do { if ((a) != (b)) { printf("FAIL %s: got %d want %d\n", m, (a), (b)); bad++; } } while (0)
int main(void) {
    const int hw = 3302400;   /* OP12 prime */
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, hw, 4, 0, 1), hw * 62 / 100, "moderate 62%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_HEAVY, hw, 4, 0, 1), hw * 62 / 100, "heavy 62%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_SUSTAINED, hw, 4, 0, 1), hw * 50 / 100, "sustained 50%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_LIGHT_IDLE, hw, 4, 0, 1), hw * 55 / 100, "light idle screen on 55%");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_LIGHT_IDLE, hw, 4, 0, 0), 0, "light idle screen off: screen-off cap owns it");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_DEEP_IDLE, hw, 4, 0, 0), 0, "deep idle untouched");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_GAMING, hw, 4, 0, 1), 0, "gaming untouched");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, hw, 4, 1, 1), 0, "a busy game is left alone");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, 4608000, 2, 0, 1), 0, "2-cluster part: slot 1 is the prime, not this");
    EQ(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, 0, 4, 0, 1), 0, "unknown hw max");
    /* Still the fastest core: above the middle cores' MODERATE share (58%). */
    if (!(asb_smart_prime_slot_cap_khz(ASB_STATE_MODERATE, hw, 4, 0, 1) > hw * 58 / 100)) { puts("FAIL prime below middle share"); bad++; }
    return bad;
}
EOF
} > "$TMP/t.c"
"$CC_BIN" -O2 -Wall -Werror -o "$TMP/t" "$TMP/t.c" 2> "$TMP/e" || { cat "$TMP/e"; fail "fixture did not compile"; }
"$TMP/t" || fail "helper returned wrong caps"
echo "PASS smart prime slot cap contract"
