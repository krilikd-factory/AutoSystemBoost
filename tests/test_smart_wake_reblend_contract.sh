#!/bin/sh
# fix84-85: three Smart field defects.
#  1. CPH2769: after two hours screen-off the Smart blend kept the screen-off lean (pure
#     Battery rails) through the next screen-on session - the slot gate never looked at alpha.
#  2. PLQ110: GAMING <-> SUSTAINED every ~30 s at 49-52 C - exit was one degree under entry
#     and the trend path re-entered five degrees under it.
#  3. CPH2769 / OP15: the thermal-trend trim (18-32%) fired at 48-49 C on phones whose
#     learned normal is 45-54 C. In Smart the trend counts from the learned warm mark.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
S="$ROOT/src/asb_smart.h"; F="$ROOT/src/asb_fsm.h"
fail() { echo "FAIL smart wake re-blend: $*" >&2; exit 1; }
grep -Fq 'if (abs(rt->alpha_battery_x1000 - rt->last_alpha_x1000) >= 50) return 1;' "$S" || fail "alpha change does not re-blend"
grep -Fq 'if (abs(rt->interactive_bonus_x1000 - rt->last_bonus_x1000) >= 50) return 1;' "$S" || fail "bonus change does not re-blend"
grep -Fq 'rt->last_alpha_x1000 = rt->alpha_battery_x1000;' "$S" || fail "alpha not recorded at blend time"
grep -Fq 'm->therm.cpu_max_c <= sustained_temp_enter - ASB_GAME_SUS_HYST_C)' "$F" || fail "game exit lacks hysteresis"
grep -Fq '!_trend_game_exempt &&' "$F" || fail "trend path still pulls a busy game into SUSTAINED early"
G="$ROOT/src/asb_governor.c"
grep -Fq 'g_smart_rt.therm_warm_x10 / 10 > _trend_mark)' "$G" || fail "trend trim ignores the learned warm mark"
grep -Fq 'int _trend_warm = (!m->therm.temp_valid) || m->therm.cpu_max_c >= _trend_mark;' "$G" || fail "trend gate"
echo "PASS Smart re-blends on wake, and games have SUSTAINED hysteresis"
