#!/bin/sh
# fix74: a GPU ceiling lowered past the live floor is put back once the floor follows.
#
# KGSL clamps max_pwrlevel to min_pwrlevel at write time (higher index = lower clock), so
# "write ceiling 17, then floor 17" against a floor of 8 ends as max=8 min=17. The override
# check then blamed the vendor and held every GPU write for 15 s - OP15 field capture:
# max_overrides=323 backoffs=492, written 17 / observed 8 with the floor at 17.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/src/asb_writer.h"
fail() { printf '%s\n' "FAIL gpu pwrlevel order: $*" >&2; exit 1; }
need() { grep -Fq "$1" "$W" || fail "missing [$1]"; }

need 'int _gmax_pl_this_tick = -1;'
need 'g_wcache.last_max_pwrlevel_written = pl; _gmax_pl_this_tick = pl;'
need 'if (_gmax_pl_this_tick >= 0 && g_gpu_uses_pwrlevel && g_gpu_max_path[0]) {'
# only when the pair is consistent: a vendor floor above our ceiling is not fought
need 'if (_gmin_now < 0 || _gmin_now >= _gmax_pl_this_tick)'

# the re-check runs AFTER the floor write, or it would see the old floor
_floor="$(grep -Fn 'g_wcache.last_min_pwrlevel_written = pl;' "$W" | head -1 | cut -d: -f1)"
_fix="$(grep -Fn 'if (_gmax_pl_this_tick >= 0 && g_gpu_uses_pwrlevel' "$W" | head -1 | cut -d: -f1)"
[ -n "$_floor" ] && [ -n "$_fix" ] || fail "anchors not found"
[ "$_fix" -gt "$_floor" ] || fail "ceiling re-check precedes the floor write"

# Model of the KGSL rule the fix relies on (kgsl_pwrctrl max/min_pwrlevel_store):
# max cannot exceed min as an index, min cannot go below max.
python3 - <<'PY'
class K:
    def __init__(s, mx, mn): s.max, s.min = mx, mn
    def wmax(s, l): s.max = min(l, s.min)
    def wmin(s, l): s.min = max(l, s.max)
k = K(0, 8)            # vendor floor at 8
k.wmax(17); k.wmin(17) # the old order
assert (k.max, k.min) == (8, 17), (k.max, k.min)
if k.max != 17 and k.min >= 17: k.wmax(17)   # the fix
assert (k.max, k.min) == (17, 17), (k.max, k.min)
k = K(0, 8); k.wmax(17)                        # floor NOT ours to move (no min write)
if k.max != 17 and k.min >= 17: k.wmax(17)
assert k.max == 8                              # left alone
PY
printf '%s\n' 'PASS gpu pwrlevel order contract'
