#!/system/bin/sh
MODID="AutoSystemBoost"
ASB_STATE_DIR="/dev/.asb_profile_state"
mkdir -p "$ASB_STATE_DIR" >/dev/null 2>&1 || true

asb_resolve_moddir() {
  local _hint="$1" _d
  for _d in \
    "$_hint" \
    "${0%/*}" \
    "/data/adb/modules/$MODID" \
    "/data/adb/modules_update/$MODID" \
    "/data/adb/modules/${MODID}_TMP" \
    "/data/adb/modules_update/${MODID}_TMP" \
    /data/adb/modules/*AutoSystemBoost* \
    /data/adb/modules_update/*AutoSystemBoost*
  do
    [ -n "$_d" ] || continue
    [ -f "$_d/module.prop" ] && { echo "$_d"; return 0; }
  done
  echo "/data/adb/modules/$MODID"
}

MODDIR="$(asb_resolve_moddir "$MODDIR")"

has() { command -v "$1" >/dev/null 2>&1; }
readf() { [ -r "$1" ] && cat "$1" 2>/dev/null; }
writef_retry() {
  local _p="$1" _v="$2" _tries="${3:-5}" _delay="${4:-0.12}" _i=1
  [ -e "$_p" ] || return 1
  while [ "$_i" -le "$_tries" ]; do
    [ -w "$_p" ] || return 1
    echo "$_v" > "$_p" 2>/dev/null || true
    [ ! -r "$_p" ] && return 0
    [ "$(cat "$_p" 2>/dev/null)" = "$_v" ] && return 0
    sleep "$_delay"
    _i=$((_i+1))
  done
  return 1
}

sysctlw() {
  local k="$1" v="$2" p
  if has sysctl; then sysctl -w "$k=$v" >/dev/null 2>&1 && return 0; fi
  p="/proc/sys/$(echo "$k" | tr . /)"
  [ -w "$p" ] || return 1
  echo "$v" > "$p" 2>/dev/null
}

asb_feature_enabled() {
  local _key="$1" _line
  [ -r "$MODDIR/features.conf" ] || return 0
  _line="$(grep -E "^${_key}=" "$MODDIR/features.conf" 2>/dev/null | tail -n 1)"
  [ -z "$_line" ] && return 0
  [ "${_line#*=}" = "1" ]
}

asb_update_desc() {
  local _s
  case "$PROFILE" in
    performance) _s='description=status: performance 🔥 | active ✅' ;;
    battery) _s='description=status: battery 🔋 | active ✅' ;;
    *) _s='description=status: balanced ⚖️ | active ✅' ;;
  esac
  sed "s/^description=.*/$_s/g" "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null || true
  grep -q '^description=' "$MODDIR/module.prop.tmp" 2>/dev/null && cat "$MODDIR/module.prop.tmp" > "$MODDIR/module.prop"
  rm -f "$MODDIR/module.prop.tmp"
}

asb_cpu_cluster_init() {
  LITTLE_POLICY=""
  BIG_POLICY=""
  CPU_MAX=7
  LITTLE_END=5
  for _p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_p" ] || continue
    [ -z "$LITTLE_POLICY" ] && LITTLE_POLICY="$_p"
    BIG_POLICY="$_p"
  done
  [ -z "$LITTLE_POLICY" ] && LITTLE_POLICY=/sys/devices/system/cpu/cpufreq/policy0
  [ -z "$BIG_POLICY" ] && BIG_POLICY="$LITTLE_POLICY"
  if [ -r /sys/devices/system/cpu/present ]; then
    _present="$(cat /sys/devices/system/cpu/present 2>/dev/null)"
    case "$_present" in *-*) CPU_MAX="${_present##*-}" ;; *) CPU_MAX="$_present" ;; esac
  fi
  [ -n "$CPU_MAX" ] || CPU_MAX=7
  if [ -r "$LITTLE_POLICY/related_cpus" ]; then
    _last="$(tr ' ' '\n' < "$LITTLE_POLICY/related_cpus" | tail -n 1)"
    case "$_last" in ''|*[!0-9]*) : ;; *) LITTLE_END="$_last" ;; esac
  fi
  [ "$LITTLE_END" -ge "$CPU_MAX" ] 2>/dev/null && LITTLE_END=$((CPU_MAX>1 ? CPU_MAX-1 : CPU_MAX))
  FG_CPUS="0-$CPU_MAX"
  BG_CPUS="0-$LITTLE_END"
  [ "$PROFILE" = "battery" ] && FG_CPUS="$BG_CPUS"
}

asb_pick_nearest_freq() {
  _dir="$1"
  _target="$2"
  [ -d "$_dir" ] || return 1
  if [ -r "$_dir/scaling_available_frequencies" ]; then
    _pick="$(tr ' ' '\n' < "$_dir/scaling_available_frequencies" | grep -v '^$' | sort -n | awk -v t="$_target" '$1<=t{v=$1} END{print v}')"
    [ -n "$_pick" ] || _pick="$(tr ' ' '\n' < "$_dir/scaling_available_frequencies" | grep -v '^$' | sort -n | head -1)"
  else
    _pick="$_target"
  fi
  [ -n "$_pick" ] && echo "$_pick"
}

asb_pick_freq_pct() {
  _dir="$1"
  _pct="$2"
  [ -d "$_dir" ] || return 1
  _max="$(cat "$_dir/cpuinfo_max_freq" 2>/dev/null)"
  [ -n "$_max" ] || return 1
  _target=$(( _max * _pct / 100 ))
  asb_pick_nearest_freq "$_dir" "$_target"
}

asb_pick_gpu_pct() {
  _dir=/sys/class/kgsl/kgsl-3d0/devfreq
  _pct="$1"
  [ -d "$_dir" ] || return 1
  _max="$(cat "$_dir/max_freq" 2>/dev/null)"
  [ -n "$_max" ] || return 1
  _target=$(( _max * _pct / 100 ))
  if [ -r "$_dir/available_frequencies" ]; then
    _pick="$(tr ' ' '\n' < "$_dir/available_frequencies" | grep -v '^$' | sort -n | awk -v t="$_target" '$1<=t{v=$1} END{print v}')"
    [ -n "$_pick" ] || _pick="$(tr ' ' '\n' < "$_dir/available_frequencies" | grep -v '^$' | sort -n | head -1)"
  else
    _pick="$_target"
  fi
  [ -n "$_pick" ] && echo "$_pick"
}

asb_apply_cpuset() {
  asb_feature_enabled CPU || return 0
  local _root _grp
  for _root in /dev/cpuset /sys/fs/cgroup; do
    [ -d "$_root" ] || continue
    for _grp in background system-background; do
      [ -e "$_root/$_grp/cpus" ] && writef_retry "$_root/$_grp/cpus" "$BG_CPUS" 8 0.18 || true
      [ -e "$_root/$_grp/cpuset.cpus" ] && writef_retry "$_root/$_grp/cpuset.cpus" "$BG_CPUS" 8 0.18 || true
    done
    for _grp in foreground top-app; do
      [ -e "$_root/$_grp/cpus" ] && writef_retry "$_root/$_grp/cpus" "$FG_CPUS" 8 0.18 || true
      [ -e "$_root/$_grp/cpuset.cpus" ] && writef_retry "$_root/$_grp/cpuset.cpus" "$FG_CPUS" 8 0.18 || true
    done
  done
}

asb_apply_uclamp() {
  asb_feature_enabled CPU || return 0
  local _root _tier _min _max
  for _root in /dev/cpuctl /sys/fs/cgroup /dev/cgroup; do
    [ -d "$_root" ] || continue
    for _tier in background system-background foreground top-app; do
      case "$_tier" in
        background|system-background) _min="$UCL_BG_MIN"; _max="$UCL_BG_MAX" ;;
        foreground) _min="$UCL_FG_MIN"; _max="$UCL_FG_MAX" ;;
        *) _min="$UCL_TOP_MIN"; _max="$UCL_TOP_MAX" ;;
      esac
      [ -e "$_root/$_tier/cpu.uclamp.min" ] && writef_retry "$_root/$_tier/cpu.uclamp.min" "$_min" 8 0.18 || true
      [ -e "$_root/$_tier/cpu.uclamp.max" ] && writef_retry "$_root/$_tier/cpu.uclamp.max" "$_max" 8 0.18 || true
      [ -e "$_root/$_tier/uclamp.min" ] && writef_retry "$_root/$_tier/uclamp.min" "$_min" 8 0.18 || true
      [ -e "$_root/$_tier/uclamp.max" ] && writef_retry "$_root/$_tier/uclamp.max" "$_max" 8 0.18 || true
    done
    [ -e "$_root/top-app/cpu.uclamp.latency_sensitive" ] && writef_retry "$_root/top-app/cpu.uclamp.latency_sensitive" "$LATENCY_SENSITIVE" 8 0.18 || true
    [ -e "$_root/top-app/uclamp.latency_sensitive" ] && writef_retry "$_root/top-app/uclamp.latency_sensitive" "$LATENCY_SENSITIVE" 8 0.18 || true
  done
}

asb_apply_walt() {
  asb_feature_enabled CPU || return 0
  [ -d /proc/sys/walt ] || return 0
  [ -e /proc/sys/walt/sched_ravg_window_nr_ticks ] && writef_retry /proc/sys/walt/sched_ravg_window_nr_ticks "$RAVG_TICKS" 8 0.18 || true
  [ -e /proc/sys/walt/sched_idle_enough ] && writef_retry /proc/sys/walt/sched_idle_enough "$WALT_IDLE" 8 0.18 || true
  [ -e /proc/sys/walt/sched_idle_enough_clust ] && writef_retry /proc/sys/walt/sched_idle_enough_clust "$WALT_IDLE_CLUST" 8 0.18 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct "$WALT_CLUSTER" 8 0.18 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct_clust ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct_clust "$WALT_CLUSTER_CLUST" 8 0.18 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_colocation ] && writef_retry /proc/sys/walt/sched_min_task_util_for_colocation "$WALT_COLOC" 8 0.18 || true
  [ -e /proc/sys/walt/sched_pipeline_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_util_thres "$WALT_PIPE" 8 0.18 || true
  [ -e /proc/sys/walt/sched_pipeline_non_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_non_special_task_util_thres "$WALT_PIPE_NONSP" 8 0.18 || true
  [ -e /proc/sys/walt/sched_pipeline_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_special_task_util_thres "$WALT_PIPE_SP" 8 0.18 || true
  [ -e /proc/sys/walt/sched_busy_hyst_ns ] && writef_retry /proc/sys/walt/sched_busy_hyst_ns "$WALT_BUSY_HYST" 8 0.18 || true
  [ -e /proc/sys/walt/sched_ed_boost ] && writef_retry /proc/sys/walt/sched_ed_boost "$WALT_ED_BOOST" 8 0.18 || true
  [ -e /proc/sys/walt/sched_topapp_weight_pct ] && writef_retry /proc/sys/walt/sched_topapp_weight_pct "$WALT_TOPAPP_WEIGHT" 8 0.18 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_boost ] && writef_retry /proc/sys/walt/sched_min_task_util_for_boost "$WALT_BOOST_MIN_UTIL" 8 0.18 || true
  [ -e /proc/sys/walt/sched_boost ] && writef_retry /proc/sys/walt/sched_boost "$WALT_SCHED_BOOST" 8 0.18 || true
}

asb_apply_cpu() {
  asb_feature_enabled CPU || return 0
  for _p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_p" ] || continue
    _rel="$(cat "$_p/related_cpus" 2>/dev/null | awk '{print $1}')"
    case "$_rel" in ''|*[!0-9]*) _rel=0 ;; esac
    if [ "$_rel" -le "$LITTLE_END" ]; then
      _cap="$CPU_CAP_LITTLE"
      _min="$CPU_MIN_LITTLE"
      _max_abs="$CPU_MAX_LITTLE"
    else
      _cap="$CPU_CAP_BIG"
      _min="$CPU_MIN_BIG"
      _max_abs="$CPU_MAX_BIG"
    fi

    _want=""
    if [ -n "$_max_abs" ]; then
      _want="$(asb_pick_nearest_freq "$_p" "$_max_abs")"
    elif [ -n "$_cap" ]; then
      if [ "$_cap" -ge 100 ] 2>/dev/null; then
        if [ -r "$_p/scaling_available_frequencies" ]; then
          _want="$(tr ' ' '\n' < "$_p/scaling_available_frequencies" | grep -v '^$' | sort -n | tail -1)"
        else
          _want="$(cat "$_p/cpuinfo_max_freq" 2>/dev/null)"
        fi
      else
        _want="$(asb_pick_freq_pct "$_p" "$_cap")"
      fi
    fi

    if [ -w "$_p/scaling_max_freq" ] && [ -n "$_want" ]; then
      writef_retry "$_p/scaling_max_freq" "$_want" 10 0.15 || true
    fi

    if [ -w "$_p/scaling_min_freq" ] && [ -n "$_min" ]; then
      _min_pick="$(asb_pick_nearest_freq "$_p" "$_min")"
      [ -n "$_min_pick" ] && writef_retry "$_p/scaling_min_freq" "$_min_pick" 10 0.15 || true
    fi

    if [ -r "$_p/scaling_max_freq" ] && [ -r "$_p/scaling_min_freq" ]; then
      _curmax="$(cat "$_p/scaling_max_freq" 2>/dev/null)"
      _curmin="$(cat "$_p/scaling_min_freq" 2>/dev/null)"
      if [ -n "$_curmax" ] && [ -n "$_curmin" ] && [ "$_curmin" -gt "$_curmax" ] 2>/dev/null; then
        writef_retry "$_p/scaling_min_freq" "$_curmax" 6 0.12 || true
      fi
    fi

    [ -w "$_p/schedutil/rate_limit_us" ] && writef_retry "$_p/schedutil/rate_limit_us" "$SCHED_RATE" 6 0.18 || true
    [ -w "$_p/schedutil/up_rate_limit_us" ] && writef_retry "$_p/schedutil/up_rate_limit_us" "$SCHED_UP_RATE" 6 0.18 || true
    [ -w "$_p/schedutil/down_rate_limit_us" ] && writef_retry "$_p/schedutil/down_rate_limit_us" "$SCHED_DOWN_RATE" 6 0.18 || true
    [ -w "$_p/schedutil/hispeed_load" ] && writef_retry "$_p/schedutil/hispeed_load" "$SCHED_HISPEED_LOAD" 6 0.18 || true
    [ -w "$_p/schedutil/hispeed_freq" ] && [ -n "$SCHED_HISPEED_FREQ" ] && writef_retry "$_p/schedutil/hispeed_freq" "$SCHED_HISPEED_FREQ" 6 0.18 || true
  done
  asb_apply_cpuset
  asb_apply_uclamp
}

asb_apply_gpu() {
  asb_feature_enabled CPU || return 0
  [ -w /sys/class/kgsl/kgsl-3d0/idle_timer ] && writef_retry /sys/class/kgsl/kgsl-3d0/idle_timer "$GPU_IDLE_TIMER" 6 0.18 || true
  [ -w /sys/class/kgsl/kgsl-3d0/force_no_nap ] && writef_retry /sys/class/kgsl/kgsl-3d0/force_no_nap "$GPU_FORCE_NO_NAP" 6 0.18 || true
  [ -w /sys/class/kgsl/kgsl-3d0/bus_split ] && [ -n "$GPU_BUS_SPLIT" ] && writef_retry /sys/class/kgsl/kgsl-3d0/bus_split "$GPU_BUS_SPLIT" 6 0.18 || true
  [ -w /sys/class/kgsl/kgsl-3d0/throttling ] && [ -n "$GPU_THROTTLING" ] && writef_retry /sys/class/kgsl/kgsl-3d0/throttling "$GPU_THROTTLING" 6 0.18 || true
  [ -w /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel ] && [ -n "$GPU_THERMAL_PWRLEVEL" ] && writef_retry /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel "$GPU_THERMAL_PWRLEVEL" 6 0.18 || true
  if [ -d /sys/class/kgsl/kgsl-3d0/devfreq ]; then
    if [ -n "$GPU_MAX_FREQ" ]; then
      _gmax="$GPU_MAX_FREQ"
    else
      _gmax="$(asb_pick_gpu_pct "$GPU_MAX_PCT")"
    fi
    [ -n "$_gmax" ] && writef_retry /sys/class/kgsl/kgsl-3d0/devfreq/max_freq "$_gmax" 6 0.18 || true
    if [ -n "$GPU_MIN_FREQ" ]; then
      _gmin="$GPU_MIN_FREQ"
      [ -n "$_gmin" ] && writef_retry /sys/class/kgsl/kgsl-3d0/devfreq/min_freq "$_gmin" 6 0.18 || true
    elif [ "$GPU_MIN_PCT" -gt 0 ] 2>/dev/null; then
      _gmin="$(asb_pick_gpu_pct "$GPU_MIN_PCT")"
      [ -n "$_gmin" ] && writef_retry /sys/class/kgsl/kgsl-3d0/devfreq/min_freq "$_gmin" 6 0.18 || true
    fi
  fi
}

asb_apply_vm() {
  asb_feature_enabled VM || return 0
  sysctlw vm.swappiness "$VM_SWAPPINESS" || true
  sysctlw vm.dirty_expire_centisecs "$VM_DIRTY_EXPIRE" || true
  sysctlw vm.dirty_writeback_centisecs "$VM_DIRTY_WRITEBACK" || true
  sysctlw vm.vfs_cache_pressure "$VM_VFS" || true
  [ -e /proc/sys/vm/stat_interval ] && sysctlw vm.stat_interval "$VM_STAT_INTERVAL" || true
  [ -e /proc/sys/vm/page-cluster ] && writef_retry /proc/sys/vm/page-cluster "$VM_PAGE_CLUSTER" 6 0.18 || true
  [ -e /proc/sys/vm/watermark_scale_factor ] && sysctlw vm.watermark_scale_factor "$VM_WMARK" || true
  [ -e /proc/sys/vm/min_free_kbytes ] && sysctlw vm.min_free_kbytes "$VM_MINFREE" || true
}

asb_apply_net() {
  asb_feature_enabled NET || return 0
  sysctlw net.ipv4.tcp_rmem "$NET_TCP_RMEM" || true
  sysctlw net.ipv4.tcp_wmem "$NET_TCP_WMEM" || true
  [ -e /proc/sys/net/ipv6/tcp_rmem ] && sysctlw net.ipv6.tcp_rmem "$NET_TCP_RMEM" || true
  [ -e /proc/sys/net/ipv6/tcp_wmem ] && sysctlw net.ipv6.tcp_wmem "$NET_TCP_WMEM" || true
  sysctlw net.core.rmem_max "$NET_RMEM_MAX" || true
  sysctlw net.core.wmem_max "$NET_WMEM_MAX" || true
  sysctlw net.core.optmem_max "$NET_OPTMEM_MAX" || true
  sysctlw net.core.netdev_max_backlog "$NET_BACKLOG" || true
  sysctlw net.core.netdev_budget "$NET_BUDGET" || true
  sysctlw net.core.netdev_budget_usecs "$NET_BUDGET_USECS" || true
  sysctlw net.core.dev_weight "$NET_DEV_WEIGHT" || true
  sysctlw net.ipv4.tcp_fastopen "$NET_TCP_FASTOPEN" || true
  [ -e /proc/sys/net/ipv4/tcp_notsent_lowat ] && sysctlw net.ipv4.tcp_notsent_lowat "$NET_TCP_NOTSENT" || true
  sysctlw net.ipv4.tcp_keepalive_time "$NET_TCP_KEEPIDLE" || true
  sysctlw net.ipv4.tcp_fin_timeout "$NET_TCP_FIN" || true
  [ -n "$NET_TCP_MTU_PROBING" ] && sysctlw net.ipv4.tcp_mtu_probing "$NET_TCP_MTU_PROBING" || true
  [ -n "$NET_UDP_MEM" ] && [ -e /proc/sys/net/ipv4/udp_mem ] && sysctlw net.ipv4.udp_mem "$NET_UDP_MEM" || true
  if [ -n "$NET_HAPPY_EYEBALLS" ] && has settings; then
    settings put system cloud_dns_happy_eyeballs_priority_enabled "$NET_HAPPY_EYEBALLS" >/dev/null 2>&1 || true
  fi
  if has tc; then
    for _if in $(ls /sys/class/net 2>/dev/null | tr '\n' ' '); do
      case "$_if" in wlan0|rmnet*|ccmni*) tc qdisc replace dev "$_if" root "$NET_QDISC" >/dev/null 2>&1 || true ;; esac
    done
  fi
}

asb_apply_ux() {
  # V44 — UX/animation no longer gated by VM toggle (was a category mismatch).
  # Now gated by FPS feature which is RESERVED but always = 1 by default.
  asb_feature_enabled FPS || asb_feature_enabled VM || return 0
  has settings || return 0
  local _anim_changed=0
  if [ -n "$UX_ANIM_SCALE" ]; then
    local _cur_anim
    _cur_anim="$(settings get global window_animation_scale 2>/dev/null)"
    if [ "$_cur_anim" != "$UX_ANIM_SCALE" ]; then
      settings put global animator_duration_scale "$UX_ANIM_SCALE" >/dev/null 2>&1 || true
      settings put global transition_animation_scale "$UX_ANIM_SCALE" >/dev/null 2>&1 || true
      settings put global window_animation_scale "$UX_ANIM_SCALE" >/dev/null 2>&1 || true
      _anim_changed=1
    fi
  fi
  [ -n "$UX_LONG_PRESS" ] && settings put secure long_press_timeout "$UX_LONG_PRESS" >/dev/null 2>&1 || true
  [ -n "$UX_MULTI_PRESS" ] && settings put secure multi_press_timeout "$UX_MULTI_PRESS" >/dev/null 2>&1 || true
  [ -n "$UX_ADAPTIVE_BAT" ] && settings put global adaptive_battery_management_enabled "$UX_ADAPTIVE_BAT" >/dev/null 2>&1 || true
  [ -n "$UX_RAM_EXPAND" ] && settings put global ram_expand_size "$UX_RAM_EXPAND" >/dev/null 2>&1 || true
  [ -n "$UX_LOW_HEAT" ] && settings put global sem_low_heat_mode "$UX_LOW_HEAT" >/dev/null 2>&1 || true
  settings put global google_core_control 0 >/dev/null 2>&1 || true

  # V44 — animation scale honest implementation.
  #
  # Reality check: Android caches ValueAnimator.sDurationScale per-process at
  # class init. Running activities (SystemUI, foreground app) never re-read
  # the value, even after `settings put global *_scale`. New activities pick
  # up the new value. There is NO standard API to force-refresh running apps.
  #
  # The only effective options are:
  #   1. Wait — new activities will use new scale (passive, recommended)
  #   2. Restart SystemUI — jarring but works (opt-in via UX_ANIM_FORCE_RESTART=1)
  #   3. Reboot
  #
  # V44 default = option 1 (passive). User can enable option 2 in governor.conf.
  if [ "$_anim_changed" = "1" ]; then
    if [ "${UX_ANIM_FORCE_RESTART:-0}" = "1" ]; then
      # Opt-in: pkill SystemUI so new launch picks up new scale.
      # Brief screen flash. SystemUI auto-respawns within ~1 sec.
      pkill -f com.android.systemui >/dev/null 2>&1 || true
    fi
    # Always-on best-effort hints (cheap, may help on some Android variants):
    am broadcast -a android.intent.action.CONFIGURATION_CHANGED >/dev/null 2>&1 || true
  fi
}

asb_apply_wifi() {
  asb_feature_enabled WIFI || return 0
  [ -e /sys/class/net/wlan0/tx_queue_len ] && writef_retry /sys/class/net/wlan0/tx_queue_len "$WIFI_TXQLEN" 6 0.18 || true
  ip link set wlan0 txqueuelen "$WIFI_TXQLEN" >/dev/null 2>&1 || true
  has iw && [ -n "$WIFI_COUNTRY" ] && iw reg set "$WIFI_COUNTRY" >/dev/null 2>&1 || true
  case "$WIFI_PM_MODE" in
    off) has iw && iw dev wlan0 set power_save off >/dev/null 2>&1 || true; [ -e /sys/module/wlan/parameters/wlan_pm ] && writef_retry /sys/module/wlan/parameters/wlan_pm 0 6 0.18 || true ;;
    on)  has iw && iw dev wlan0 set power_save on  >/dev/null 2>&1 || true; [ -e /sys/module/wlan/parameters/wlan_pm ] && writef_retry /sys/module/wlan/parameters/wlan_pm 1 6 0.18 || true ;;
    auto) : ;;
  esac
}

asb_load_profile() {
  if [ -z "$PROFILE" ] && [ -r "$MODDIR/current_profile" ]; then
    PROFILE="$(cat "$MODDIR/current_profile" 2>/dev/null)"
  fi
  case "$PROFILE" in
    battery|balanced|performance) : ;;
    *) PROFILE=balanced ;;
  esac
  if [ -f "$MODDIR/profiles/$PROFILE.sh" ]; then
    . "$MODDIR/profiles/$PROFILE.sh"
  else
    PROFILE=balanced
    . "$MODDIR/profiles/balanced.sh"
  fi
}

asb_apply_profile_once() {
  asb_load_profile
  asb_cpu_cluster_init
  asb_update_desc
  asb_apply_walt
  asb_apply_cpu
  asb_apply_gpu
  asb_apply_vm
  asb_apply_net
  asb_apply_wifi
  asb_apply_ux
}
