#!/bin/sh
# Runtime (fix156): the comparison reads how the clusters were used while the phone was warm.
#
# fix156 keeps the main cores level with the prime under Smart's comfort trim and in HEAVY and
# SUSTAINED. What should change in the next round of logs: fewer warm screen-on samples with the
# main ceiling under the prime's, the prime working less, a lower sampled current. The REAL
# tool computes those from the raw traces of a capture (so captures made before the report
# printed them compare too): screen-on samples only, surface 40 C and above, capacities from the
# governor state, hardware maxima from the throttle trace; and the --baseline table names them.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TOOL="$ROOT/tools/asb_capture_compare.py"
fail() { echo "FAIL capture compare warm: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP capture compare warm: no python3"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cap() {
  d="$T/$1"; mkdir -p "$d"
  printf 'model:           CPH2745\nmodule_version:  V65-debug%s\n' "$2" > "$d/env.txt"
  printf '%s|2026-10-20 08:00:00|active|capture_start\n' "$3" > "$d/phase_timeline.txt"
  printf ' capture: 24h target, 600 min elapsed\n' > "$d/_full_day_report.txt"
  printf 'main_parity_capacity="762,1024"\n' > "$d/snapshot_1.txt"
  printf '# throttle trace\n%s|active|p0_max=1555200/3628800|p6_max=1862400/4608000|cpu_temp=50\n' "$3" > "$d/throttle_trace.txt"
  echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$d/display_trace.txt"
  echo "epoch|datetime|x|x|x|x|x|x|x|x|x|x|p0_cur|p0_max|p6_cur|p6_max|x|x|x|x|x|bat_mA|x|x|x|x|x|x|x|x|x|x|x|x|x|surface_c" > "$d/perf_trace.txt"
}
row() {   # dir epoch screen p0_max p6_cur p6_max mA surface
  echo "$2|d|active|$3|1|1|1|90|1||" >> "$T/$1/display_trace.txt"
  echo "$2|d|||||||||||1|$4|$5|$6||||||$7||||||||||||||$8" >> "$T/$1/perf_trace.txt"
}
cap old 8 1000
e=1000
for i in 1 2 3 4; do row old $e 1 1555200 1862400 1862400 480 44; e=$((e + 20)); done
for i in 1 2; do row old $e 1 1996800 768000 1862400 340 43; e=$((e + 20)); done
row old $e 1 1555200 1862400 1862400 900 33; e=$((e + 20))
row old $e 0 1555200 1862400 1862400 900 45; e=$((e + 20))
cap new 10 5000
e=5000
for i in 1 2 3 4 5; do row new $e 1 1996800 768000 1862400 330 44; e=$((e + 20)); done
row new $e 1 1996800 1862400 1862400 410 42
python3 "$TOOL" "$T/old" --json "$T/base.json" --label old > "$T/o1" 2>&1 || { cat "$T/o1" >&2; fail "tool failed"; }
python3 - "$T/base.json" <<'P' || fail "warm figures of the old capture"
import json, sys
c = json.load(open(sys.argv[1]))["captures"][0]
want = {"warm_on_n": 6, "warm_below_pct": 66.7, "warm_prime_pct": 66.7, "warm_on_ma": 433}
bad = {k: (c.get(k), v) for k, v in want.items() if c.get(k) != v}
if bad:
    print(bad); sys.exit(1)
P
python3 "$TOOL" "$T/new" --baseline "$T/base.json" > "$T/o2" 2>&1 || { cat "$T/o2" >&2; fail "comparison failed"; }
grep -qE '^warm: main under prime % +66\.70 +0\.00 +-66\.70 \(-100%\) +better' "$T/o2" || fail "main-under-prime row: $(cat "$T/o2")"
grep -qE '^warm: prime working % +66\.70 +16\.70 .* better' "$T/o2" || fail "prime row: $(cat "$T/o2")"
grep -qE '^warm screen-on mA +433 +343 .* better' "$T/o2" || fail "current row: $(cat "$T/o2")"
cap cool 9 9000
e=9000
for i in 1 2 3 4 5 6; do row cool $e 1 1555200 1862400 1862400 480 35; e=$((e + 20)); done
python3 "$TOOL" "$T/cool" --json "$T/cool.json" > "$T/o3" 2>&1 || fail "cool capture"
python3 -c "import json,sys; c=json.load(open(sys.argv[1]))['captures'][0]; sys.exit(0 if c['warm_on_n'] is None and c['warm_on_ma'] is None else 1)" "$T/cool.json" || fail "a capture that never got warm produced warm figures"
echo "PASS capture compare warm: warm screen-on samples, main under the prime, prime work and current, from the raw traces"
