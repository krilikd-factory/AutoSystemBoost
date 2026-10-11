#!/bin/sh
# Runtime (fix121): the comfort trims read a running mean of the discharge current, updated
# once per metrics sample, restarted on the charger / with the screen off / after a gap, and
# a trim in force has an exit band (80% of the entry current, 2 C below the entry temperature).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL comfort current: $*" >&2; exit 1; }

grep -q 'int _cma = asb_comfort_ma(m);' "$G" || fail "comfort gates do not read the smoothed current"
grep -q 'asb_ma_ref(_cma) >= (_cin ? comfort_current_ma \* 4 / 5 : comfort_current_ma)' "$G" || fail "no exit band on the comfort current"
grep -q 'm->therm.cpu_max_c >= g_asb_cfg.bat_comfort_temp - (_cin ? 2 : 0)' "$G" || fail "no exit band on the comfort temperature"
grep -q '(reason && strncmp(reason, "screenon_comfort", 16) == 0) ? 1 : 0;' "$G" || fail "engaged flag not tracked with the budget reason"
# The spike tie-breaker stays on the raw sample: it exists for spikes.
grep -q 'if (!m->bat.charging && asb_ma_ref(m->bat.current_ma) >= 1800)' "$G" || fail "1800 mA tie-breaker must stay raw"

CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS comfort current (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{
  cat <<'X'
#include <stdio.h>
#include <time.h>
typedef struct { int charging; int current_ma; } bat_t;
typedef struct { int screen_on; } misc_t;
typedef struct { struct timespec ts; bat_t bat; misc_t misc; } asb_metrics_t;
X
  sed -n '/^static int  g_comfort_ma_ema = 0;/,/^static int asb_adaptive_budget_trim_pct/p' "$G" | sed '$d'
  cat <<'X'
static asb_metrics_t M;
static int feed(long sec, int ma) { M.ts.tv_sec = sec; M.ts.tv_nsec = 0; M.bat.current_ma = ma; return asb_comfort_ma(&M); }
int main(void) {
    int bad = 0, v;
    (void)g_budget_comfort_engaged;
    M.misc.screen_on = 1;
    /* The 24817 sequence, one sample per 6 s tick: the mean stays in one band. */
    int seq[] = { 391, 516, 437, 258, 748, 328, 384, 268, 517, 304 };
    int lo = 100000, hi = 0;
    for (int i = 0; i < 10; i++) { v = feed(100 + 6 * i, seq[i]); if (i >= 3) { if (v < lo) lo = v; if (v > hi) hi = v; } }
    if (hi - lo > 160) { printf("mean swings %d..%d - not smoothed\n", lo, hi); bad = 1; }
    if (lo < 350 * 4 / 5) { printf("mean %d drops out of the exit band on this sequence\n", lo); bad = 1; }
    /* Same sample asked twice: one update. */
    int a = feed(200, 1000); int b = asb_comfort_ma(&M);
    if (a != b) { printf("second caller moved the mean %d -> %d\n", a, b); bad = 1; }
    /* Gap over 30 s: restart from the sample. */
    v = feed(260, 200);
    if (v != 200) { printf("stale mean not restarted: %d\n", v); bad = 1; }
    /* Charger and screen-off restart it too. */
    feed(262, 900); M.bat.charging = 1; feed(264, 900); M.bat.charging = 0;
    v = feed(266, 300);
    if (v != 300) { printf("charging did not restart the mean: %d\n", v); bad = 1; }
    M.misc.screen_on = 0; feed(268, 900); M.misc.screen_on = 1;
    v = feed(270, 310);
    if (v != 310) { printf("screen-off did not restart the mean: %d\n", v); bad = 1; }
    return bad;
}
X
} > "$T/t.c"
"$CC" -O2 -Wall -Werror -o "$T/t" "$T/t.c" || fail "fixture did not compile"
"$T/t" || fail "smoothing wrong"
echo "PASS comfort trims: smoothed current, once per sample, restarts, exit band"
