#!/bin/sh
# Contract: a camera payload identical to the LIVE file is still queued when the live file
# is a mount point (the previous build's bind), not skipped as "nothing to bind".
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
I="$ROOT/common/install.sh"
fail=0; f() { echo "FAIL camera bind requeue: $*" >&2; fail=1; }
body="$(sed -n '/^asb_generate_odm_camera_binds()/,/^}/p' "$I")"
printf '%s\n' "$body" | grep -Fq 'grep -qs " ${_obc_live} " /proc/1/mountinfo /proc/self/mountinfo' \
  || f 'equality with the live file still skips the bind without checking for our own mount'
printf '%s\n' "$body" | grep -Eq '^[[:space:]]*cmp -s "\$_obc_src" "\$_obc_live" 2>/dev/null && continue' \
  && f 'unconditional cmp-skip is back'
grep -Fq 'camera bind: ' "$ROOT/tools/asb_diag.sh" || f 'asbdiag does not show camera bind evidence'
grep -Fq 'nsenter -t 1 -m -- umount "$_ct_live"' "$I" || f 'installer does not take down its own camera bind before declaring the live tone table dirty'
grep -q 'ASB_L_CAM_LIVE_DIRTY2=".*root' "$ROOT/common/englishtext.sh" || f 'dirty-camera advice still says only "reboot and install again"'
[ "$fail" = 0 ] && echo "PASS camera bind requeue contract"
exit "$fail"
