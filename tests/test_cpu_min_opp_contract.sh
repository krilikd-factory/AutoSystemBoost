#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WRITER="$ROOT/src/asb_writer.h"
DISCOVER="$ROOT/tools/asb_discover.sh"
DIAG="$ROOT/tools/asb_diag.sh"
POLICY="$ROOT/tools/asb_effective_policy.sh"
SERVICE="$ROOT/service.sh"

fail() { printf '%s\n' "FAIL cpu min OPP: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing $2 in ${1#$ROOT/}"; }
absent() { grep -Fq "$2" "$1" && fail "forbidden $2 in ${1#$ROOT/}" || true; }

# The native writer must discover the actual first OPP from every physical policy table.
need "$WRITER" 'static long cpu_lowest_opp(int path_idx)'
need "$WRITER" 'A missing/empty table returns 0'
need "$WRITER" 'if (fsm_profile_is_smart && state <= ASB_STATE_SUSTAINED)'
need "$WRITER" 'long smart_opp = cpu_lowest_opp(_mi);'
need "$WRITER" 'long smart_opp = cpu_lowest_opp(j);'
need "$WRITER" 'manual profiles and'
need "$WRITER" 'HEAVY/GAMING keep their requested floors unchanged'
# No literal cross-device floor may be introduced by this policy.
absent "$WRITER" 'DEEP_IDLE_MIN_KHZ'
absent "$WRITER" 'LOWEST_OPP_KHZ'

# Discovery and diagnostics must expose whether the actual policy is usable and accepted.
need "$DISCOVER" 'cpu_policy${_pid}_lowest_opp='
need "$DISCOVER" 'cpu_policy${_pid}_min_writable='
need "$DIAG" 'smart minimum: [PASS] Smart requested hardware lowest OPP'
need "$DIAG" 'smart minimum: [WARN]'
need "$DIAG" 'DEEP_IDLE|LIGHT_IDLE|MODERATE|SUSTAINED'
need "$DIAG" 'scaling_min=$_minwf'
need "$SERVICE" '[ "${ASB_PROFILE:-$PROFILE}" = "smart" ]'
need "$SERVICE" 'cpuinfo_min_freq'
need "$POLICY" '"cpu_min_policy"'
need "$POLICY" 'hardware_lowest_opp'
need "$POLICY" 'smart_non_gaming'

printf '%s\n' 'PASS CPU minimum OPP contract'
