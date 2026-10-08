#!/bin/sh
# Contract: every staged camera payload is queued for the boot-time bind - no comparison with
# the live file at install time (fix54 skipped on equality; fix64 drops the comparison: what
# the live path shows mid-install says nothing about what it shows after the reboot).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
I="$ROOT/common/install.sh"
fail=0; f() { echo "FAIL camera bind requeue: $*" >&2; fail=1; }
body="$(sed -n '/^asb_generate_odm_camera_binds()/,/^}/p' "$I")"
printf '%s\n' "$body" | grep -q 'cmp -s' && f 'a live-file comparison can skip the camera bind again'
printf '%s\n' "$body" | grep -Fq 'echo "${_obc_live}|${_obc_dst}" >> "$_obc_man"' || f 'camera payload no longer queued'
grep -Fq 'camera bind: ' "$ROOT/tools/asb_diag.sh" || f 'asbdiag does not show camera bind evidence'
grep -Fq 'nsenter -t 1 -m -- umount "$_ct_live"' "$I" || f 'installer does not take down its own camera bind before declaring the live tone table dirty'
grep -q 'ASB_L_CAM_LIVE_DIRTY2=".*root' "$ROOT/common/englishtext.sh" || f 'dirty-camera advice still says only "reboot and install again"'
[ "$fail" = 0 ] && echo "PASS camera bind requeue contract"
exit "$fail"
