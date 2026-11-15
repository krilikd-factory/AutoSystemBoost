#!/system/bin/sh
# Read-only, on-demand pressure snapshot. Requires the collector's _emit and _read helpers.
# This is a documented load heuristic, not a device-health score or an A/B saving estimate.

_asb_num() { case "$1" in ''|*[!0-9.]*) return 1 ;; *) return 0 ;; esac; }

_asb_cpu_online_count() {
  awk -F, '{ n=0; for (i=1;i<=NF;i++) { split($i,a,"-"); if (a[1] ~ /^[0-9]+$/ && (a[2] == "" || a[2] ~ /^[0-9]+$/)) n += (a[2] == "" ? 1 : a[2]-a[1]+1) } print n }' 2>/dev/null
}

_asb_psi_some10() {
  sed -n 's/^some avg10=\([0-9][0-9.]*\) .*/\1/p' "$1" 2>/dev/null | head -n 1
}

_asb_hz() {
  awk '{ for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/ && $i > 0) { v=$i; if (v < 100000) v=v*1000000; printf "%.0f\n", v } }' 2>/dev/null
}

_asb_cpu_times() {
  awk 'NR==1 && $1=="cpu" { total=0; for(i=2;i<=9;i++) total += $i; idle=$5+$6; print total, idle; exit }' "$PROC/stat" 2>/dev/null
}

_asb_pressure_collect() {
  _pl_load="$(_read "$PROC/loadavg" | awk '{print $1}')"
  _pl_online_raw="$(_read "$SYS/devices/system/cpu/online")"
  _pl_online="$(printf '%s\n' "$_pl_online_raw" | _asb_cpu_online_count)"
  _pl_load_part='not exposed'; _pl_load_norm='not exposed'; _pl_load_weight=0
  if _asb_num "$_pl_load" && case "$_pl_online" in ''|0) false ;; *) true ;; esac; then
    _pl_load_norm="$(awk -v l="$_pl_load" -v c="$_pl_online" 'BEGIN { printf "%.3f", l/c }')"
    _pl_load_part="$(awk -v n="$_pl_load_norm" 'BEGIN { p=n*50; if(p>100)p=100; if(p<0)p=0; printf "%.1f",p }')"
    _pl_load_weight=35
  fi

  _pl_total="$(_mem "$PROC/meminfo" MemTotal | awk '{print $1}')"
  _pl_avail="$(_mem "$PROC/meminfo" MemAvailable | awk '{print $1}')"
  _pl_mem_part='not exposed'; _pl_mem_used='not exposed'; _pl_mem_weight=0
  if _asb_num "$_pl_total" && _asb_num "$_pl_avail" && [ "$_pl_total" -gt 0 ] 2>/dev/null; then
    _pl_mem_used="$(awk -v t="$_pl_total" -v a="$_pl_avail" 'BEGIN { u=(t-a)*100/t; if(u<0)u=0;if(u>100)u=100;printf "%.1f",u }')"
    _pl_mem_part="$(awk -v u="$_pl_mem_used" 'BEGIN { p=(u-40)*2; if(p<0)p=0;if(p>100)p=100;printf "%.1f",p }')"
    _pl_mem_weight=30
  fi

  _pl_cpu_part='not exposed'; _pl_cpu_busy='not exposed'; _pl_cpu_weight=0; _pl_cpu_window='not exposed'
  _pl_sample="${ASB_PRESSURE_CPU_SAMPLE_S:-0.20}"
  _pl_c1="$(_asb_cpu_times)"
  if [ -n "$_pl_c1" ] && [ "$_pl_sample" != 0 ]; then
    sleep "$_pl_sample" 2>/dev/null || sleep 1
    _pl_c2="$(_asb_cpu_times)"
    if [ -n "$_pl_c2" ]; then
      _pl_cpu_busy="$(awk -v a="$_pl_c1" -v b="$_pl_c2" -v s="$_pl_sample" 'BEGIN { split(a,x," ");split(b,y," ");dt=y[1]-x[1];di=y[2]-x[2]; if(dt>0 && di>=0 && di<=dt){p=(dt-di)*100/dt;printf "%.1f",p;printf "\n%d",s*1000}else print "not exposed\nnot exposed"}')"
      _pl_cpu_window="$(printf '%s\n' "$_pl_cpu_busy" | sed -n '2p')"
      _pl_cpu_busy="$(printf '%s\n' "$_pl_cpu_busy" | sed -n '1p')"
      if _asb_num "$_pl_cpu_busy"; then _pl_cpu_part="$_pl_cpu_busy"; _pl_cpu_weight=25; else _pl_cpu_window='not exposed'; fi
    fi
  fi

  _pl_gpu_part='not exposed'; _pl_gpu_busy='not exposed'; _pl_gpu_weight=0; _pl_gpu_source='not exposed'
  _pl_gpu_path="${ASB_PRESSURE_GPU_BUSY:-}"
  if [ -z "$_pl_gpu_path" ]; then
    for _pl_try in "$SYS/class/kgsl/kgsl-3d0/gpu_busy" "$SYS/kernel/gpu/gpu_busy" "$SYS/class/devfreq/gpufreq/gpu_busy"; do
      [ -r "$_pl_try" ] && { _pl_gpu_path="$_pl_try"; break; }
    done
  fi
  if [ -n "$_pl_gpu_path" ] && [ -r "$_pl_gpu_path" ]; then
    _pl_gpu_raw="$(_read "$_pl_gpu_path")"
    _pl_gpu_busy="$(printf '%s\n' "$_pl_gpu_raw" | awk 'NR==1 { if($1 ~ /^[0-9]+([.][0-9]+)?$/ && ($2=="" || $2=="%")){p=$1}else if($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2>0){p=$1*100/$2}else if($1 == "0" && $2 == "0"){p=0}else{print "not exposed";exit} if(p<0||p>100){print "not exposed";exit}printf "%.1f",p}')"
    if _asb_num "$_pl_gpu_busy"; then _pl_gpu_part="$_pl_gpu_busy"; _pl_gpu_weight=10; _pl_gpu_source="$_pl_gpu_path"; fi
  fi

  _pl_gpu_clock='not exposed'; _pl_gpu_work='not exposed'
  _pl_clk_file="${ASB_PRESSURE_GPU_CLK:-}"; _pl_tab_file="${ASB_PRESSURE_GPU_FREQS:-}"
  if [ -z "$_pl_clk_file" ]; then
    if [ -r "$SYS/class/kgsl/kgsl-3d0/devfreq/cur_freq" ]; then
      _pl_clk_file="$SYS/class/kgsl/kgsl-3d0/devfreq/cur_freq"; _pl_tab_file="$SYS/class/kgsl/kgsl-3d0/devfreq/available_frequencies"
    elif [ -r "$SYS/kernel/gpu/gpu_clock" ]; then
      _pl_clk_file="$SYS/kernel/gpu/gpu_clock"; _pl_tab_file="$SYS/kernel/gpu/gpu_freq_table"
    fi
  fi
  if _asb_num "$_pl_gpu_busy" && [ -n "$_pl_clk_file" ] && [ -r "$_pl_clk_file" ] && [ -r "$_pl_tab_file" ]; then
    _pl_clk_hz="$(_read "$_pl_clk_file" | _asb_hz | head -n 1)"
    _pl_max_hz="$(_read "$_pl_tab_file" | _asb_hz | sort -n | tail -n 1)"
    if _asb_num "$_pl_clk_hz" && _asb_num "$_pl_max_hz" && [ "$_pl_max_hz" -gt 0 ] 2>/dev/null; then
      _pl_gpu_clock="$(awk -v c="$_pl_clk_hz" 'BEGIN { printf "%d", c/1000000 }')"
      _pl_gpu_work="$(awk -v b="$_pl_gpu_busy" -v c="$_pl_clk_hz" -v m="$_pl_max_hz" 'BEGIN { if (c>m) c=m; printf "%.1f", b*c/m }')"
      _pl_gpu_part="$_pl_gpu_work"
    fi
  fi

  _pl_basis='loadavg and memory share'
  _pl_psi_cpu='not exposed'; _pl_psi_cpu_part='not exposed'; _pl_psi_cpu_weight=0
  _pl_psi_mem='not exposed'; _pl_psi_mem_part='not exposed'; _pl_psi_mem_weight=0
  _pl_psi_io='not exposed'; _pl_psi_io_part='not exposed'; _pl_psi_io_weight=0
  _pl_psi_dir="${ASB_PRESSURE_PSI:-$PROC/pressure}"
  if [ -r "$_pl_psi_dir/cpu" ] && [ -r "$_pl_psi_dir/memory" ]; then
    _pl_psi_cpu="$(_asb_psi_some10 "$_pl_psi_dir/cpu")"
    _pl_psi_mem="$(_asb_psi_some10 "$_pl_psi_dir/memory")"
    [ -r "$_pl_psi_dir/io" ] && _pl_psi_io="$(_asb_psi_some10 "$_pl_psi_dir/io")"
    _asb_num "$_pl_psi_cpu" || _pl_psi_cpu='not exposed'
    _asb_num "$_pl_psi_mem" || _pl_psi_mem='not exposed'
    _asb_num "$_pl_psi_io" || _pl_psi_io='not exposed'
  fi
  if _asb_num "$_pl_psi_cpu" && _asb_num "$_pl_psi_mem"; then
    _pl_basis='pressure stall information (PSI)'
    _pl_psi_cpu_part="$(awk -v v="$_pl_psi_cpu" 'BEGIN { p=v*2; if(p>100)p=100; printf "%.1f",p }')"; _pl_psi_cpu_weight=30
    _pl_psi_mem_part="$(awk -v v="$_pl_psi_mem" 'BEGIN { p=v*5; if(p>100)p=100; printf "%.1f",p }')"; _pl_psi_mem_weight=25
    if _asb_num "$_pl_psi_io"; then
      _pl_psi_io_part="$(awk -v v="$_pl_psi_io" 'BEGIN { p=v*4; if(p>100)p=100; printf "%.1f",p }')"; _pl_psi_io_weight=10
    fi
    _pl_load_weight=0; _pl_mem_weight=0
  fi

  _pl_weight=$((_pl_load_weight + _pl_mem_weight + _pl_cpu_weight + _pl_gpu_weight + _pl_psi_cpu_weight + _pl_psi_mem_weight + _pl_psi_io_weight))
  _pl_coverage="$_pl_weight"
  _pl_score='unknown'; _pl_band='unknown'; _pl_formula='insufficient measured coverage (minimum 40%)'
  if [ "$_pl_weight" -ge 40 ]; then
    _pl_score="$(awk -v w="$_pl_weight" -v lw="$_pl_load_weight" -v lp="$_pl_load_part" -v mw="$_pl_mem_weight" -v mp="$_pl_mem_part" -v cw="$_pl_cpu_weight" -v cp="$_pl_cpu_part" -v gw="$_pl_gpu_weight" -v gp="$_pl_gpu_part" -v pcw="$_pl_psi_cpu_weight" -v pcp="$_pl_psi_cpu_part" -v pmw="$_pl_psi_mem_weight" -v pmp="$_pl_psi_mem_part" -v piw="$_pl_psi_io_weight" -v pip="$_pl_psi_io_part" 'BEGIN { s=0;if(lw)s+=lw*lp;if(mw)s+=mw*mp;if(cw)s+=cw*cp;if(gw)s+=gw*gp;if(pcw)s+=pcw*pcp;if(pmw)s+=pmw*pmp;if(piw)s+=piw*pip;printf "%.0f",s/w }')"
    case "$_pl_score" in
      ''|*[!0-9]*) _pl_score='unknown' ;;
      *) if [ "$_pl_score" -lt 25 ]; then _pl_band=light; elif [ "$_pl_score" -lt 50 ]; then _pl_band=moderate; elif [ "$_pl_score" -lt 75 ]; then _pl_band=high; else _pl_band=very_high; fi ;;
    esac
    _pl_formula="weighted mean of available components / $_pl_weight%; missing weights renorm.; 0-24 light, 25-49 moderate, 50-74 high, 75-100 very high"
  fi

  _pl_swap_total="$(_mem "$PROC/meminfo" SwapTotal | awk '{print $1}')"
  _pl_swap_free="$(_mem "$PROC/meminfo" SwapFree | awk '{print $1}')"
  _pl_swap_used='not exposed'
  if _asb_num "$_pl_swap_total" && _asb_num "$_pl_swap_free" && [ "$_pl_swap_total" -gt 0 ] 2>/dev/null; then
    _pl_swap_used="$(awk -v t="$_pl_swap_total" -v f="$_pl_swap_free" 'BEGIN { printf "%.1f",(t-f)*100/t }')"
  fi

  _emit system_load score "$_pl_score"
  _emit system_load band "$_pl_band"
  _emit system_load scale '0-100 current pressure heuristic; not health, not a trend'
  _emit system_load coverage_pct "$_pl_coverage"
  _emit system_load confidence 'single on-demand snapshot; no baseline or A/B inference'
  _emit system_load formula "$_pl_formula"
  _emit system_load loadavg_1m "${_pl_load:-not exposed}"
  _emit system_load online_cpus "${_pl_online:-not exposed}"
  _emit system_load load_per_core "$_pl_load_norm"
  _emit system_load load_component "$_pl_load_part"
  _emit system_load load_weight "$_pl_load_weight"
  _emit system_load memory_total_kb "${_pl_total:-not exposed}"
  _emit system_load memory_available_kb "${_pl_avail:-not exposed}"
  _emit system_load memory_used_pct "$_pl_mem_used"
  _emit system_load memory_component "$_pl_mem_part"
  _emit system_load memory_weight "$_pl_mem_weight"
  _emit system_load cpu_busy_pct "$_pl_cpu_busy"
  _emit system_load cpu_component "$_pl_cpu_part"
  _emit system_load cpu_weight "$_pl_cpu_weight"
  _emit system_load cpu_window_ms "$_pl_cpu_window"
  _emit system_load gpu_busy_pct "$_pl_gpu_busy"
  _emit system_load gpu_component "$_pl_gpu_part"
  _emit system_load gpu_weight "$_pl_gpu_weight"
  _emit system_load gpu_source "$_pl_gpu_source"
  _emit system_load gpu_clock_mhz "$_pl_gpu_clock"
  _emit system_load gpu_work_pct "$_pl_gpu_work"
  _emit system_load basis "$_pl_basis"
  _emit system_load psi_cpu_some_avg10 "$_pl_psi_cpu"
  _emit system_load psi_cpu_component "$_pl_psi_cpu_part"
  _emit system_load psi_cpu_weight "$_pl_psi_cpu_weight"
  _emit system_load psi_memory_some_avg10 "$_pl_psi_mem"
  _emit system_load psi_memory_component "$_pl_psi_mem_part"
  _emit system_load psi_memory_weight "$_pl_psi_mem_weight"
  _emit system_load psi_io_some_avg10 "$_pl_psi_io"
  _emit system_load psi_io_component "$_pl_psi_io_part"
  _emit system_load psi_io_weight "$_pl_psi_io_weight"
  _emit system_load swap_total_kb "${_pl_swap_total:-not exposed}"
  _emit system_load swap_used_pct "$_pl_swap_used"
  _emit system_load swap_role 'supporting signal only; occupancy is not scored and does not prove a problem'
  _emit system_load loadavg_role 'includes running/runnable and uninterruptible wait; it is not CPU usage'
}
