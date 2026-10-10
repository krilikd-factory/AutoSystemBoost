#!/bin/sh
# fix90: (1) never disable the kernel's reboot-on-panic / panic-on-oops - a wedged phone
# (OP12: black launcher, alarm missed, reboot fixed it) is worse than any saving;
# (2) LIGHT_IDLE escalates when the main cores sit at the light-idle ceiling (OP15: 52% of
# screen-on LIGHT_IDLE samples pinned at 1440 MHz).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL fix90: $*" >&2; exit 1; }
grep -rnE 'sysctlw kernel\.panic(_on_oops)? |/proc/sys/kernel/panic(_on_oops)?' \
  "$ROOT/service.sh" "$ROOT/post-fs-data.sh" "$ROOT/runtime" "$ROOT/profiles" 2>/dev/null \
  | grep -v '^\s*#' | grep -v ':[0-9]*: *#' && fail "a script still writes kernel.panic / panic_on_oops"
F="$ROOT/src/asb_fsm.h"
grep -Fq '#define ASB_LI_PIN_HOLD_S 20' "$F" || fail "pin hold constant"
grep -Fq 'int _pinned = (_max > 0 && _cur > 0 && _cur * 100 >= _max * 98);' "$F" || fail "pinned test"
grep -Fq 'if (m->misc.screen_on && !fsm_profile_is_battery && !m->misc.camera_active) {' "$F" || fail "escalation must be screen-on, not Battery, not camera"
grep -Fq 'light_idle_pin_escalations=' "$ROOT/src/asb_governor.c" || fail "escalations not published"
grep -q 'resetprop -n tombstoned.max_tombstone_count 0' "$ROOT/post-fs-data.sh" && fail "native crash records still thrown away"
grep -Eq 'for _svc in .*(minidump|mtdoopslog|bootstat)' "$ROOT/service.sh" && fail "bg_trim still stops the crash recorders"
grep -Fq 'kernel panic policy' "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not show the panic policy"
for _k in persist.sys.crash_dumps persist.sys.pstore_dumps persist.sys.mdlog_dumpback \
          persist.sys.oom_crash_on_watchdog persist.sys.stability.nativehang.enable \
          persist.sys.stability.nativehangII.enable persist.sys.stability.qcom_hang_task.enable \
          persist.sys.stability.scout.enable persist.sys.stability.enable_res_leak_abort; do
  grep -q "^$_k=" "$ROOT/runtime/asb_managed.props" && fail "managed props still set $_k"
done
echo "PASS fix90: panic reboot left to the vendor, pinned light idle escalates"
