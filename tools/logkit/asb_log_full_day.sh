#!/system/bin/sh
#

set -u
LK_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
. "$LK_SCRIPT_DIR/_asb_logkit_common.sh"

# Auto-detach so the day-long capture survives Termux closure / phone sleep.
if [ -t 0 ]; then
  if command -v setsid >/dev/null 2>&1; then
    if [ -z "${ASB_LOGKIT_DETACHED:-}" ]; then
      export ASB_LOGKIT_DETACHED=1
      echo "[autodetach] Re-launching detached for full-day capture"
      exec setsid sh "$0" "$@" </dev/null
    fi
  fi
fi

LK_SCENARIO="full_day"
LK_OUT_DIR="$(lk_resolve_outbase)/asb_log_${LK_SCENARIO}_$$"
LK_HOURS="${1:-24}"
LK_MAX_SEC=$(( LK_HOURS * 3600 ))
LK_SNAPSHOT_S=3600          # full state snapshot + interim report every hour

# Phase-adaptive poll cadence (seconds)
LK_POLL_FAST=15             # gaming / charging — catch transients
LK_POLL_NORMAL=45           # active / post-wake
LK_POLL_SLOW=90             # sleep / idle — don't cost battery
LK_POLL_S=$LK_POLL_NORMAL

# Wakelock attribution snapshot cadence (kernel sources are cheap; app-side
# batterystats is heavier, so only at phase boundaries + hourly).
LK_WAKE_SNAP_S=900

LK_WAKELOCK_NAME="asb_logkit_$$"
LK_HAVE_WAKELOCK=0
lk_wl_acquire() {
  [ -w /sys/power/wake_lock ] || return 0
  echo "$LK_WAKELOCK_NAME" > /sys/power/wake_lock 2>/dev/null && LK_HAVE_WAKELOCK=1
}
lk_wl_release() {
  [ "$LK_HAVE_WAKELOCK" = "1" ] || return 0
  echo "$LK_WAKELOCK_NAME" > /sys/power/wake_unlock 2>/dev/null && LK_HAVE_WAKELOCK=0
}

# ── phase detection ────────────────────────────────────────────────────────
LK_SCREEN_OFF_SINCE=0
LK_LAST_SCREEN="unknown"
LK_WOKE_AT=0

lk_detect_phase() {
  _now="$1"
  # charging?
  _cs=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
  # screen state via power manager (cheap, no toybox dep beyond grep/sed)
  _scr=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | sed 's/.*mWakefulness=//;s/ .*//')
  [ -z "$_scr" ] && _scr="$LK_LAST_SCREEN"
  # screen-off duration tracking
  if [ "$_scr" = "Asleep" ] || [ "$_scr" = "Dozing" ]; then
    [ "$LK_SCREEN_OFF_SINCE" = "0" ] && LK_SCREEN_OFF_SINCE="$_now"
  else
    if [ "$LK_LAST_SCREEN" = "Asleep" ] || [ "$LK_LAST_SCREEN" = "Dozing" ]; then
      LK_WOKE_AT="$_now"            # just woke
    fi
    LK_SCREEN_OFF_SINCE=0
  fi
  LK_LAST_SCREEN="$_scr"
  _off_for=0
  [ "$LK_SCREEN_OFF_SINCE" != "0" ] && _off_for=$(( _now - LK_SCREEN_OFF_SINCE ))

  # GPU busy + top-app cpu for gaming detection
  _gb=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -dc '0-9')
  [ -z "$_gb" ] && _gb=0
  read -r _l1 _rest < /proc/loadavg
  _l1i=$(echo "$_l1" | tr -dc '0-9')      # e.g. 3.42 -> 342, compared *100

  # charging branches
  case "$_cs" in
    Charging|Full)
      if [ "$_scr" = "Awake" ]; then echo "charging_active"; else echo "charging_idle"; fi
      return ;;
  esac
  # screen off → sleep vs idle (sleep = off > 20 min)
  if [ "$_scr" = "Asleep" ] || [ "$_scr" = "Dozing" ]; then
    if [ "$_off_for" -ge 1200 ]; then echo "sleep"; else echo "idle"; fi
    return
  fi
  # screen on: gaming if GPU sustained high
  if [ "$_gb" -ge 60 ]; then echo "gaming"; return; fi
  # within 5 min of waking → post_wake (ASB ramp window of interest)
  if [ "$LK_WOKE_AT" != "0" ] && [ $(( _now - LK_WOKE_AT )) -le 300 ]; then
    echo "post_wake"; return
  fi
  echo "active"
}

# Poll cadence per phase
lk_poll_for_phase() {
  case "$1" in
    gaming|charging_active|charging_idle) echo "$LK_POLL_FAST" ;;
    sleep|idle)                           echo "$LK_POLL_SLOW" ;;
    *)                                    echo "$LK_POLL_NORMAL" ;;
  esac
}

# ── throttle detection ─────────────────────────────────────────────────────
LK_P0_HWMAX=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq 2>/dev/null)
LK_P6_HWMAX=$(cat /sys/devices/system/cpu/cpufreq/policy6/cpuinfo_max_freq 2>/dev/null)
lk_throttle_row() {
  _ph="$1"; _e=$(date +%s)
  _p0=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)
  _p6=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null)
  _capped=0
  [ -n "$_p0" ] && [ -n "$LK_P0_HWMAX" ] && [ "$_p0" -lt "$LK_P0_HWMAX" ] 2>/dev/null && _capped=1
  [ -n "$_p6" ] && [ -n "$LK_P6_HWMAX" ] && [ "$_p6" -lt "$LK_P6_HWMAX" ] 2>/dev/null && _capped=1
  [ "$_capped" = "0" ] && return 0
  _j=$(lk_status_json)
  _temp=$(echo "$_j" | awk -F'"temp":' '{print $2}' | awk -F, '{print $1}')
  _surf=$(echo "$_j" | awk -F'"surface_hotspot":' '{print $2}' | awk -F, '{print $1}')
  _own=$(echo "$_j"  | awk -F'"cap_owner":"' '{print $2}' | awk -F'"' '{print $1}')
  echo "${_e}|${_ph}|p0_max=${_p0}/${LK_P0_HWMAX}|p6_max=${_p6}/${LK_P6_HWMAX}|cpu_temp=${_temp}|surface=${_surf}|cap_owner=${_own}" >> "$LK_OUT_DIR/throttle_trace.txt"
}

# ── per-phase accounting ───────────────────────────────────────────────────
LK_CUR_PHASE=""
LK_PH_START=0
LK_PH_START_PCT=0
LK_PH_MAXCPU=0
LK_PH_MAXSURF=0
LK_PH_MAXP6=0
LK_PH_GPUSUM=0
LK_PH_GPUCNT=0
LK_PH_THROTTLE=0
LK_PH_WAKEPEAK=0

lk_phase_ledger_flush() {
  _endpct=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  _end=$(date +%s)
  [ -z "$LK_CUR_PHASE" ] && return 0
  _gavg=0; [ "$LK_PH_GPUCNT" -gt 0 ] && _gavg=$(( LK_PH_GPUSUM / LK_PH_GPUCNT ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LK_CUR_PHASE" "$LK_PH_START" "$_end" "$LK_PH_START_PCT" "$_endpct" \
    "$LK_PH_MAXCPU" "$LK_PH_MAXSURF" "$LK_PH_MAXP6" "$_gavg" \
    "$LK_PH_THROTTLE" "$LK_PH_WAKEPEAK" >> "$LK_OUT_DIR/phase_ledger.tsv"
}

lk_phase_ledger_open() {
  LK_CUR_PHASE="$1"
  LK_PH_START=$(date +%s)
  LK_PH_START_PCT=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  LK_PH_MAXCPU=0; LK_PH_MAXSURF=0; LK_PH_MAXP6=0
  LK_PH_GPUSUM=0; LK_PH_GPUCNT=0; LK_PH_THROTTLE=0; LK_PH_WAKEPEAK=0
}

lk_phase_ledger_accumulate() {
  _j=$(lk_status_json)
  _temp=$(echo "$_j" | awk -F'"temp":' '{print $2}' | awk -F, '{print $1}' | tr -dc '0-9')
  _surf=$(echo "$_j" | awk -F'"surface_hotspot":' '{print $2}' | awk -F, '{print $1}' | tr -dc '0-9')
  _p6=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq 2>/dev/null)
  _gb=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -dc '0-9')
  [ -n "$_temp" ] && [ "$_temp" -gt "$LK_PH_MAXCPU" ] 2>/dev/null && LK_PH_MAXCPU=$_temp
  [ -n "$_surf" ] && [ "$_surf" -gt "$LK_PH_MAXSURF" ] 2>/dev/null && LK_PH_MAXSURF=$_surf
  [ -n "$_p6" ] && [ "$_p6" -gt "$LK_PH_MAXP6" ] 2>/dev/null && LK_PH_MAXP6=$_p6
  if [ -n "$_gb" ]; then LK_PH_GPUSUM=$(( LK_PH_GPUSUM + _gb )); LK_PH_GPUCNT=$(( LK_PH_GPUCNT + 1 )); fi
  # wake active peak
  _ksrc=/sys/kernel/debug/wakeup_sources
  [ -r "$_ksrc" ] || _ksrc=/d/wakeup_sources
  if [ -r "$_ksrc" ]; then
    _ka=$(awk -v self="$LK_WAKELOCK_NAME" 'NR>1 && $1!=self && $2>0 {n++} END{print n+0}' "$_ksrc" 2>/dev/null)
    [ -n "$_ka" ] && [ "$_ka" -gt "$LK_PH_WAKEPEAK" ] 2>/dev/null && LK_PH_WAKEPEAK=$_ka
  fi
}

# ── reporting ──────────────────────────────────────────────────────────────
lk_emit_phase_summary() {
  _led="$LK_OUT_DIR/phase_ledger.tsv"
  [ -r "$_led" ] || return 0
  {
    echo "===== PER-PHASE SUMMARY ====="
    echo ""
    printf "%-15s %8s %7s %8s %8s %8s %9s %7s %9s\n" \
      "phase" "dur_min" "d_pct" "pct/h" "cpuT" "surfT" "p6MHz" "gpu%" "throttle"
    awk -F'\t' '
      /^#/{next}
      {
        ph=$1; dur=($3-$2); dpct=($4-$5);
        D[ph]+=dur; DP[ph]+=dpct; N[ph]++;
        if($6>CT[ph])CT[ph]=$6; if($7>SF[ph])SF[ph]=$7;
        if($8>P6[ph])P6[ph]=$8; G[ph]+=$9; TH[ph]+=$10;
      }
      END{
        for(p in D){
          durm=D[p]/60.0;
          rate=(D[p]>0)?(DP[p]*3600.0/D[p]):0;
          gavg=(N[p]>0)?(G[p]/N[p]):0;
          printf "%-15s %8.1f %7d %8.2f %8d %8d %9d %7d %9d\n", \
            p, durm, DP[p], rate, CT[p], SF[p], (P6[p]/1000), gavg, TH[p];
        }
      }
    ' "$_led" | sort -k4 -rn
    echo ""
    echo "Legend: d_pct=battery % consumed (negative=gained while charging),"
    echo "        pct/h=drain rate, cpuT/surfT=peak temps (°C), p6MHz=peak prime"
    echo "        clock, gpu%=avg GPU busy, throttle=ticks the prime was capped."
  } > "$LK_OUT_DIR/phase_summary.txt"
}

lk_emit_full_day_report() {
  _led="$LK_OUT_DIR/phase_ledger.tsv"
  _out="$LK_OUT_DIR/_full_day_report.txt"
  {
    echo "==================================================================="
    echo " ASB FULL-DAY REPORT — $(date '+%Y-%m-%d %H:%M:%S')"
    echo " capture: ${LK_HOURS}h target, $(( ($(date +%s) - LK_START_EPOCH) / 60 )) min elapsed"
    echo "==================================================================="
    echo ""
    if [ -r "$LK_OUT_DIR/phase_summary.txt" ]; then
      cat "$LK_OUT_DIR/phase_summary.txt"
    fi
    echo ""
    echo "----- THROTTLE HOTSPOTS (prime capped below hardware max) -----"
    if [ -s "$LK_OUT_DIR/throttle_trace.txt" ]; then
      _tc=$(wc -l < "$LK_OUT_DIR/throttle_trace.txt")
      echo "throttle events logged: $_tc"
      echo "by phase:"
      awk -F'|' '{split($2,a,"="); print $2}' "$LK_OUT_DIR/throttle_trace.txt" \
        | sort | uniq -c | sort -rn | head
      echo "by cap owner:"
      awk -F'cap_owner=' 'NF>1{print $2}' "$LK_OUT_DIR/throttle_trace.txt" \
        | sort | uniq -c | sort -rn | head
      echo "sample (first + worst-temp few):"
      head -3 "$LK_OUT_DIR/throttle_trace.txt"
    else
      echo "none — prime never capped below hardware max during capture."
      echo "(if you gamed hard and still see none, ASB+thermal kept full clocks)"
    fi
    echo ""
    echo "----- WAKE SOURCES (who kept the device awake) -----"
    if [ -s "$LK_OUT_DIR/wake_sources.txt" ]; then
      echo "see wake_sources.txt for full detail. DELTA (active time gained"
      echo "during capture) is the actionable part — top offenders:"
      awk '/DELTA over capture/{f=1;next} /^=====/{f=0} f&&NF>=3 && $1!~/^#/{print}' \
        "$LK_OUT_DIR/wake_sources.txt" | head -12
    else
      echo "wakeup_sources not readable on this device (no debugfs access)."
    fi
    echo ""
    echo "----- READING THIS -----"
    echo "* Compare pct/h across phases. 'sleep' and 'idle' should be the"
    echo "  lowest; if 'idle' ≈ 'active' something is keeping the SoC busy —"
    echo "  cross-check wake_sources.txt for that window."
    echo "* In 'gaming', look at p6MHz vs hardware max and the throttle count:"
    echo "  if throttle is high and surfT is moderate, the cap is vendor/ASB,"
    echo "  not heat — there may be headroom to let clocks run higher."
    echo "* If a kernel wake source dominates the DELTA and isn't essential,"
    echo "  that's a concrete ASB target (prop/standby tuning)."
    echo ""
    echo "Send the whole output folder back for a targeted ASB tuning pass."
  } > "$_out"
}

# ── run ────────────────────────────────────────────────────────────────────
lk_init

# trace headers
lk_perf_trace_header
lk_battery_trace_header
{ echo "# phase timeline — epoch | iso | phase | trigger"; } > "$LK_OUT_DIR/phase_timeline.txt"
{ echo "# throttle trace — epoch | phase | p0 | p6 | temps | cap_owner"; } > "$LK_OUT_DIR/throttle_trace.txt"
printf '# phase\tstart\tend\tstart_pct\tend_pct\tmaxCpuT\tmaxSurfT\tmaxP6\tgpuAvg\tthrottle\twakePeak\n' > "$LK_OUT_DIR/phase_ledger.tsv"

# wakelock baseline + reset
lk_wakelock_kernel_baseline
lk_wakelock_kernel_snapshot "start"
lk_wakelock_batterystats_reset
lk_oem_ram_expand_probe "start"
lk_oem_toggle_row

echo "[$(date '+%H:%M:%S')] FULL-DAY capture running up to ${LK_HOURS}h. Use the phone normally."

_last_snapshot=$(date +%s)
_last_wakesnap=$(date +%s)
_phase="$(lk_detect_phase "$(date +%s)")"
lk_phase_ledger_open "$_phase"
echo "$(date +%s)|$(date '+%Y-%m-%d %H:%M:%S')|$_phase|capture_start" >> "$LK_OUT_DIR/phase_timeline.txt"

while : ; do
  _now=$(date +%s)
  _elapsed=$(( _now - LK_START_EPOCH ))
  [ "$_elapsed" -ge "$LK_MAX_SEC" ] && break

  lk_wl_acquire

  # detect phase; on change, flush the ledger and re-open
  _new_phase="$(lk_detect_phase "$_now")"
  if [ "$_new_phase" != "$_phase" ]; then
    lk_phase_ledger_accumulate
    lk_phase_ledger_flush
    echo "${_now}|$(date '+%Y-%m-%d %H:%M:%S')|${_new_phase}|from:${_phase}" >> "$LK_OUT_DIR/phase_timeline.txt"
    # at every phase boundary, grab a wake snapshot (cheap kernel side)
    lk_wakelock_kernel_snapshot "phase:${_new_phase}"
    lk_phase_ledger_open "$_new_phase"
    _phase="$_new_phase"
    LK_POLL_S="$(lk_poll_for_phase "$_phase")"
  fi

  # per-poll capture
  lk_capture_perf_trace_row
  lk_capture_battery_trace_row
  lk_wakelock_live_row
  lk_oem_toggle_row
  lk_throttle_row "$_phase"
  lk_phase_ledger_accumulate
  LK_TICK_COUNT=$((LK_TICK_COUNT + 1))

  # periodic heavier wake snapshot
  if [ $(( _now - _last_wakesnap )) -ge "$LK_WAKE_SNAP_S" ]; then
    lk_wakelock_kernel_snapshot "periodic"
    _last_wakesnap=$_now
  fi

  # hourly: full state snapshot + interim reports
  if [ $(( _now - _last_snapshot )) -ge "$LK_SNAPSHOT_S" ]; then
    lk_snapshot_state "snapshot_${_now}"
    lk_verify_caps
    lk_emit_phase_summary 2>/dev/null || true
    lk_emit_full_day_report 2>/dev/null || true
    _last_snapshot=$_now
  fi

  lk_wl_release
  sleep "$LK_POLL_S"
done

# finalize
lk_phase_ledger_accumulate
lk_phase_ledger_flush
lk_wakelock_kernel_snapshot "end"
lk_wakelock_kernel_delta
lk_wakelock_batterystats_dump
lk_oem_ram_expand_probe "end"
lk_emit_phase_summary
lk_emit_full_day_report
lk_snapshot_state "after"
lk_wl_release
lk_finalize
echo "[$(date '+%H:%M:%S')] FULL-DAY capture complete. Output: $LK_OUT_DIR"
