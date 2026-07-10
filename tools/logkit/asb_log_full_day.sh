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
LK_BSTATS_WINDOW_MIN=$(( LK_SNAPSHOT_S / 60 ))
export LK_BSTATS_WINDOW_MIN

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
LK_PHASE_OUT=""
LK_GPU_HI=60
LK_GPU_LO=35
LK_GPU_ENTER=2
LK_GPU_EXIT=3
LK_GPU_HI_STREAK=0
LK_GPU_LO_STREAK=0
LK_IN_GAMING=0
LK_GPU_NOW=0

lk_sample_gpu_busy() {
  LK_GPU_NOW=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -dc '0-9')
  [ -z "$LK_GPU_NOW" ] && LK_GPU_NOW=0
  export LK_GPU_NOW
}

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
  _gb="$LK_GPU_NOW"
  [ -z "$_gb" ] && _gb=0
  read -r _l1 _rest < /proc/loadavg
  _l1i=$(echo "$_l1" | tr -dc '0-9')      # e.g. 3.42 -> 342, compared *100

  # charging branches
  case "$_cs" in
    Charging|Full)
      LK_IN_GAMING=0; LK_GPU_HI_STREAK=0; LK_GPU_LO_STREAK=0
      if [ "$_scr" = "Awake" ]; then LK_PHASE_OUT="charging_active"; else LK_PHASE_OUT="charging_idle"; fi
      return 0 ;;
  esac
  # screen off → sleep vs idle (sleep = off > 20 min)
  if [ "$_scr" = "Asleep" ] || [ "$_scr" = "Dozing" ]; then
    LK_IN_GAMING=0; LK_GPU_HI_STREAK=0; LK_GPU_LO_STREAK=0
    if [ "$_off_for" -ge 1200 ]; then LK_PHASE_OUT="sleep"; else LK_PHASE_OUT="idle"; fi
    return 0
  fi
  # screen on: gaming if GPU sustained high (hysteresis, not a single sample)
  if [ "$_gb" -ge "$LK_GPU_HI" ]; then
    LK_GPU_HI_STREAK=$(( LK_GPU_HI_STREAK + 1 )); LK_GPU_LO_STREAK=0
  elif [ "$_gb" -lt "$LK_GPU_LO" ]; then
    LK_GPU_LO_STREAK=$(( LK_GPU_LO_STREAK + 1 )); LK_GPU_HI_STREAK=0
  else
    LK_GPU_HI_STREAK=0; LK_GPU_LO_STREAK=0
  fi
  if [ "$LK_IN_GAMING" = "1" ]; then
    [ "$LK_GPU_LO_STREAK" -ge "$LK_GPU_EXIT" ] && LK_IN_GAMING=0
  else
    [ "$LK_GPU_HI_STREAK" -ge "$LK_GPU_ENTER" ] && LK_IN_GAMING=1
  fi
  if [ "$LK_IN_GAMING" = "1" ]; then LK_PHASE_OUT="gaming"; return 0; fi
  # within 5 min of waking → post_wake (ASB ramp window of interest)
  if [ "$LK_WOKE_AT" != "0" ] && [ $(( _now - LK_WOKE_AT )) -le 300 ]; then
    LK_PHASE_OUT="post_wake"; return 0
  fi
  LK_PHASE_OUT="active"
  return 0
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
LK_PH_START_UP=0

lk_uptime_s() {
  awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0
}

lk_mono_s() {
  _m=$(awk '/now at/{printf "%d", $3/1000000000; exit}' /proc/timer_list 2>/dev/null)
  [ -n "$_m" ] && echo "$_m" || echo -1
}

lk_phase_ledger_row() {
  [ -z "$LK_CUR_PHASE" ] && return 1
  _endpct=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  _end=$(date +%s)
  _upend=$(lk_uptime_s)
  _monoend=$(lk_mono_s)
  _gavg=0; [ "$LK_PH_GPUCNT" -gt 0 ] && _gavg=$(( LK_PH_GPUSUM / LK_PH_GPUCNT ))
  _elapsed=$(( _upend - LK_PH_START_UP ))
  _awake=-1
  if [ "$_elapsed" -gt 0 ] && [ "$LK_PH_START_MONO" -ge 0 ] 2>/dev/null && [ "$_monoend" -ge 0 ] 2>/dev/null; then
    _mono=$(( _monoend - LK_PH_START_MONO ))
    [ "$_mono" -lt 0 ] && _mono=0
    _awake=$(( _mono * 100 / _elapsed ))
    [ "$_awake" -gt 100 ] && _awake=100
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LK_CUR_PHASE" "$LK_PH_START" "$_end" "$LK_PH_START_PCT" "$_endpct" \
    "$LK_PH_MAXCPU" "$LK_PH_MAXSURF" "$LK_PH_MAXP6" "$_gavg" \
    "$LK_PH_THROTTLE" "$LK_PH_WAKEPEAK" "$_awake"
  return 0
}

lk_phase_ledger_flush() {
  lk_phase_ledger_row >> "$LK_OUT_DIR/phase_ledger.tsv" 2>/dev/null || return 0
}

lk_phase_ledger_snapshot_open() {
  : > "$LK_OUT_DIR/.phase_open.tsv"
  lk_phase_ledger_row >> "$LK_OUT_DIR/.phase_open.tsv" 2>/dev/null || true
}

lk_phase_ledger_open() {
  LK_CUR_PHASE="$1"
  LK_PH_START=$(date +%s)
  LK_PH_START_UP=$(lk_uptime_s)
  LK_PH_START_MONO=$(lk_mono_s)
  LK_PH_START_PCT=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  LK_PH_MAXCPU=0; LK_PH_MAXSURF=0; LK_PH_MAXP6=0
  LK_PH_GPUSUM=0; LK_PH_GPUCNT=0; LK_PH_THROTTLE=0; LK_PH_WAKEPEAK=0
}

lk_phase_ledger_accumulate() {
  _j=$(lk_status_json)
  _temp=$(echo "$_j" | awk -F'"temp":' '{print $2}' | awk -F, '{print $1}' | tr -dc '0-9')
  _surf=$(echo "$_j" | awk -F'"surface_hotspot":' '{print $2}' | awk -F, '{print $1}' | tr -dc '0-9')
  _p6=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq 2>/dev/null)
  _gb="$LK_GPU_NOW"
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
  lk_phase_ledger_snapshot_open
  _all="$LK_OUT_DIR/.phase_all.tsv"
  cat "$_led" > "$_all" 2>/dev/null
  [ -s "$LK_OUT_DIR/.phase_open.tsv" ] && cat "$LK_OUT_DIR/.phase_open.tsv" >> "$_all"
  {
    echo "===== PER-PHASE SUMMARY ====="
    echo ""
    printf "%-15s %8s %7s %8s %8s %8s %9s %7s %9s %8s\n" \
      "phase" "dur_min" "d_pct" "pct/h" "cpuT" "surfT" "p6MHz" "gpu%" "throttle" "awake%"
    awk -F'\t' '
      /^#/{next}
      {
        ph=$1; dur=($3-$2); dpct=($4-$5);
        D[ph]+=dur; DP[ph]+=dpct; N[ph]++;
        if($6>CT[ph])CT[ph]=$6; if($7>SF[ph])SF[ph]=$7;
        if($8>P6[ph])P6[ph]=$8; G[ph]+=$9; TH[ph]+=$10;
        if($12>=0){ AW[ph]+=$12*dur; AWD[ph]+=dur }
      }
      END{
        for(p in D){
          durm=D[p]/60.0;
          rate=(D[p]>0)?(DP[p]*3600.0/D[p]):0;
          gavg=(N[p]>0)?(G[p]/N[p]):0;
          aw=(AWD[p]>0)?(AW[p]/AWD[p]):-1;
          aws=(aw>=0)?sprintf("%.1f",aw):"-";
          printf "%-15s %8.1f %7d %8.2f %8d %8d %9d %7d %9d %8s\n", \
            p, durm, DP[p], rate, CT[p], SF[p], (P6[p]/1000), gavg, TH[p], aws;
        }
      }
    ' "$_all" | sort -k4 -rn
    awk -F'\t' '
      !/^#/ && ($1=="idle" || $1=="sleep") { d=$3-$2; if(d>DUR){DUR=d;SP=$4;EP=$5;CT=$6;SF=$7;P6=$8;AW=$12} }
      END{ if(DUR>=10800){ aws=(AW>=0)?sprintf("%.1f",AW):"-";
        printf "%-15s %8.1f %7d %8.2f %8d %8d %9d %7s %9s %8s\n", \
        "night(longest)", DUR/60.0, SP-EP, (SP-EP)*3600.0/DUR, CT, SF, (P6/1000), "-", "-", aws } }
    ' "$_all"
    echo ""
    echo "Legend: d_pct=battery % consumed (negative=gained while charging),"
    echo "        pct/h=drain rate, cpuT/surfT=peak temps (°C), p6MHz=peak prime"
    echo "        clock, gpu%=avg GPU busy, throttle=ticks the prime was capped."
    echo "        awake%=awake share = CLOCK_MONOTONIC delta / boottime delta"
    echo "        (Android uptimeMillis/elapsedRealtime); excludes suspend."
    echo "        On sleep/idle blocks target <5%, >15% = something holds the CPU."
    echo "        night(longest)=longest continuous screen-off block >=3h — the pure"
    echo "        overnight rate; compare IT (not the mixed idle row) against 0.3-0.7 %/h."
    echo "        The currently-open phase is included, so interim reports are complete."
  } > "$LK_OUT_DIR/phase_summary.txt"
  rm -f "$_all" "$LK_OUT_DIR/.phase_open.tsv" 2>/dev/null
}

lk_emit_screenoff_sleep() {
  _bs=$(dumpsys batterystats 2>/dev/null | grep -m1 -iE "screen off:.*realtime.*uptime")
  [ -z "$_bs" ] && { echo "  screen-off CPU sleep: n/a (batterystats line not found)"; return 0; }
  echo "$_bs" | sed 's/.*[Ss]creen off: //; s/ realtime,/|/; s/ uptime.*//' | awk -F'|' '
    function tosec(t,  n,a,i,v,u){ n=split(t,a," "); v=0
      for(i=1;i<=n;i++){ u=a[i]
        if(u ~ /ms$/) continue
        if(u ~ /h$/){sub(/h/,"",u); v+=u*3600}
        else if(u ~ /m$/){sub(/m/,"",u); v+=u*60}
        else if(u ~ /s$/){sub(/s/,"",u); v+=u} }
      return v }
    { rt=$1; sub(/ \(.*\)/,"",rt); r=tosec(rt); u=tosec($2)
      if(r>0){ aw=u*100.0/r
        printf "  screen-off: %.1fh realtime, CPU awake %.0fm -> awake %.1f%% (deep sleep %.1f%%)\n", r/3600.0, u/60.0, aw, 100-aw
        printf "  NOTE: batterystats is reset every %s min, so this covers only the last\n", ENVIRON["LK_BSTATS_WINDOW_MIN"]
        printf "        window, NOT the whole night. For the overnight number read the\n"
        printf "        awake%% column of night(longest) in the per-phase summary.\n" } }'
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
    echo "----- NIGHT / SCREEN-OFF CPU SLEEP -----"
    lk_emit_screenoff_sleep
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
    if [ -s "$LK_OUT_DIR/_wakelock_report.txt" ]; then
      echo "Android batterystats attribution (works without debugfs):"
      echo "see _wakelock_report.txt for the ranked offenders. Top of it:"
      sed -n '/TOP PARTIAL WAKELOCK HOLDERS/,/TOP ALARM/p' \
        "$LK_OUT_DIR/_wakelock_report.txt" 2>/dev/null | head -12
    elif [ -s "$LK_OUT_DIR/wake_sources.txt" ]; then
      echo "see wake_sources.txt for full detail. DELTA (active time gained"
      echo "during capture) is the actionable part — top offenders:"
      awk '/DELTA over capture/{f=1;next} /^=====/{f=0} f&&NF>=3 && $1!~/^#/{print}' \
        "$LK_OUT_DIR/wake_sources.txt" | head -12
    else
      echo "wakeup attribution unavailable (no debugfs and no dumpsys)."
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
printf '# phase\tstart\tend\tstart_pct\tend_pct\tmaxCpuT\tmaxSurfT\tmaxP6\tgpuAvg\tthrottle\twakePeak\tawakePct\n' > "$LK_OUT_DIR/phase_ledger.tsv"

# wakelock baseline + reset
lk_wakelock_kernel_baseline
lk_wakelock_kernel_snapshot "start"
lk_wakelock_batterystats_reset
lk_oem_ram_expand_probe "start"
lk_oem_toggle_row

echo "[$(date '+%H:%M:%S')] FULL-DAY capture running up to ${LK_HOURS}h. Use the phone normally."

_last_snapshot=$(date +%s)
_last_wakesnap=$(date +%s)
lk_sample_gpu_busy
lk_detect_phase "$(date +%s)"; _phase="$LK_PHASE_OUT"
lk_phase_ledger_open "$_phase"
echo "$(date +%s)|$(date '+%Y-%m-%d %H:%M:%S')|$_phase|capture_start" >> "$LK_OUT_DIR/phase_timeline.txt"

while : ; do
  _now=$(date +%s)
  _elapsed=$(( _now - LK_START_EPOCH ))
  [ "$_elapsed" -ge "$LK_MAX_SEC" ] && break

  lk_wl_acquire
  lk_sample_gpu_busy

  # detect phase; on change, flush the ledger and re-open
  lk_detect_phase "$_now"; _new_phase="$LK_PHASE_OUT"
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
    # Android-side wakelock attribution snapshot each hour (works without
    # debugfs). Dumps + refreshes the parsed offenders report, then resets the
    # batterystats window so the next hour is attributed cleanly.
    lk_wakelock_batterystats_dump 2>/dev/null || true
    lk_wakelock_batterystats_reset 2>/dev/null || true
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
