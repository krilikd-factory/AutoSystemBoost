#!/usr/bin/env sh
# Regression guard for ASB-03 and ASB-05 service-side contracts.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE="$ROOT/service.sh"

fail() { printf '%s\n' "FAIL: $*" >&2; exit 1; }
need() { grep -Fq "$1" "$SERVICE" || fail "missing: $1"; }

# Stock thermal must read the paired type file and only resolve a passive trip as
# an active control value. Active data remains explicit diagnostics, not policy.
need '_typef="${_base}_type"'
need 'case "$_tt" in'
need 'passive)'
need 'SOURCE=passive_trip_point'
need 'SOURCE=active_fallback'
need 'SOURCE=none'
need 'no passive stock trip'

# VM_PAGE_CLUSTER is declared by the selected profile. service.sh must not reapply
# old hard-coded per-profile values after profile_core.sh has set the profile value.
need 'VM_PAGE_CLUSTER belongs to the selected profile'
need 'writef_retry /proc/sys/vm/page-cluster "$VM_PAGE_CLUSTER"'
if grep -Eq 'page-cluster[[:space:]]+(0|1|3)[[:space:]]+1[[:space:]]+0' "$SERVICE"; then
  fail 'legacy hard-coded page-cluster write remains in service.sh'
fi

# The boot-only compatibility audio path must match the validated live path. 255 is outside
# the documented resampler enum and is silently rejected on current OPlus stacks.
need 'setprop af.resampler.quality 0 2>/dev/null || true'
if grep -Fq 'setprop af.resampler.quality 255' "$SERVICE"; then
  fail 'legacy audio writer still sets unsupported resampler value 255'
fi

printf '%s\n' 'PASS service thermal/vm contract'
