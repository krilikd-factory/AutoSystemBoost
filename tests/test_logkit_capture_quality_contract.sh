#!/bin/sh
# Contract: full-day telemetry improvements must remain observer-only and phase-stable.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LOGKIT="$ROOT/tools/logkit/asb_log_full_day.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

need() { grep -Fq -- "$2" "$1" >/dev/null || { echo "FAIL logkit capture-quality: missing [$2]" >&2; exit 1; }; }

[ -f "$LOGKIT" ] || { echo "FAIL logkit capture-quality: missing full-day logkit" >&2; exit 1; }
sh -n "$LOGKIT"

# Extract the standalone debounce function: this avoids sourcing a device-only recorder.
sed -n '/^lk_stabilize_charging_phase() {/,/^}/p' "$LOGKIT" > "$TMP/debounce.sh"
[ -s "$TMP/debounce.sh" ] || { echo "FAIL logkit capture-quality: cannot extract debounce helper" >&2; exit 1; }
. "$TMP/debounce.sh"

LK_CHG_PHASE_STABLE=""
LK_CHG_IDLE_CANDIDATE_SINCE=0
LK_CHG_IDLE_DEBOUNCE_S=45
LK_CHG_IDLE_COALESCED=0
# Charging-idle telemetry is intentionally less frequent than visible charging/gaming so an
# opt-in diagnostic capture does not itself keep a plugged, screen-off device busy.
need "$LOGKIT" 'LK_POLL_CHARGING_IDLE=60'
need "$LOGKIT" 'charging_idle)          echo "$LK_POLL_CHARGING_IDLE" ;'
sed -n '/^lk_poll_for_phase() {/,/^}/p' "$LOGKIT" > "$TMP/cadence.sh"
[ -s "$TMP/cadence.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract cadence helper' >&2; exit 1; }
LK_POLL_FAST=15 LK_POLL_NORMAL=45 LK_POLL_SLOW=90 LK_POLL_CHARGING_IDLE=60
. "$TMP/cadence.sh"
[ "$(lk_poll_for_phase charging_idle)" = 60 ] || { echo 'FAIL logkit capture-quality: charging-idle cadence' >&2; exit 1; }
[ "$(lk_poll_for_phase charging_active)" = 15 ] || { echo 'FAIL logkit capture-quality: visible charging cadence' >&2; exit 1; }
[ "$(lk_poll_for_phase gaming)" = 15 ] || { echo 'FAIL logkit capture-quality: gaming cadence' >&2; exit 1; }
[ "$(lk_poll_for_phase sleep)" = 90 ] || { echo 'FAIL logkit capture-quality: sleep cadence' >&2; exit 1; }
lk_stabilize_charging_phase charging_active 100
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: first active sample" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 115
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: short idle must stay active" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 145
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: debounce must remain bounded" >&2; exit 1; }
lk_stabilize_charging_phase charging_idle 160
[ "$LK_CHG_PHASE_OUT" = charging_idle ] || { echo "FAIL logkit capture-quality: sustained idle must commit" >&2; exit 1; }
lk_stabilize_charging_phase charging_active 161
[ "$LK_CHG_PHASE_OUT" = charging_active ] || { echo "FAIL logkit capture-quality: visible screen use must be immediate" >&2; exit 1; }
[ "$LK_CHG_IDLE_COALESCED" -ge 2 ] || { echo "FAIL logkit capture-quality: coalesced counter" >&2; exit 1; }

need "$LOGKIT" 'LK_SCREENOFF_LONGEST_S=0'
need "$LOGKIT" '----- CAPTURE VALIDITY -----'
need "$LOGKIT" 'night verdict: unavailable'
need "$LOGKIT" '----- CAP OWNERSHIP VERDICT -----'
need "$LOGKIT" 'Native vendor holddown/detente'
need "$LOGKIT" 'throttle samples logged: $_tc (poll observations, not independent clamp incidents)'
need "$LOGKIT" 'continuous clamp periods (new period after >180s gap or owner change):'
need "$LOGKIT" 'owner=%-8s duration=%4d min samples=%d'
need "$LOGKIT" "_tc=\$(awk -F'|' 'NR>1 && NF>=6 {n++} END{print n+0}'"
if grep -Fq '%s..%s\\\\n", own' "$LOGKIT"; then
  echo 'FAIL logkit capture-quality: grouping would print literal \\n' >&2
  exit 1
fi
cat > "$TMP/throttle_trace.txt" <<'EOF_TRACE'
# throttle trace — epoch | phase | p0 | p6 | temps | cap_owner
100|active|p0_max=1/2|p6_max=1/2|cpu_temp=45|surface=40|cap_owner=vendor
160|active|p0_max=1/2|p6_max=1/2|cpu_temp=46|surface=41|cap_owner=vendor
400|idle|p0_max=1/2|p6_max=1/2|cpu_temp=44|surface=39|cap_owner=asb
EOF_TRACE
_count="$(awk -F'|' 'NR>1 && NF>=6 {n++} END{print n+0}' "$TMP/throttle_trace.txt")"
[ "$_count" = 3 ] || { echo "FAIL logkit capture-quality: expected 3 data rows, got $_count" >&2; exit 1; }
_grouped="$(awk -F'|' '
  function emit(){ if(n>0) printf "owner=%s samples=%d epoch=%s..%s\n", own, n, start, last }
  NR==1 {next}; NF<6 {next}
  { split($0,a,"cap_owner="); own_now=a[2]; sub(/\|.*/,"",own_now); now=$1+0
    if(n==0){start=now;last=now;own=own_now;n=1;next}
    if((now-last)>180 || own_now!=own){emit();start=now;own=own_now;n=1}else n++
    last=now }
  END{emit()}
' "$TMP/throttle_trace.txt")"
printf '%s\n' "$_grouped" | grep -Fqx 'owner=vendor samples=2 epoch=100..160' || { echo 'FAIL logkit capture-quality: vendor period grouping' >&2; exit 1; }
printf '%s\n' "$_grouped" | grep -Fqx 'owner=asb samples=1 epoch=400..400' || { echo 'FAIL logkit capture-quality: ASB period grouping' >&2; exit 1; }
case "$_grouped" in *'\\n'*) echo 'FAIL logkit capture-quality: literal \\n in fixture output' >&2; exit 1 ;; esac
need "$LOGKIT" '----- CHARGING-IDLE AWAKE VERDICT -----'
need "$LOGKIT" 'ASB does not alter charge current or kill apps automatically.'
need "$LOGKIT" 'lk_charge_idle_observe "$_phase"'
# The source-class report is a passive observed-context diagnostic. It must never claim a
# causal battery percentage by class, and may only cover adjacent same-class samples.
need "$LOGKIT" '===== SCREEN-OFF CLASS OBSERVATIONS ====='
need "$LOGKIT" 'screenoff_class_trace.tsv'
need "$LOGKIT" 'lk_capture_screenoff_class_row "$_phase"'
need "$LOGKIT" 'intervals <=180s'
need "$LOGKIT" 'not a percentage or causal energy allocation'
sed -n '/^lk_emit_screenoff_class_summary() {/,/^}/p' "$LOGKIT" > "$TMP/screenoff_summary.sh"
[ -s "$TMP/screenoff_summary.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract screen-off summary' >&2; exit 1; }
cat > "$TMP/screenoff_class_trace.tsv" <<'EOF_CLASS'
# epoch|phase|class|awake_pct|window_min|bat_mA|reason
100|sleep|quiet|2|55|80|low awake / no media or network
160|sleep|quiet|4|56|100|low awake / no media or network
230|idle|network|28|58|240|active mobile transfer
700|idle|network|31|60|280|active mobile transfer
EOF_CLASS
LK_OUT_DIR="$TMP"
. "$TMP/screenoff_summary.sh"
_class_summary="$(lk_emit_screenoff_class_summary)"
printf '%s\n' "$_class_summary" | grep -Eq '^quiet[[:space:]]+2[[:space:]]+1\.0' || { echo 'FAIL logkit capture-quality: quiet observed coverage' >&2; exit 1; }
printf '%s\n' "$_class_summary" | grep -Eq '^network[[:space:]]+2[[:space:]]+0\.0' || { echo 'FAIL logkit capture-quality: gap must not be attributed to network class' >&2; exit 1; }
printf '%s\n' "$_class_summary" | grep -Fq 'not a percentage or causal energy allocation' || { echo 'FAIL logkit capture-quality: causal allocation disclaimer missing' >&2; exit 1; }

# Current and capacity-percent rates are complementary measurements, not source attribution.
# A synthetic ledger verifies both the aligned path and the explicit >30% quality warning.
need "$LOGKIT" '===== CURRENT / SOC CONSISTENCY (MEASUREMENT QUALITY) ====='
need "$LOGKIT" 'A CHECK result is a measurement-consistency warning, not causal energy attribution.'
sed -n '/^lk_emit_current_soc_consistency() {/,/^}/p' "$LOGKIT" > "$TMP/current_soc_summary.sh"
[ -s "$TMP/current_soc_summary.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract current/SOC helper' >&2; exit 1; }
cat > "$TMP/phase_ledger.tsv" <<'EOF_LEDGER'
# phase	start	end	start_pct	end_pct	maxCpuT	maxSurfT	maxP6	gpuAvg	throttle	wakePeak	awakePct	avgMA	rmnetRxBytes	rmnetTxBytes
sleep	0	3600	90	88	40	35	1000000	0	0	0	2	100	0	0
idle	3600	7200	88	87	42	36	1000000	0	0	0	5	400	0	0
EOF_LEDGER
LK_OUT_DIR="$TMP" LK_BATTERY_CAPACITY_MAH=5000
. "$TMP/current_soc_summary.sh"
_consistency="$(lk_emit_current_soc_consistency)"
printf '%s\n' "$_consistency" | grep -Eq '^sleep[[:space:]]+60\.0[[:space:]]+2\.00[[:space:]]+2\.00[[:space:]]+0\.0%[[:space:]]+aligned$' || { echo 'FAIL logkit capture-quality: aligned current/SOC verdict' >&2; exit 1; }
printf '%s\n' "$_consistency" | grep -Eq '^idle[[:space:]]+60\.0[[:space:]]+1\.00[[:space:]]+8\.00[[:space:]]+87\.5%[[:space:]]+CHECK \(>30%\)$' || { echo 'FAIL logkit capture-quality: current/SOC check verdict' >&2; exit 1; }
printf '%s\n' "$_consistency" | grep -Fq 'not causal energy attribution' || { echo 'FAIL logkit capture-quality: current/SOC causal disclaimer missing' >&2; exit 1; }

# Per-phase distribution must use raw battery samples mapped to each concrete ledger interval,
# not a median of phase averages. The outlier makes this distinction visible: mean=250 but
# median=100 for the two disjoint active intervals. The endpoint rule must not double-count
# the transition sample at epoch 200, while epoch 400 belongs once to the final interval.
need "$LOGKIT" '===== SAMPLED CURRENT DISTRIBUTION ====='
need "$LOGKIT" 'raw positive discharge samples'
need "$LOGKIT" 'not physical whole-phase averages'
need "$LOGKIT" 'Suspend and intervals between recorder wake-ups are under-sampled'
sed -n '/^lk_emit_sampled_current_distribution() {/,/^}/p' "$LOGKIT" > "$TMP/sampled_current_distribution.sh"
[ -s "$TMP/sampled_current_distribution.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract sampled-current helper' >&2; exit 1; }
cat > "$TMP/phase_ledger.tsv" <<'EOF_SAMPLE_LEDGER'
# phase	start	end	start_pct	end_pct	maxCpuT	maxSurfT	maxP6	gpuAvg	throttle	wakePeak	awakePct	avgMA	rmnetRxBytes	rmnetTxBytes
active	100	200	90	90	40	35	1000000	0	0	0	0	0	0	0
idle	200	300	90	90	40	35	1000000	0	0	0	0	0	0	0
active	300	400	90	90	40	35	1000000	0	0	0	0	0	0	0
EOF_SAMPLE_LEDGER
cat > "$TMP/battery_trace.txt" <<'EOF_SAMPLE_TRACE'
epoch|datetime|fsm_state|profile|screen|bat_pct|bat_mA
100|x|x|x|1|90|100000
150|x|x|x|1|90|100000
199|x|x|x|1|90|1000000
200|x|x|x|0|90|900000
250|x|x|x|0|90|-100000
300|x|x|x|1|90|100000
350|x|x|x|1|90|100000
400|x|x|x|1|90|100000
EOF_SAMPLE_TRACE
LK_OUT_DIR="$TMP"
. "$TMP/sampled_current_distribution.sh"
_sampled_current="$(lk_emit_sampled_current_distribution "$TMP/phase_ledger.tsv")"
printf '%s\n' "$_sampled_current" | grep -Eq '^active[[:space:]]+3\.3[[:space:]]+6[[:space:]]+250\.0[[:space:]]+100\.0$' || { echo 'FAIL logkit capture-quality: mapped active raw-sample mean/median' >&2; exit 1; }
printf '%s\n' "$_sampled_current" | grep -Eq '^idle[[:space:]]+1\.7[[:space:]]+1[[:space:]]+900\.0[[:space:]]+900\.0$' || { echo 'FAIL logkit capture-quality: endpoint belongs to next interval once' >&2; exit 1; }
printf '%s\n' "$_sampled_current" | grep -Fq 'not causal attribution' || { echo 'FAIL logkit capture-quality: sampled-current disclaimer missing' >&2; exit 1; }

# Mobile traffic is a qualified phase context only. Aggregate two active blocks across the
# 32 MiB report-only threshold and keep a 31 MiB idle block out of the listing.
need "$LOGKIT" '===== MOBILE TRAFFIC CONTEXT ====='
need "$LOGKIT" 'LK_MOBILE_TRAFFIC_CONTEXT_MIN_MIB=32'
need "$LOGKIT" 'does not prove cause or assign battery percentage'
sed -n '/^lk_emit_mobile_traffic_context() {/,/^}/p' "$LOGKIT" > "$TMP/mobile_traffic_context.sh"
[ -s "$TMP/mobile_traffic_context.sh" ] || { echo 'FAIL logkit capture-quality: cannot extract mobile-traffic helper' >&2; exit 1; }
cat > "$TMP/phase_ledger.tsv" <<'EOF_TRAFFIC_LEDGER'
# phase	start	end	start_pct	end_pct	maxCpuT	maxSurfT	maxP6	gpuAvg	throttle	wakePeak	awakePct	avgMA	rmnetRxBytes	rmnetTxBytes
active	100	200	90	90	40	35	1000000	0	0	0	0	0	20971520	0
idle	200	300	90	90	40	35	1000000	0	0	0	0	0	32505856	0
active	300	400	90	90	40	35	1000000	0	0	0	0	0	13631488	0
EOF_TRAFFIC_LEDGER
LK_OUT_DIR="$TMP" LK_MOBILE_TRAFFIC_CONTEXT_MIN_MIB=32
. "$TMP/mobile_traffic_context.sh"
_traffic_context="$(lk_emit_mobile_traffic_context "$TMP/phase_ledger.tsv")"
printf '%s\n' "$_traffic_context" | grep -Eq '^active[[:space:]]+3\.3[[:space:]]+33\.0[[:space:]]+screen-on$' || { echo 'FAIL logkit capture-quality: aggregated traffic context' >&2; exit 1; }
if printf '%s\n' "$_traffic_context" | grep -Eq '^idle[[:space:]]'; then
  echo 'FAIL logkit capture-quality: below-threshold mobile traffic was listed' >&2
  exit 1
fi
printf '%s\n' "$_traffic_context" | grep -Fq 'does not prove cause or assign battery percentage' || { echo 'FAIL logkit capture-quality: mobile-traffic disclaimer missing' >&2; exit 1; }

# New verdict code must remain read-only: no global runtime-policy writes are allowed here.
if grep -nE 'setprop|settings[[:space:]]+put|sysctl[[:space:]]+-w|swapoff|svc[[:space:]]+power|reboot' "$LOGKIT" >/dev/null 2>&1; then
  echo "FAIL logkit capture-quality: full-day telemetry gained a policy write" >&2
  exit 1
fi

echo 'PASS logkit capture-quality telemetry contract'
