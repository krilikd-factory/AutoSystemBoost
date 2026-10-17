#!/bin/sh
# Runtime (fix144): a governor that died is restarted, and nothing pretends to check it.
#
# The governor scheduled "asb_watchdog.sh --once" and "asb_reconcile.sh --once" itself. The
# watchdog exited on its first line (ASB_GOV_ENABLED is not in the governor's environment) and
# could never catch the death of the process that scheduled it; reconcile's --once broke out
# of its loop before the first check. Both forked shells every few minutes for nothing, and
# a crashed governor left its last ceilings in place until a reboot. service.sh's housekeeping
# loop now checks the pid (asb_gov_liveness); asbdiag tells boots, clean restarts and crashes
# apart from the persistent log. The REAL function runs here.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL gov liveness: $*" >&2; fail=1; }

sed -n '/^# asb_gov_liveness_begin$/,/^# asb_gov_liveness_end$/p' "$ROOT/service.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || { echo "FAIL gov liveness: no asb_gov_liveness block in service.sh" >&2; exit 1; }
grep -q '^    asb_gov_liveness$' "$ROOT/service.sh" || f "housekeeping loop does not call asb_gov_liveness"

sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null
mkdir -p "$T/mod"; echo smart > "$T/mod/current_profile"

out="$(MODDIR="$T/mod" ASB_GOV_PIDFILE="$T/gov.pid" ASB_SAFE_MODE_FILE="$T/safe" T="$T" DEAD="$DEAD" sh -c '
  . "$T/fn.sh"
  asb_feature_enabled() { [ "$(cat "$T/cpu" 2>/dev/null)" != 0 ]; }
  asb_log() { echo "LOG $*"; }
  asb_governor_start() { echo START; echo "$$" > "$ASB_GOV_PIDFILE"; }
  echo "-- none";  asb_gov_liveness
  echo "$$" > "$ASB_GOV_PIDFILE"
  echo "-- alive"; asb_gov_liveness
  echo "$DEAD" > "$ASB_GOV_PIDFILE"
  echo "-- dead";  asb_gov_liveness
  echo "-- after"; asb_gov_liveness
  touch "$T/safe"; echo "$DEAD" > "$ASB_GOV_PIDFILE"
  echo "-- safe";  asb_gov_liveness
  rm -f "$T/safe"; echo stock > "$MODDIR/current_profile"
  echo "-- stock"; asb_gov_liveness; [ -e "$ASB_GOV_PIDFILE" ] && echo "PIDFILE KEPT"
  echo smart > "$MODDIR/current_profile"
  for i in 2 3 4 5; do echo "$DEAD" > "$ASB_GOV_PIDFILE"; echo "-- loop$i"; asb_gov_liveness; done
  _gl_w0=$(( _gl_w0 - 1900 )); echo "$DEAD" > "$ASB_GOV_PIDFILE"
  echo "-- window"; asb_gov_liveness
  echo 0 > "$T/cpu"; echo "$DEAD" > "$ASB_GOV_PIDFILE"
  echo "-- nocpu"; asb_gov_liveness; [ -e "$ASB_GOV_PIDFILE" ] && echo "PIDFILE KEPT"
' 2>&1)"
sec() { printf '%s\n' "$out" | awk -v s="-- $1" '$0 == s { f = 1; next } /^-- / { f = 0 } f'; }
[ -z "$(sec none)" ] || f "acted with no pid file: $(sec none)"
[ -z "$(sec alive)" ] || f "acted on a live governor: $(sec alive)"
sec dead | grep -q '^START$' || f "dead governor not restarted: $out"
sec dead | grep -q "^LOG governor: pid $DEAD had died without a clean stop - restarted (1 in 30 min)$" || f "restart not logged: $out"
[ -z "$(sec after)" ] || f "acted again on the restarted governor: $(sec after)"
[ -z "$(sec safe)" ] || f "restarted in safe mode: $(sec safe)"
[ -z "$(sec stock)" ] || f "restarted under stock: $(sec stock)"
printf '%s\n' "$out" | grep -q 'PIDFILE KEPT' && f "a stale pid file left where no governor belongs: $out"
sec loop2 | grep -q 'restarted (2 in 30 min)' || f "second restart: $out"
sec loop3 | grep -q 'restarted (3 in 30 min)' || f "third restart: $out"
sec loop4 | grep -q '^START$' && f "a fourth restart inside 30 min (crash loop fed): $out"
sec loop4 | grep -q 'died again after 3 restarts in 30 min' || f "crash loop not logged: $out"
[ -z "$(sec loop5)" ] || f "crash-loop line repeated: $(sec loop5)"
sec window | grep -q 'restarted (1 in 30 min)' || f "no restart once the window passed: $out"
[ -z "$(sec nocpu)" ] || f "restarted with the CPU feature off: $(sec nocpu)"

# The governor no longer spawns the two no-op scripts.
G="$ROOT/src/asb_governor.c"
grep -q 'runtime/asb_reconcile.sh"' "$G" && f "governor still spawns asb_reconcile.sh --once"
grep -q 'runtime/asb_watchdog.sh"' "$G" && f "governor still spawns asb_watchdog.sh --once"
grep -q 'started (pid %d, %lds after boot)' "$G" || f "start line without seconds since boot"
grep -q 'asb_governor stopped cleanly (pid %d)' "$G" || f "clean exit not logged"

# asbdiag: boots, clean restarts and crashes apart.
sed -n '/^# asb_gov_starts_begin$/,/^# asb_gov_starts_end$/p' "$ROOT/tools/asb_diag.sh" > "$T/gs.sh"
[ -s "$T/gs.sh" ] || f "asbdiag has no asb_gov_starts block"
cat > "$T/persist" <<'EOF'
[10-12 22:44:48] asb_governor V65 started (pid 15917)
[10-13 10:35:20] asb_governor V65 started (pid 15147, 45s after boot)
[10-13 11:02:00] smart store flushed on shutdown
[10-13 11:02:00] asb_governor stopped cleanly (pid 15147)
[10-13 11:02:02] asb_governor V65 started (pid 16001, 1662s after boot)
[10-13 12:40:10] asb_governor V65 started (pid 16420, 7530s after boot)
[10-13 20:00:00] asb_governor V65 started (pid 1500, 38s after boot)
EOF
r="$(sh -c '. "$1"; asb_gov_starts < "$2"' x "$T/gs.sh" "$T/persist")"
[ "$r" = "4 2 1 1" ] || f "asbdiag start classification: '$r' (want 4 starts: 2 at boot, 1 after a clean stop, 1 after a crash)"
r="$(printf '[x] asb_governor V65 started (pid 1)\n' | sh -c '. "$1"; asb_gov_starts' x "$T/gs.sh")"
[ -z "$r" ] || f "asbdiag classified pre-fix144 lines: $r"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f "asbdiag copies differ"

[ "$fail" = 0 ] && echo "PASS gov liveness: dead governor restarted (not under stock/safe mode, no crash-loop feeding), no-op spawns gone, starts classified"
exit "$fail"
