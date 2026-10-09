#!/bin/sh
# fix80: Smart writes (and repairs) the lowest-OPP floor on every slot, including the prime
# slot whose profile floor is 0. Field OP12: policy7 min=672000 against 480000, the only
# cluster Smart never touched ("smart minimum: WARN"). Non-Smart profiles keep skipping a
# slot without a floor, and HEAVY/GAMING keep their profile floors.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
fail() { echo "FAIL smart prime floor: $*" >&2; exit 1; }
grep -Fq 'int _smart_floor = (fsm_profile_is_smart && state <= ASB_STATE_SUSTAINED);' "$W" || fail "primary path"
grep -Fq 'if (want_min <= 0 && !_smart_floor) continue;' "$W" || fail "primary path still skips a zero floor in Smart"
grep -Fq 'if (want_min <= 0 && !(fsm_profile_is_smart && state <= ASB_STATE_SUSTAINED)) continue;' "$W" || fail "extra clusters"
[ "$(grep -Fc 'if (want_min <= 0) continue;' "$W")" -ge 2 ] || fail "no guard against writing 0 when the OPP table is missing"
echo "PASS Smart floors every slot at its lowest OPP"
