#!/bin/sh
# Runtime (fix126): the full-day capture says, per cluster, WHO put a ceiling under ASB's
# profile rail - ASB's own thermal-budget trim or a ceiling ASB did not write.
#
# The fix124 capture logged 20 minutes as "owner=asb" while the prime sat at a 1632000 vendor
# ceiling under ASB's 1862400 request; and the prime column was compared with governor slot 1,
# which is a middle cluster on 1+3+2+1 parts (OP12, Ace 5).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
FD="$ROOT/tools/logkit/asb_log_full_day.sh"
G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL throttle cause: $*" >&2; fail=1; }

cat > "$T/tt" <<'EOF'
# throttle trace
1791715890|active|p0_max=1670400/3628800|p6_max=1862400/4608000|cpu_temp=54|surface=41|cap_owner=asb|main_by=asb_trim|prime_by=-
1791715985|audio|p0_max=1785600/3628800|p6_max=1632000/4608000|cpu_temp=42|surface=39|cap_owner=asb|main_by=-|prime_by=vendor
1791716032|audio|p0_max=1555200/3628800|p6_max=1632000/4608000|cpu_temp=39|surface=38|cap_owner=asb|main_by=asb_trim|prime_by=vendor
1791716079|audio|p0_max=1555200/3628800|p6_max=1632000/4608000|cpu_temp=39|surface=38|cap_owner=asb
EOF
out="$(sh -c '
  . "$0" >/dev/null 2>&1
  echo "c1=$(lk_cap_cause 1632000 1862400 1862400)"
  echo "c2=$(lk_cap_cause 1555200 1785600 1555200)"
  echo "c3=$(lk_cap_cause 1862400 1862400 1862400)"
  echo "c4=$(lk_cap_cause 1555200 1785600 "")"
  echo "c5=$(lk_cap_cause "" 1785600 1555200)"
  lk_emit_cap_cause_split "$1"
' "$C" "$T/tt" 2>&1)"
printf '%s\n' "$out" | grep -qx 'c1=vendor'   || f "live under ASB's request is not a foreign ceiling: $out"
printf '%s\n' "$out" | grep -qx 'c2=asb_trim' || f "live == ASB's trimmed request is not ASB's trim: $out"
printf '%s\n' "$out" | grep -qx 'c3=-'        || f "at the rail must read '-': $out"
printf '%s\n' "$out" | grep -qx 'c4=?'        || f "no request must read '?': $out"
printf '%s\n' "$out" | grep -qx 'c5=?'        || f "no live value must read '?': $out"
printf '%s\n' "$out" | grep -q 'who held the lower ceiling, per cluster (3 samples):' || f "old rows without *_by must be skipped: $out"
printf '%s\n' "$out" | grep -qE '^  main: +asb_trim 2$'  || f "main split wrong: $out"
printf '%s\n' "$out" | grep -qE '^  prime: +vendor 2$'   || f "prime split wrong: $out"

# The recorder and the governor.
grep -q 'lk_state_kv desired_cpu_max_prime' "$FD" || f "prime compared with slot 1, not the prime"
grep -q '|main_by=${_mb}|prime_by=${_pb}"' "$FD" || f "rows carry no per-cluster cause"
grep -q 'lk_emit_cap_cause_split "$LK_OUT_DIR/throttle_trace.txt"' "$FD" || f "report does not print the split"
grep -q 'requested_cpu_max0=%d\\nrequested_cpu_max_prime=%d' "$G" || f "governor does not publish what it wrote"
grep -q 'g_fsm_slot_req_khz\[i\] = cmax\[i\];' "$ROOT/src/asb_writer.h" || f "writer does not record its kept request"
grep -q 'writer_slot_ceiling(1, fsm->current_caps.cpu_max\[1\], fsm->thermal_cap)' "$G" || f "slot 1 figure still snapped with table index 1"

[ "$fail" = 0 ] && echo "PASS throttle cause: per-cluster asb_trim / vendor, prime compared with the prime"
exit "$fail"
