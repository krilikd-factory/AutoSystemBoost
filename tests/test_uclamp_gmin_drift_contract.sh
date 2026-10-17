#!/bin/sh
# Contract: reconcile watches the GLOBAL uclamp.min ceiling for drift, with the same
# target formula as the writer (profile_core), and the new reason is wired into every
# place a drift reason must reach: the drift streak, the apply ledger and the
# governor-mode re-apply branch.
#
# Why: a field capture showed /proc/sys/kernel/sched_util_clamp_min back at the OxygenOS
# default 1024 on a phone whose profile applies 512. asb_apply_uclamp writes it on
# profile apply and nothing re-asserted it afterwards, so the ROM's boost framework could
# quietly outrank every per-cgroup ceiling the module sets. The C governor never writes
# this node, so the check must live OUTSIDE the governor-running gate that guards the
# per-cgroup uclamp tiers.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REC="$ROOT/runtime/asb_reconcile.sh"
PC="$ROOT/runtime/profile_core.sh"
DIAG="$ROOT/tools/asb_diag.sh"
DIAG2="$ROOT/system/bin/asbdiag"
fail() { echo "FAIL uclamp-gmin drift contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in ${1#$ROOT/}"; }
absent() { grep -Fq "$2" "$1" && fail "forbidden [$2] in ${1#$ROOT/}" || true; }

[ -f "$REC" ] || fail "asb_reconcile.sh not found"

# The check exists, reads the node and carries the reason end to end.
need "$REC" '/proc/sys/kernel/sched_util_clamp_min'
need "$REC" '_reason="uclamp-gmin"'
need "$REC" 'walt-topapp|walt-edboost|walt-ravg|uclamp|uclamp-fg|uclamp-bg|uclamp-gmin)'
need "$REC" 'uclamp|uclamp-fg|uclamp-bg|uclamp-gmin)'
need "$REC" 'elif [ "$_reason" = "uclamp-gmin" ]; then'

# Governor mode restores ONLY the global node there, never the governor-owned tiers.
absent "$REC" '_reason" = "uclamp-gmin" ] ; then
          asb_apply_uclamp'

# Write-war stand-down: gate on the check, reset on profile/screen change, and the
# restore counter must advance on BOTH apply paths. Governor mode writes the node
# directly; without the governor the restore rides apply_runtime_profile_now - and a
# counter that only increments on one path never arms on the other.
need "$REC" '[ "${_gmin_restores:-0}" -lt 3 ]'
need "$REC" '_drift_streak=0; _gmin_restores=0 ;;'
[ "$(grep -cF '_gmin_restores=$(( ${_gmin_restores:-0} + 1 ))' "$REC")" -ge 2 ] \
  || fail "uclamp-gmin restore counter advances on only one apply path (write war in the other)"
need "$REC" 'held externally, standing down until profile/screen change'

# The 20% floor is present in BOTH the writer and the watcher; the formula must be the
# same shape in both, or one day one of them changes and they silently disagree.
need "$REC" '_want_gmin=$(( ( ${UCL_TOP_MIN:-50} * 1024 ) / 100 ))'
need "$PC"  '_gmin="$(( ( ${UCL_TOP_MIN:-50} * 1024 ) / 100 ))"'
[ "$(grep -cF -- '-lt 205' "$REC")" -ge 2 ] || fail "205 floor missing in reconcile (check + fix branch)"
need "$PC" '[ "$_gmin" -lt 205 ] && _gmin=205'

# The check sits outside the governor-running gate: it must appear AFTER the closing
# of the per-cgroup block, which the uclamp-bg drift line marks the end of.
_bg=$(grep -nF '_reason="uclamp-bg"' "$REC" | head -1 | cut -d: -f1)
_gm=$(grep -nF '_reason="uclamp-gmin"' "$REC" | head -1 | cut -d: -f1)
[ -n "$_bg" ] && [ -n "$_gm" ] || fail "uclamp drift lines not found"
[ "$_gm" -gt "$_bg" ] || fail "uclamp-gmin check must follow the per-cgroup block (governor-gate escape)"

# Diagnosis names the live value so the next capture shows drift without a diff.
need "$DIAG" 'global sched_util_clamp_min'
cmp -s "$DIAG" "$DIAG2" || fail "tools/asb_diag.sh and system/bin/asbdiag differ"

echo "PASS uclamp-gmin drift contract"
