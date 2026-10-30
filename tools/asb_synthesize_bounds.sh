#!/system/bin/sh
# =============================================================================
# asb_synthesize_bounds.sh — derive per-device CPU ranges from reference ratios
# ============================================================================= Reads
# /data/adb/asb/device_caps.env (written by asb_discover.sh) and produces
# /data/adb/asb/device_bounds.env — a flat KEY=value file the governor reads at startup (only
# when device_bounds_override=1) to scale its compiled reference bounds onto THIS device's hardware.
#
# Method ("ratios, not literal kHz"): reference = OP15 (canoe). MAX comes from this
# device's hardware ceiling; MIN and CAP preserve each profile's own MIN/MAX and CAP/MAX
# relationships. Every value snaps down to the policy's real OPP table when exposed.
#
# Safety / confidence: only the supported 2/3/4-policy mappings are synthesized. Any other
# topology, missing hardware ceiling or unresolved middle policy writes provenance with low
# confidence and no overrides (governor and shell then keep their compiled defaults).

CAPS="/data/adb/asb/device_caps.env"
OUT="/data/adb/asb/device_bounds.env"
ASB_DIR="/data/adb/asb"
mkdir -p "$ASB_DIR" 2>/dev/null

_cget() { grep -E "^$1=" "$CAPS" 2>/dev/null | head -1 | sed 's/^[^=]*=//'; }

# --- OP15 REFERENCE RATIOS (value / cluster hw_max), x10000 for integer math --- little hw_max
# ref = 3628800 ; big(prime) hw_max ref = 4608000 These mirror the shipped
# config/profile_bounds.conf exactly.
# ratio_x10000 = round( shipped_value * 10000 / op15_hw_max ) NOTE: one assignment per line — a
# second assignment after a '#' would be eaten by the comment (that bug cost us the entire
# big-cluster column once).
R_BAT_MAX_L=4603   # 1670400 / 3628800
R_BAT_MAX_B=3542   # 1632000 / 4608000
R_BAL_MAX_L=7196   # 2611200 / 3628800
R_BAL_MAX_B=8625   # 3974400 / 4608000
R_PRF_MAX_L=9500   # perf little, near hw max
R_PRF_MAX_B=9000   # perf big, near hw max
# Mid-band ratios for 3/4-cluster SoCs (e.g.
R_BAT_MAX_M=4072   # (4603+3542)/2  battery mid
R_BAL_MAX_M=7910   # (7196+8625)/2  balanced mid
R_PRF_MAX_M=9250   # (9500+9000)/2  performance mid

# ---- Topology mapping: exactly 2, 3, or 4 policies -> little / [mid] / big ----
# Match native discovery: order by measured hardware ceiling, not by policy directory number.
# The weakest policy is little, the strongest is big/prime, and the strongest remaining policy
# is mid. A 5+ policy file is intentionally rejected instead of being squeezed into three slots.
_pcount="$(_cget cpu_policy_count)"
_plist="$(_cget cpu_policy_list)"
_conf="high"
_little_id=""
_mid_id=""
_big_id=""
_hw_little=0
_hw_big=0
_hw_mid=0
_topo="unsupported"
_skip_reason="unsupported policy count"

case "${_pcount:-0}" in
  2|3|4)
    _topo="${_pcount}c"
    _seen=0
    for _pid in $_plist; do
      case "$_pid" in ''|*[!0-9]*) _conf="low"; continue ;; esac
      _h="$(_cget cpu_policy${_pid}_hwmax)"
      case "$_h" in ''|*[!0-9]*) _conf="low"; continue ;; esac
      [ "$_h" -gt 0 ] 2>/dev/null || { _conf="low"; continue; }
      _seen=$((_seen + 1))
      if [ -z "$_little_id" ] || [ "$_h" -lt "$_hw_little" ] || \
         { [ "$_h" -eq "$_hw_little" ] && [ "$_pid" -lt "$_little_id" ]; }; then
        _little_id="$_pid"; _hw_little="$_h"
      fi
      if [ -z "$_big_id" ] || [ "$_h" -gt "$_hw_big" ] || \
         { [ "$_h" -eq "$_hw_big" ] && [ "$_pid" -gt "$_big_id" ]; }; then
        _big_id="$_pid"; _hw_big="$_h"
      fi
    done
    [ "$_seen" -eq "$_pcount" ] 2>/dev/null || _conf="low"
    if [ "$_pcount" -ge 3 ]; then
      _mid_best=-1
      for _pid in $_plist; do
        [ "$_pid" = "$_little_id" ] && continue
        [ "$_pid" = "$_big_id" ] && continue
        _h="$(_cget cpu_policy${_pid}_hwmax)"
        case "$_h" in ''|*[!0-9]*) continue ;; esac
        if [ "$_h" -gt "$_mid_best" ] 2>/dev/null; then _mid_best="$_h"; _mid_id="$_pid"; _hw_mid="$_h"; fi
      done
      [ -n "$_mid_id" ] && [ "$_hw_mid" -gt 0 ] 2>/dev/null || _conf="low"
    fi
    [ "$_conf" = "high" ] || _skip_reason="unresolved policy ids or hardware ceilings"
    ;;
  *) _conf="low" ;;
esac

# Canonical physical topology (fix260). The representative signature above is useful for
# diagnostics, but it cannot prove the identity of the fourth policy on a 4-policy SoC.
# policy_map is the single full record shared by synthesis, shell validation and native
# validation: sorted policy id, logical writer slot, hardware ceiling and exposed OPP shape.
_policy_map=""
_full_sig=""
_extra_id=""
_sorted_ids="$(for _pid in $_plist; do case "$_pid" in ''|*[!0-9]*) ;; *) echo "$_pid" ;; esac; done | sort -n)"
for _pid in $_sorted_ids; do
  _h="$(_cget cpu_policy${_pid}_hwmax)"
  case "$_h" in ''|*[!0-9]*) _h=0 ;; esac
  if [ "$_pid" = "$_little_id" ]; then
    _slot=0
  elif [ "$_pid" = "$_big_id" ]; then
    if [ "${_pcount:-0}" -gt 2 ] 2>/dev/null; then _slot=2; else _slot=1; fi
  else
    _slot=1
    [ "$_pid" = "$_mid_id" ] || _extra_id="${_extra_id}${_extra_id:+,}${_pid}"
  fi
  _on="$(_cget cpu_policy${_pid}_opp_count)"
  _omin="$(_cget cpu_policy${_pid}_opp_min)"
  _omax="$(_cget cpu_policy${_pid}_opp_max)"
  case "$_on" in ''|*[!0-9]*) _on=0 ;; esac
  case "$_omin" in ''|*[!0-9]*) _omin=0 ;; esac
  case "$_omax" in ''|*[!0-9]*) _omax=0 ;; esac
  _policy_map="${_policy_map}${_policy_map:+,}${_pid}:${_slot}:${_h}:${_on}:${_omin}:${_omax}"
  _full_sig="${_full_sig}${_full_sig:+,}${_pid}:${_h}"
done

# Snap a ceiling DOWN to this policy's own OPP table. Rounding to the nearest entry
# could exceed the profile's intended ceiling and the native writer would then round it
# down again, leaving shell and native policy on different rails. If every OPP is above
# the target, the lowest real OPP is the only valid non-zero choice.
CPUFREQ_ROOT="${ASB_CPUFREQ_ROOT:-/sys/devices/system/cpu/cpufreq}"
_snap_target() {
  _target="$1"; _pid="$2"
  _avail="$CPUFREQ_ROOT/policy${_pid}/scaling_available_frequencies"
  _best=0; _lowest=0
  if [ -r "$_avail" ]; then
    for _fr in $(cat "$_avail" 2>/dev/null); do
      case "$_fr" in ''|*[!0-9]*) continue ;; esac
      [ "$_fr" -gt 0 ] 2>/dev/null || continue
      if [ "$_lowest" -eq 0 ] || [ "$_fr" -lt "$_lowest" ]; then _lowest="$_fr"; fi
      if [ "$_fr" -le "$_target" ] && [ "$_fr" -gt "$_best" ]; then _best="$_fr"; fi
    done
  fi
  if [ "$_best" -gt 0 ]; then echo "$_best"
  elif [ "$_lowest" -gt 0 ]; then echo "$_lowest"
  else echo "$_target"; fi  # no table -> raw target; native writer still validates/clamps
}

# snap RATIO_x10000 HW POLICY_ID -> ratio*hw, snapped down to a real OPP.
_snap() {
  _ratio="$1"; _hw="$2"; _pid="$3"
  # IMPORTANT: hw_max (~4.6M) * ratio (~9000) overflows 32-bit shell math
  # (>2.1e9). Scale hw down by 100 first, ratio is /10000, so divide by 100 too:
  #   target = hw * ratio / 10000  ==  (hw/100) * ratio / 100
  _target=$(( (_hw / 100) * _ratio / 100 ))
  _snap_target "$_target" "$_pid"
}

# Derive MIN and CAP from the already-snapped MAX. The ratios are the shipped
# profile's own MIN/MAX and CAP/MAX relationships, so every device keeps the profile's
# shape without inheriting literal reference-device kHz.
_snap_part() {
  _base="$1"; _ratio="$2"; _pid="$3"
  _target=$(( (_base / 100) * _ratio / 100 ))
  _snap_target "$_target" "$_pid"
}

# PROFILE SLOT MAX_RATIO MIN_OF_MAX CAP_OF_MAX HW POLICY_ID
_emit_cpu_range() {
  _erp="$1"; _ers="$2"; _ermax="$3"; _ermin="$4"; _ercap="$5"; _erhw="$6"; _erpid="$7"
  _er_max="$(_snap "$_ermax" "$_erhw" "$_erpid")"
  _er_cap="$(_snap_part "$_er_max" "$_ercap" "$_erpid")"
  _er_min="$(_snap_part "$_er_max" "$_ermin" "$_erpid")"
  echo "${_erp}_CPU_MIN_${_ers}=$_er_min"
  echo "${_erp}_CPU_CAP_${_ers}=$_er_cap"
  echo "${_erp}_CPU_MAX_${_ers}=$_er_max"
}

{
  echo "# device_bounds.env — generated by asb_synthesize_bounds.sh"
  echo "# generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  echo "# method=reference-ratio full MIN/CAP/MAX ranges, snapped down to this device's real frequencies"
  echo "# confidence=$_conf  topology=$_topo (little+[mid]+big; 2/3/4 clusters supported)"
  echo "schema=3"
  echo "confidence=$_conf"
  echo "source=measured"
  echo "policy_count=${_pcount:-0}"
  echo "cluster_signature=${_little_id:-none}:${_hw_little:-0}>${_mid_id:-none}:${_hw_mid:-0}>${_big_id:-none}:${_hw_big:-0}"
  echo "cluster_signature_full=$_full_sig"
  echo "logical_roles=little:${_little_id:-none},mid:${_mid_id:-none},big:${_big_id:-none},extra:${_extra_id:-none}"
  echo "policy_map=$_policy_map"
  echo "fingerprint=$(_cget fingerprint)"
  echo "# little_policy=$_little_id hw_max=$_hw_little | mid_policy=${_mid_id:-none} hw_max=${_hw_mid:-n/a} | big_policy=$_big_id hw_max=$_hw_big"
  if [ "$_conf" = "high" ]; then
    # --- multi-cluster (3/4-cluster, e.g.
    # This is the lag-safe direction: a higher cap can only reduce stutter (cost is some
    # battery, never smoothness).
    _r_bat_p="$R_BAT_MAX_B"; _r_bal_p="$R_BAL_MAX_B"; _r_prf_p="$R_PRF_MAX_B"
    if [ -n "$_mid_id" ] && [ -n "$_hw_mid" ]; then
      R_BAT_MAX_L=6000; R_BAL_MAX_L=7600
      R_BAT_MAX_M=6400; R_BAL_MAX_M=8200
      _r_bat_p=6200;    _r_bal_p=8600;    _r_prf_p=9200
    fi
    # Full MIN/CAP/MAX ranges, not only MAX. Absolute reference MIN/CAP values could
    # exceed a smaller SoC's scaled ceiling or hold its floor needlessly high. The two
    # ratio columns are MIN/MAX and CAP/MAX from config/profile_bounds.conf. On 3/4-
    # cluster topologies MID uses the BIG profile shape; PRIME remains deliberately
    # unmanaged except for Battery's existing ceiling.
    _emit_cpu_range BATTERY LITTLE "$R_BAT_MAX_L" 1839 5517 "$_hw_little" "$_little_id"
    _emit_cpu_range BALANCED LITTLE "$R_BAL_MAX_L" 3014 4559 "$_hw_little" "$_little_id"
    _emit_cpu_range PERFORMANCE LITTLE "$R_PRF_MAX_L" 3196 6443 "$_hw_little" "$_little_id"
    if [ -n "$_mid_id" ] && [ -n "$_hw_mid" ]; then
      # 3/4-cluster: last cluster is PRIME (slot 2), strongest middle is MID
      # (slot 1). Battery/balanced leaned up per the block above for smoothness.
      echo "# topology=$_topo: big(prime) -> slot2, strongest middle -> slot1 (interactive caps leaned up)"
      # Only BATTERY caps the prime on these topologies.
      # Adding a balanced ceiling made the strongest core the most restricted one on those
      # SoCs: measured side by side on one device, same profile, same screen state, the prime
      # went from 100% of its hardware ceiling to 48% - felt sluggish, and the battery drain
      # did not improve, because the little/mid clusters simply spent longer at their own caps.
      echo "BATTERY_CPU_MAX_PRIME=$(_snap $_r_bat_p $_hw_big $_big_id)"
      echo "# BALANCED/PERFORMANCE prime intentionally not emitted (slot2 stays unmanaged)"
      _emit_cpu_range BATTERY MID "$R_BAT_MAX_M" 3765 5647 "$_hw_mid" "$_mid_id"
      _emit_cpu_range BALANCED MID "$R_BAL_MAX_M" 2222 4735 "$_hw_mid" "$_mid_id"
      _emit_cpu_range PERFORMANCE MID "$R_PRF_MAX_M" 1959 5839 "$_hw_mid" "$_mid_id"
    else
      # 2-cluster (OP15/OP13): last cluster is the prime, mapped to slot 1 here.
      _emit_cpu_range BATTERY BIG "$R_BAT_MAX_B" 3765 5647 "$_hw_big" "$_big_id"
      _emit_cpu_range BALANCED BIG "$R_BAL_MAX_B" 2222 4735 "$_hw_big" "$_big_id"
      _emit_cpu_range PERFORMANCE BIG "$R_PRF_MAX_B" 1959 5839 "$_hw_big" "$_big_id"
    fi
  else
    echo "# synthesis skipped: $_skip_reason (count=${_pcount:-0}) — governor keeps compiled defaults"
  fi
} > "$OUT.tmp" 2>/dev/null
# Write-then-rename, so the governor can never read a half-written file. The old form
# truncated device_bounds.env first and filled it after; a process killed in between (an
# interrupted boot) left a partial file that the loader applies key by key.
[ -s "$OUT.tmp" ] && mv -f "$OUT.tmp" "$OUT" 2>/dev/null
rm -f "$OUT.tmp" 2>/dev/null

chmod 0644 "$OUT" 2>/dev/null
[ -f "$OUT" ] && echo "asb_synthesize_bounds: wrote $OUT (confidence=$_conf)" \
             || echo "asb_synthesize_bounds: FAILED to write $OUT"
