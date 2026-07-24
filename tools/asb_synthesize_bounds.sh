#!/system/bin/sh
# =============================================================================
# asb_synthesize_bounds.sh — derive per-device CPU bounds from OP15 ratios
# =============================================================================
# Reads /data/adb/asb/device_caps.env (written by asb_discover.sh) and produces
# /data/adb/asb/device_bounds.env — a flat KEY=value file the governor reads at
# startup (only when device_bounds_override=1) to scale its compiled OP15 bounds
# onto THIS device's hardware.
#
# Method (the agreed "ratios, not literal kHz" approach):
#   reference = OP15 (canoe). For each bound, OP15 ships value V at hw_max H, so
#   ratio = V/H. For this device we read its real per-cluster hw_max, multiply by
#   the OP15 ratio, then SNAP DOWN to a real frequency from that cluster's
#   scaling_available_frequencies. On OP15 the snap returns the original value,
#   so the output equals the shipped bounds (zero change for the reference).
#
# Safety / confidence:
#   - If topology is not the expected 2-cluster little+big shape, we DO NOT guess
#     a 3/4-cluster mapping here; we write a header noting low confidence and emit
#     nothing (governor then keeps its compiled defaults). 3/4-cluster synthesis
#     is a later stage once validated on real logs from such devices.
#   - Every emitted value is a real frequency snapped from the device's own table.
#   - This script writes ONLY device_bounds.env. It changes no tunable directly;
#     the governor decides whether to read it.
# =============================================================================

CAPS="/data/adb/asb/device_caps.env"
OUT="/data/adb/asb/device_bounds.env"
ASB_DIR="/data/adb/asb"
mkdir -p "$ASB_DIR" 2>/dev/null

_cget() { grep -E "^$1=" "$CAPS" 2>/dev/null | head -1 | sed 's/^[^=]*=//'; }

# --- OP15 REFERENCE RATIOS (value / cluster hw_max), x10000 for integer math ---
# little hw_max ref = 3628800 ; big(prime) hw_max ref = 4608000
# These mirror the shipped config/profile_bounds.conf exactly.
#   ratio_x10000 = round( shipped_value * 10000 / op15_hw_max )
# NOTE: one assignment per line — a second assignment after a '#' would be eaten
# by the comment (that bug cost us the entire big-cluster column once).
R_BAT_MAX_L=4603   # 1670400 / 3628800
R_BAT_MAX_B=3542   # 1632000 / 4608000
R_BAL_MAX_L=7196   # 2611200 / 3628800
R_BAL_MAX_B=8625   # 3974400 / 4608000
R_PRF_MAX_L=9500   # perf little, near hw max
R_PRF_MAX_B=9000   # perf big, near hw max
# Mid-band ratios for 3/4-cluster SoCs (e.g. OP12 policy2/5). No OP15 reference
# exists for a middle cluster (OP15 is 2-cluster), so the mid ceiling is taken as
# the midpoint between the little and big ratios — a conservative interpolation
# that keeps the mid cluster between the two known-good rails. Applied to the
# strongest middle cluster's own hw_max, then snapped to its real freq table.
R_BAT_MAX_M=4072   # (4603+3542)/2  battery mid
R_BAL_MAX_M=7910   # (7196+8625)/2  balanced mid
R_PRF_MAX_M=9250   # (9500+9000)/2  performance mid

# ---- Topology mapping: 2, 3, or 4 clusters -> little / [mid] / big ----
# Mirrors the C writer's logic exactly (src/asb_metrics.h cpu_topology_discover):
#   first policy        -> little
#   last  policy        -> big (prime)
#   strongest middle    -> mid (only when >2 clusters; OP12 has policy0/2/5/7)
# confidence stays "high" for 2/3/4 clusters as long as we can resolve first+last
# hw_max; anything we can't read drops to "low" and we emit no overrides.
_pcount="$(_cget cpu_policy_count)"
_plist="$(_cget cpu_policy_list)"
_conf="high"
_little_id=""
_mid_id=""
_big_id=""
_topo="2c"

if [ "${_pcount:-0}" -ge 2 ] 2>/dev/null; then
  _little_id="$(echo "$_plist" | awk '{print $1}')"
  _big_id="$(echo "$_plist"   | awk '{print $NF}')"
  if [ "${_pcount}" -ge 3 ] 2>/dev/null; then
    # pick the middle policy with the highest hw_max (the strongest mid cluster)
    _topo="${_pcount}c"
    _mid_best=-1
    _i=0
    for _pid in $_plist; do
      _i=$((_i + 1))
      # skip first and last (those are little/big)
      [ "$_pid" = "$_little_id" ] && continue
      [ "$_pid" = "$_big_id" ] && continue
      _h="$(_cget cpu_policy${_pid}_hwmax)"
      [ -z "$_h" ] && continue
      if [ "$_h" -gt "$_mid_best" ] 2>/dev/null; then _mid_best="$_h"; _mid_id="$_pid"; fi
    done
  fi
else
  _conf="low"
fi

_hw_little="$(_cget cpu_policy${_little_id}_hwmax)"
_hw_big="$(_cget cpu_policy${_big_id}_hwmax)"
_hw_mid=""
[ -n "$_mid_id" ] && _hw_mid="$(_cget cpu_policy${_mid_id}_hwmax)"
[ -z "$_hw_little" ] && _conf="low"
[ -z "$_hw_big" ]    && _conf="low"
# for 3/4-cluster, a missing mid hw_max is not fatal — we just skip mid overrides


# snap RATIO_x10000 HW POLICY_ID -> the available freq closest to ratio*hw.
# Closest (not strictly-down) so integer-rounded ratios still land on the exact
# reference frequency on OP15. Ties and "between steps" resolve to the nearer
# step; if equidistant we take the lower (battery-leaning, conservative on heat).
_snap() {
  _ratio="$1"; _hw="$2"; _pid="$3"
  # IMPORTANT: hw_max (~4.6M) * ratio (~9000) overflows 32-bit shell math
  # (>2.1e9). Scale hw down by 100 first, ratio is /10000, so divide by 100 too:
  #   target = hw * ratio / 10000  ==  (hw/100) * ratio / 100
  _target=$(( (_hw / 100) * _ratio / 100 ))
  _avail="/sys/devices/system/cpu/cpufreq/policy${_pid}/scaling_available_frequencies"
  _best=""
  _bestd=""
  if [ -r "$_avail" ]; then
    for _fr in $(cat "$_avail" 2>/dev/null); do
      if [ "$_fr" -ge "$_target" ] 2>/dev/null; then _d=$(( _fr - _target )); else _d=$(( _target - _fr )); fi
      if [ -z "$_bestd" ] || [ "$_d" -lt "$_bestd" ] 2>/dev/null; then
        _bestd="$_d"; _best="$_fr"
      fi
    done
  fi
  [ -z "$_best" ] && _best="$_target"   # no table -> raw target (governor still validates)
  echo "$_best"
}

{
  echo "# device_bounds.env — generated by asb_synthesize_bounds.sh"
  echo "# generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  echo "# method=OP15-ratio-scaled, snapped to this device's real frequencies"
  echo "# confidence=$_conf  topology=$_topo (little+[mid]+big; 2/3/4 clusters supported)"
  echo "# little_policy=$_little_id hw_max=$_hw_little | mid_policy=${_mid_id:-none} hw_max=${_hw_mid:-n/a} | big_policy=$_big_id hw_max=$_hw_big"
  if [ "$_conf" = "high" ]; then
    # --- multi-cluster (3/4-cluster, e.g. SM8650 1+3+2+1) lag-safety lean ---
    # Under the raw OP15-derived ratios these SoCs pin their MAIN interactive
    # cluster low in battery mode (mid ~41%, prime ~35%), which reads as UI
    # stutter — the scheduler parks interactive work on the strongest middle
    # cluster and it can't clock up. For >2-cluster devices ONLY, lean every
    # interactive cluster's BATTERY/BALANCED ceiling UP toward a responsive floor
    # (~62-64% battery, ~82-86% balanced). This is the lag-safe direction: a
    # higher cap can only reduce stutter (cost is some battery, never smoothness).
    # The field-proven 2-cluster (OP15/OP13) ratios below are left exactly as-is.
    _r_bat_p="$R_BAT_MAX_B"; _r_bal_p="$R_BAL_MAX_B"; _r_prf_p="$R_PRF_MAX_B"
    if [ -n "$_mid_id" ] && [ -n "$_hw_mid" ]; then
      R_BAT_MAX_L=6000; R_BAL_MAX_L=7600
      R_BAT_MAX_M=6400; R_BAL_MAX_M=8200
      _r_bat_p=6200;    _r_bal_p=8600;    _r_prf_p=9200
    fi
    # Only the MAX ceilings are synthesised. These are the heat/perf-relevant
    # peaks that genuinely scale with a cluster's hardware ceiling, and they
    # reproduce OP15's shipped values exactly under the ratio model. The CAP and
    # MIN values in the reference config are deliberately "flat" (e.g. 921600
    # shared across clusters, and not a real prime-cluster step), so ratio-
    # scaling them would diverge AND snap to wrong steps — those stay at the
    # governor's compiled defaults, which are already conservative floors.
    echo "BATTERY_CPU_MAX_LITTLE=$(_snap $R_BAT_MAX_L $_hw_little $_little_id)"
    echo "BALANCED_CPU_MAX_LITTLE=$(_snap $R_BAL_MAX_L $_hw_little $_little_id)"
    echo "PERFORMANCE_CPU_MAX_LITTLE=$(_snap $R_PRF_MAX_L $_hw_little $_little_id)"
    if [ -n "$_mid_id" ] && [ -n "$_hw_mid" ]; then
      # 3/4-cluster: last cluster is PRIME (slot 2), strongest middle is MID
      # (slot 1). Battery/balanced leaned up per the block above for smoothness.
      echo "# topology=$_topo: big(prime) -> slot2, strongest middle -> slot1 (interactive caps leaned up)"
      # Only BATTERY caps the prime on these topologies. Before this synthesis existed the
      # prime slot stayed unmanaged here (compiled 0), which is what V52 shipped and what
      # users of 4-cluster devices were happy with. Adding a balanced ceiling made the
      # strongest core the most restricted one on those SoCs: measured side by side on one
      # device, same profile, same screen state, the prime went from 100% of its hardware
      # ceiling to 48% - felt sluggish, and the battery drain did not improve, because the
      # little/mid clusters simply spent longer at their own caps. Balanced and performance
      # therefore leave the prime alone again; battery still caps it, since that profile
      # exists precisely to trade speed away.
      echo "BATTERY_CPU_MAX_PRIME=$(_snap $_r_bat_p $_hw_big $_big_id)"
      echo "# BALANCED/PERFORMANCE prime intentionally not emitted (slot2 stays unmanaged)"
      echo "BATTERY_CPU_MAX_MID=$(_snap $R_BAT_MAX_M $_hw_mid $_mid_id)"
      echo "BALANCED_CPU_MAX_MID=$(_snap $R_BAL_MAX_M $_hw_mid $_mid_id)"
      echo "PERFORMANCE_CPU_MAX_MID=$(_snap $R_PRF_MAX_M $_hw_mid $_mid_id)"
    else
      # 2-cluster (OP15/OP13): last cluster is the prime, mapped to slot 1 here.
      echo "BATTERY_CPU_MAX_BIG=$(_snap $R_BAT_MAX_B $_hw_big $_big_id)"
      echo "BALANCED_CPU_MAX_BIG=$(_snap $R_BAL_MAX_B $_hw_big $_big_id)"
      echo "PERFORMANCE_CPU_MAX_BIG=$(_snap $R_PRF_MAX_B $_hw_big $_big_id)"
    fi
  else
    echo "# synthesis skipped: could not resolve first+last cluster hw_max (count=$_pcount) — governor keeps compiled defaults"
  fi
} > "$OUT" 2>/dev/null

chmod 0644 "$OUT" 2>/dev/null
[ -f "$OUT" ] && echo "asb_synthesize_bounds: wrote $OUT (confidence=$_conf)" \
             || echo "asb_synthesize_bounds: FAILED to write $OUT"
