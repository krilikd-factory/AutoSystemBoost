#!/bin/sh
# Contract: Smart must lower its ceiling before the vendor thermal owner clamps it, and must
# never re-raise a vendor cap through the anti-clamp path.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FSM="$ROOT/src/asb_fsm.h"
GOV="$ROOT/src/asb_governor.c"
fail() { echo "FAIL Smart thermal cap contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
need "$FSM" '#define ASB_SMART_PROACTIVE_P0_MODERATE_MAX 1996800'
need "$FSM" '#define ASB_SMART_PROACTIVE_P6_MODERATE_MAX 1632000'
need "$FSM" '#define ASB_SMART_PROACTIVE_P0_SUSTAINED_MAX 1785600'
need "$FSM" '#define ASB_SMART_PROACTIVE_P6_SUSTAINED_MAX 1382400'
need "$FSM" 'profile_idx == PROFILE_SMART'
need "$FSM" 'state >= ASB_STATE_MODERATE && state < ASB_STATE_GAMING'
need "$GOV" 'Smart is an energy/heat profile, not a hidden Balanced profile'
need "$GOV" 'p = PROFILE_BATTERY;'
need "$GOV" 'fsm->plan.ac_eligible  = 0'
# Host syntax/warning compilation is covered by the main regression; this test only protects the
# source-level policy invariants that a host cannot observe through sysfs.
echo 'PASS Smart proactive thermal cap contract'
