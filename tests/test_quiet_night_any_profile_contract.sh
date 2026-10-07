#!/bin/sh
# Contract: Quiet Night is eligible inside the night window on any profile.
#
# A full OP15 night on Smart (battery weight 0.45-0.79, under the 0.8 "battery-like" bar)
# never entered Quiet Night, while two daytime screen-offs did. The mode trims the
# governor's own footprint on a sleeping phone; the profile's performance lean is not a
# reason to keep polling all night. Outside the window the battery-like rule still applies.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail=0; f() { echo "FAIL quiet night eligibility: $*" >&2; fail=1; }
grep -Fq '(asb_profile_battery_like(fsm.profile_idx) || _qn_window) &&' "$G" || f 'night window does not make any profile eligible'
grep -Fq 'if (g_asb_cfg.night_quiet_enable && fsm.state == ASB_STATE_DEEP_IDLE &&' "$G" || f 'window is not gated by night_quiet_enable'
grep -Fq 'if (!_use_fast) _use_fast = _qn_window;' "$G" || f 'night window no longer speeds up entry'
[ "$fail" = 0 ] && echo "PASS quiet night any-profile contract"
exit "$fail"
