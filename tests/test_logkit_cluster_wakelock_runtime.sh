#!/bin/sh
# Runtime (fix130): the full-day report says which cluster carried the screen-on work and
# who held a wakelock while the phone charged.
#
# An OP15 capture on V65-debug5: the prime above a quarter of its top clock in 90% of the
# screen-on samples, the main cores in 32%, and the split followed the ceilings. The same
# capture's "anomaly: charging idle stayed awake" pointed at a batterystats ranking that was
# empty - batterystats counts nothing on the charger - while the live power-manager samples
# showed a proxy app holding a partial wakelock in every one of them. The REAL report
# functions run on fixtures and a fake two-cluster sysfs.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
FD="$ROOT/tools/logkit/asb_log_full_day.sh"
fail() { echo "FAIL logkit cluster/wakelock: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
F="$T/sys"; O="$T/out"
mkdir -p "$F/cpufreq/policy0" "$F/cpufreq/policy6" "$F/cpu0" "$F/cpu6" "$O"
echo 762 > "$F/cpu0/cpu_capacity"; echo 1024 > "$F/cpu6/cpu_capacity"
echo 3628800 > "$F/cpufreq/policy0/cpuinfo_max_freq"; echo 4608000 > "$F/cpufreq/policy6/cpuinfo_max_freq"
echo "6 7" > "$F/cpufreq/policy6/related_cpus"

echo "epoch|datetime|phase|screen|bl_raw|bl_max|bl_pct|refresh_hz|bat_mA|wake|disp_state" > "$O/display_trace.txt"
echo "epoch|x|x|x|x|x|x|x|x|x|x|x|p0_cur|p0_max|p6_cur|p6_max" > "$O/perf_trace.txt"
i=0
while [ $i -lt 12 ]; do
  e=$((1000 + i * 20))
  echo "$e|d|active|1|1000|4094|25|120|300||" >> "$O/display_trace.txt"
  # 8 samples main 1555200 / prime 1862400 with the prime working; 4 level (1996800) with it idle.
  if [ $i -lt 8 ]; then echo "$e|d|||||||||||883200|1555200|1862400|1862400" >> "$O/perf_trace.txt"
  else echo "$e|d|||||||||||1996800|1996800|768000|1862400" >> "$O/perf_trace.txt"; fi
  i=$((i + 1))
done
for e in 2000 2020 2040 2060; do
  echo "$e|d|charging_idle|0|0|4094|0||-120||" >> "$O/display_trace.txt"
done
cat > "$O/wake_live.txt" <<'X'
1000|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'ScreenOnOnly' ACQ=-50m0s1ms LONG (uid=10999 pid=1);
2000|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'TgWsProxy::ServiceWakeLock' ACQ=-9m7s229ms LONG (uid=10383 pid=16659);PARTIAL_WAKE_LOCK                 '*sync*/com.android.contacts/com.whatsapp' ACQ=-47s696ms (uid=1000 pid=4813 ws=WorkSource{10384});
2020|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'TgWsProxy::ServiceWakeLock' ACQ=-23m57s318ms LONG (uid=10383 pid=16659);PARTIAL_WAKE_LOCK                 'AudioMix' ACQ=-3s916ms (uid=1041 ws=WorkSource{ chains=WorkChain{(10382), (1041)}});
2040|kactive=0|ktop=|plocks=PARTIAL_WAKE_LOCK                 'TgWsProxy::ServiceWakeLock' ACQ=-1h2m4s5ms LONG (uid=10383 pid=16659);
2060|kactive=0|ktop=|plocks=
X
printf '10383 com.amurcanov.tgwsproxy\n10384 com.whatsapp\n1000 com.oplus.atlas\n10382 org.telegram.messenger\n' > "$O/uid_map.txt"

out="$(LK_CPU_SYSFS="$F" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_cluster_work_summary; lk_emit_live_wakelock_holders' "$C" "$O" 2>&1)"
printf '%s\n' "$out" | grep -q '^screen-on samples 12: prime cores working in 66%, main cores in 33%$' || fail "cluster split: $out"
printf '%s\n' "$out" | grep -qE 'level with the prime .*: +4 samples, prime working in 0%' || fail "level bucket: $out"
printf '%s\n' "$out" | grep -qE "below the prime's: +8 samples, prime working in 100%" || fail "below bucket: $out"
printf '%s\n' "$out" | grep -q '^screen-off samples: 4$' || fail "screen-off samples: $out"
printf '%s\n' "$out" | grep -qE '^  held in  75% of samples, longest hold   62 min  TgWsProxy::ServiceWakeLock  \(com.amurcanov.tgwsproxy\)$' || fail "proxy not ranked first with its longest hold: $out"
printf '%s\n' "$out" | grep -q 'com.android.contacts/com.whatsapp  (com.whatsapp)' || fail "compact WorkSource uid not resolved: $out"
printf '%s\n' "$out" | grep -q 'ScreenOnOnly' && fail "a screen-on sample counted: $out"
# Not shown on a three-cluster phone.
mkdir -p "$F/cpufreq/policy2"
out2="$(LK_CPU_SYSFS="$F" sh -c '. "$0" >/dev/null 2>&1; LK_OUT_DIR="$1"; lk_emit_cluster_work_summary' "$C" "$O" 2>&1)"
[ -z "$out2" ] || fail "cluster summary printed on a 3-cluster layout: $out2"
grep -q '^    lk_emit_cluster_work_summary$' "$FD" || fail "report does not include the cluster summary"
grep -q '^  lk_emit_live_wakelock_holders$' "$FD" || fail "report does not include the live wakelock holders"
grep -q 'LIVE WAKELOCK HOLDERS below names who held the CPU' "$FD" || fail "charging verdict still points at the empty ranking"
echo "PASS logkit cluster/wakelock: screen-on work by cluster, wakelock holders while charging"
