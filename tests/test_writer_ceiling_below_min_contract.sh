#!/bin/sh
# Contract: a min-freq clamped down to the ceiling is applied, not failed.
#
# Field report: eight FAILs for cpu_min (want 2438400, live 1632000/1747200) on a kernel
# doing exactly what it should - scaling_min_freq cannot exceed scaling_max_freq, and the
# vendor pulls the ceiling back down right after ASB writes it. The writer classifies this
# as ceiling_below_min: counted as applied, with a floor_holds backoff so a vendor that
# holds the ceiling for good is not re-asked on every transition.
#
# The danger in such a branch is scope creep: a wider condition would start excusing real
# write failures. These checks pin the branch to CPU_MIN nodes only, below the request
# only, and with the backoff wired to the existing retry_at mechanism.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WRITER="$ROOT/src/asb_writer.h"

fail() { printf '%s\n' "FAIL writer ceiling_below_min: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in ${1#$ROOT/}"; }

[ -f "$WRITER" ] || fail "asb_writer.h not found"

# The branch exists and is scoped to the CPU minimum nodes, success path only.
need "$WRITER" 'ceiling_below_min'
need "$WRITER" 'rc == 0 && node >= ASB_WRITE_CPU_MIN0 && node < ASB_WRITE_CPU_MIN0 + 3'
need "$WRITER" 'observed > 0 && observed < requested'

# It counts as applied and clears the failure counter - never the other way round.
need "$WRITER" 'h->applied++;'
need "$WRITER" 'h->consecutive_failures = 0;'

# The backoff: three holds -> leave the vendor alone for an hour; otherwise retry freely.
need "$WRITER" 'if (++h->floor_holds >= 3) h->retry_at = now + 3600;'

# floor_holds must be state, not a local: the field lives in the writer state struct and
# is initialised where the other counters are.
need "$WRITER" 'unsigned long floor_holds;'
need "$WRITER" 'h->floor_holds = 0;'

# The branch must sit BEFORE the generic failure accounting, or failures would be
# counted first and the classification would never run. Order check, not just presence.
_branch_line="$(grep -Fn 'ceiling_below_min' "$WRITER" | head -1 | cut -d: -f1)"
_unsup_line="$(grep -Fn 'unsupported node is not a failure' "$WRITER" | head -1 | cut -d: -f1)"
[ -n "$_branch_line" ] && [ -n "$_unsup_line" ] || fail "cannot locate branch anchors"
[ "$_branch_line" -lt "$_unsup_line" ] || \
  fail "ceiling_below_min branch must precede the unsupported/failure classification"

printf '%s\n' 'PASS writer ceiling_below_min contract'
