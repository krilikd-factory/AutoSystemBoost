command -v asb_settings_put >/dev/null 2>&1 || asb_settings_put() {
  settings put "$1" "$2" "$3" >/dev/null 2>&1 || true
}
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
  local _s _p
  _p="$(cat "$MODDIR/current_profile" 2>/dev/null)"
  case "$_p" in
    performance) _s='description=status: Performance 🔥 | active ✅' ;;
    battery)     _s='description=status: Battery 🔋 | active ✅' ;;
    smart)       _s='description=status: Smart Mode 🤖 | active ✅' ;;
    *)           _s='description=status: Balanced ⚖️ | active ✅' ;;
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
    # CPU CAP OWNERSHIP: scaling_max/min are written ONLY by service.sh
    : # caps intentionally not computed or written here

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
  # GPU FREQ OWNERSHIP (single-owner, mirrors the CPU refactor): devfreq
  : # GPU freq caps intentionally not written here
}

asb_apply_vm() {
  asb_feature_enabled VM || return 0
  # Camera guard owns swappiness while a recording is in flight.
  #
  # service.sh already checks this and smart_dynamic_tune.sh does too, but the profile
  # path did not - so switching profile mid-recording wrote the profile's swappiness
  # straight over the guard's 10, and on release the guard restored a value that was
  # captured before the switch. Same bug the tuner had; this was the last writer still
  # missing the check.
  [ -r /dev/.asb/camera_guard ] || sysctlw vm.swappiness "$VM_SWAPPINESS" || true
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
    asb_settings_put system cloud_dns_happy_eyeballs_priority_enabled "$NET_HAPPY_EYEBALLS"
  fi
  if has tc; then
    for _if in $(ls /sys/class/net 2>/dev/null | tr '\n' ' '); do
      case "$_if" in wlan0|rmnet*|ccmni*) tc qdisc replace dev "$_if" root "$NET_QDISC" >/dev/null 2>&1 || true ;; esac
    done
  fi
}

# OEM-owned settings need a baseline that is captured ONCE, before ASB has ever
# touched them, and never re-captured. Recording "the current value" on every boot
# looks the same on boot 1 and quietly records ASB's own value from boot 2 onwards -
# at which point uninstall restores what ASB wrote instead of what the user had.
asb_oem_baseline_save() {
  _ob_log="/data/adb/asb/oem_restore.log"
  mkdir -p /data/adb/asb 2>/dev/null || true
  [ -f "$_ob_log" ] || : > "$_ob_log" 2>/dev/null
  grep -q "^$1|" "$_ob_log" 2>/dev/null && return 0
  echo "$1|$(settings get global "$1" 2>/dev/null)" >> "$_ob_log" 2>/dev/null || true
}

# Turn RAM expansion off the way OxygenOS itself records it.
#
# OOS tracks this toggle in THREE keys, not two: ram_expand_size, ram_expand_size_list
# and ram_expand_switch_state. ASB only ever zeroed the first two, so while the module
# was installed it re-zeroed them at every boot and the slider looked off - but OOS
# still had switch_state=1 on record. Remove the module and nothing re-zeroes anything;
# OOS repairs the inconsistency from its own switch record, RAM expansion comes back on,
# swap-on-UFS resumes and the phone runs hot. Reported from the field on a OnePlus 13:
# "after every uninstall the RAM expansion slider turns itself on and the phone heats up".
asb_ram_expand_apply() {
  has settings || return 0
  for _rk in ram_expand_size ram_expand_size_list ram_expand_switch_state; do
    asb_oem_baseline_save "$_rk"
  done
  if [ "$1" = "0" ]; then
    asb_settings_put global ram_expand_size 0
    asb_settings_put global ram_expand_size_list 0
    asb_settings_put global ram_expand_switch_state 0
  else
    asb_settings_put global ram_expand_switch_state 1
    asb_settings_put global ram_expand_size "$1"
  fi
}

asb_apply_ux() {
  asb_feature_enabled FPS || asb_feature_enabled VM || return 0
  has settings || return 0
  local _anim_changed=0
  local _ux_base="$MODDIR/config/ux_baseline.conf"

  # Load the WebUI-controlled UX_MANAGE_* flags from governor.conf. These are
  _ux_conf="$MODDIR/config/governor.conf"
  if [ -r "$_ux_conf" ]; then
    # UX_MANAGE_ANIM_SCALE was dropped here in V60: its WebUI card was removed and the
    # animation block below is gated on UX_MANAGE_TIMEOUTS, which owns both the scales
    # and the touch timeouts. Loading it kept a config key alive that a hand-editor
    # could set to 1 and get nothing for.
    for _uxk in UX_MANAGE_TIMEOUTS UX_MANAGE_OEM_TOGGLES \
                UX_ANIM_FORCE_RESTART; do
      _uxv="$(grep -E "^[[:space:]]*${_uxk}=" "$_ux_conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
      case "$_uxv" in
        1|on)  eval "$_uxk=1" ;;
        0|off) eval "$_uxk=0" ;;
        # absent or unexpected → leave whatever is already set (default 0 via :-)
      esac
    done
    # Also read the OEM-toggle TARGET values (what to actually write when the user
    for _uxk in UX_RAM_EXPAND UX_ADAPTIVE_BAT UX_LOW_HEAT; do
      _uxv="$(grep -E "^[[:space:]]*${_uxk}=" "$_ux_conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
      case "$_uxv" in
        ''|*[!0-9]*) : ;;            # absent/non-numeric → leave unset
        *) eval "$_uxk=$_uxv" ;;
      esac
    done
  fi
  # When the user turns ON "Manage OEM Toggles" without having picked explicit
  if [ "${UX_MANAGE_OEM_TOGGLES:-0}" = "1" ] && [ -z "$UX_RAM_EXPAND" ]; then
    UX_RAM_EXPAND=0
  fi

  # ANIMATION SCALES — manage OR restore.
  if [ -n "$UX_ANIM_SCALE" ] && [ "${UX_MANAGE_TIMEOUTS:-0}" = "1" ]; then
    # Save the user's stock scales ONCE, before we ever override them, so we can
    # put them back when the toggle is turned off.
    if [ ! -f "$_ux_base" ]; then
      mkdir -p "$MODDIR/config" 2>/dev/null
      {
        echo "BASE_WIN_ANIM=$(settings get global window_animation_scale 2>/dev/null)"
        echo "BASE_TRANS_ANIM=$(settings get global transition_animation_scale 2>/dev/null)"
        echo "BASE_DUR_ANIM=$(settings get global animator_duration_scale 2>/dev/null)"
        echo "BASE_LONG_PRESS=$(settings get secure long_press_timeout 2>/dev/null)"
        echo "BASE_MULTI_PRESS=$(settings get secure multi_press_timeout 2>/dev/null)"
      } > "$_ux_base" 2>/dev/null
    fi
    local _cur_anim
    _cur_anim="$(settings get global window_animation_scale 2>/dev/null)"
    if [ "$_cur_anim" != "$UX_ANIM_SCALE" ]; then
      asb_settings_put global animator_duration_scale "$UX_ANIM_SCALE"
      asb_settings_put global transition_animation_scale "$UX_ANIM_SCALE"
      asb_settings_put global window_animation_scale "$UX_ANIM_SCALE"
      _anim_changed=1
    fi
  else
    # Toggle is OFF — if we previously overrode the scales, RESTORE the saved
    if [ -f "$_ux_base" ]; then
      . "$_ux_base" 2>/dev/null
      local _restore=0
      _cur_anim="$(settings get global window_animation_scale 2>/dev/null)"
      case "$BASE_WIN_ANIM" in ''|null) BASE_WIN_ANIM=1 ;; esac
      case "$BASE_TRANS_ANIM" in ''|null) BASE_TRANS_ANIM=1 ;; esac
      case "$BASE_DUR_ANIM" in ''|null) BASE_DUR_ANIM=1 ;; esac
      if [ "$_cur_anim" != "$BASE_WIN_ANIM" ]; then
        asb_settings_put global animator_duration_scale "$BASE_DUR_ANIM"
        asb_settings_put global transition_animation_scale "$BASE_TRANS_ANIM"
        asb_settings_put global window_animation_scale "$BASE_WIN_ANIM"
        _restore=1
      fi
      [ "$_restore" = "1" ] && _anim_changed=1
    else
      # No baseline saved, but the toggle is OFF. An EARLIER build may have
      _cur_anim="$(settings get global window_animation_scale 2>/dev/null)"
      case "$_cur_anim" in
        0.8|0.80|0.9|0.90)
          asb_settings_put global animator_duration_scale 1.0
          asb_settings_put global transition_animation_scale 1.0
          asb_settings_put global window_animation_scale 1.0
          _anim_changed=1
          ;;
      esac
    fi
  fi

  # TOUCH TIMEOUTS — manage OR restore.
  if [ "${UX_MANAGE_TIMEOUTS:-0}" = "1" ]; then
    [ -n "$UX_LONG_PRESS" ] && asb_settings_put secure long_press_timeout "$UX_LONG_PRESS"
    [ -n "$UX_MULTI_PRESS" ] && asb_settings_put secure multi_press_timeout "$UX_MULTI_PRESS"
  elif [ -f "$_ux_base" ]; then
    . "$_ux_base" 2>/dev/null
    [ -n "$BASE_LONG_PRESS" ] && [ "$BASE_LONG_PRESS" != "null" ] && \
      asb_settings_put secure long_press_timeout "$BASE_LONG_PRESS"
    [ -n "$BASE_MULTI_PRESS" ] && [ "$BASE_MULTI_PRESS" != "null" ] && \
      asb_settings_put secure multi_press_timeout "$BASE_MULTI_PRESS"
  fi

  # OEM-owned settings (RAM expansion, adaptive battery, low-heat). These are
  if [ "${UX_MANAGE_OEM_TOGGLES:-0}" = "1" ]; then
    [ -n "$UX_ADAPTIVE_BAT" ] && asb_settings_put global adaptive_battery_management_enabled "$UX_ADAPTIVE_BAT"
    if [ -n "$UX_RAM_EXPAND" ]; then
      # Record what OOS currently has BEFORE we touch it, so a field report can
      if has settings; then
        _re_before=$(settings get global ram_expand_size 2>/dev/null)
        # Only log a real change. This fired on every profile apply and every boot,
        # writing "before=0 want=0" - a no-op - over and over: 147 lines on a device
        # that had been up for a few hours, none of which said anything.
        if [ "$_re_before" != "$UX_RAM_EXPAND" ]; then
          mkdir -p /data/adb/asb 2>/dev/null || true
          echo "$(date '+%F %T') apply ram_expand: before=${_re_before} want=${UX_RAM_EXPAND}" >> /data/adb/asb/ram_expand.log 2>/dev/null || true
        fi
      fi
      asb_ram_expand_apply "$UX_RAM_EXPAND"
    fi
    [ -n "$UX_LOW_HEAT" ] && asb_settings_put global sem_low_heat_mode "$UX_LOW_HEAT"
  fi
  asb_settings_put global google_core_control 0

  # Blur is a UX setting like the rest, and the one part of it that does NOT need a
  # reboot: WindowManager watches this global live, so the shade and the launcher drop
  # their blur the moment it is written. The system.prop half (SurfaceFlinger) still
  # needs the reboot, and asb_blur_apply.sh writes that.
  _blur_want="$(grep -E '^[[:space:]]*disable_blur=' "$_ux_conf" 2>/dev/null \
                | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_blur_want" in
    1) asb_settings_put global disable_window_blurs 1
       wm disable-blur true >/dev/null 2>&1 || true ;;
    0) asb_settings_put global disable_window_blurs 0
       wm disable-blur false >/dev/null 2>&1 || true ;;
  esac

  if [ "$_anim_changed" = "1" ]; then
    am broadcast -a android.intent.action.CONFIGURATION_CHANGED >/dev/null 2>&1 || true
  fi
  # SystemUI caches the animation scales at process start, so a restart is only
  # meaningful when a scale was actually rewritten this run - restarting it on every
  # boot regardless would be a visible hitch for nothing. The reason this looked dead
  # before is not the gate: asb_apply_ux was never reached at boot at all (see the
  # command -v fix in service.sh), so no scale was ever written and the gate never
  # opened.
  # Never on an AUTOMATIC profile change.
  #
  # Killing SystemUI blanks the screen for a couple of seconds, drops the user at the
  # lock screen and tears down every overlay another module has drawn into the status
  # bar. That is an acceptable price for a change the user just asked for; it is not
  # acceptable for one they did not.
  #
  # Auto-battery switches profiles at 20% on its own, and the profiles carry different
  # animation scales (balanced 0.9, battery 1.0), so _anim_changed was set and the kill
  # fired. Reported from the field as "at 19% the screen goes black for a moment, comes
  # back on the lock screen, and my status-bar icon module resets" - which reads exactly
  # like a SystemUI crash and is in fact us.
  #
  # The scales are written either way; SystemUI simply picks them up when it is next
  # restarted for its own reasons. A slightly stale animation duration is not worth
  # interrupting someone whose phone is already low on battery.
  # Restart SystemUI ONLY when the user personally asked for this profile change.
  #
  # PROFILE_FLAG is "user" for a tap in the WebUI, "auto" for an automatic switch, and
  # UNSET when service.sh re-applies the profile at boot. It used to be empty in the
  # user case too, so "unset" and "the user asked" were the same value - and the boot
  # path, which sets nothing, was read as a user request. The result: roughly a minute
  # into startup the reinforce pass found the animation scales still at their pre-boot
  # values, set _anim_changed, and killed SystemUI. Screen blinks, lock screen returns,
  # and every overlay another module has drawn into the status bar is torn down. Nobody
  # asked for any of it.
  #
  # Requiring the word "user" makes both silent cases - boot and auto-switch - fall
  # through. The scales are still written; SystemUI picks them up the next time it
  # restarts for its own reasons, which is a fair trade for never interrupting a boot.
  _ux_manual=0
  case "${PROFILE_FLAG:-}" in user) _ux_manual=1 ;; esac
  if [ "${UX_ANIM_FORCE_RESTART:-0}" = "1" ] && [ "$_anim_changed" = "1" ] \
     && [ "$_ux_manual" = "1" ]; then
    pkill -f com.android.systemui >/dev/null 2>&1 || true
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
  if [ -r "$MODDIR/current_profile" ]; then
    _cp="$(cat "$MODDIR/current_profile" 2>/dev/null)"
    [ -n "$_cp" ] && PROFILE="$_cp"
  fi
  case "$PROFILE" in
    battery|balanced|performance) : ;;
    smart)
      _SHELL_BOOT_PROFILE=balanced
      ;;
    *) PROFILE=balanced ;;
  esac
  _SHELL_BOOT_PROFILE="${_SHELL_BOOT_PROFILE:-$PROFILE}"
  # Remember what was actually REQUESTED before sourcing a profile file, because
  # every profiles/*.sh opens with PROFILE="<its own name>" and would otherwise
  # rewrite it - on smart that turns the request into "balanced" before anyone can
  # read it.
  _ASB_REQUESTED="$PROFILE"
  if [ -f "$MODDIR/profiles/$_SHELL_BOOT_PROFILE.sh" ]; then
    . "$MODDIR/profiles/$_SHELL_BOOT_PROFILE.sh"
  else
    _SHELL_BOOT_PROFILE=balanced
    . "$MODDIR/profiles/balanced.sh"
  fi
  PROFILE="$_ASB_REQUESTED"
  unset _SHELL_BOOT_PROFILE
  # ASB_PROFILE is what service.sh branches on - 21 case/if sites covering doze
  # constants, WiFi DTIM, sched_energy_aware, lpm_prediction, page-cluster and TCP
  # pacing. This function overrides the one in asb_utils.sh (sourced first, so this
  # one wins) and used to set only PROFILE, leaving ASB_PROFILE empty forever: every
  # one of those 21 sites fell through to its "*)" balanced branch, so the Battery
  # profile never applied its deepest power savings and Performance never applied its
  # loosest ones. The empty "profile=" in runtime_apply.log's reinforce lines was this.
  #
  # It carries the REQUESTED profile, including "smart" - not _SHELL_BOOT_PROFILE.
  # The shell layer loads balanced.sh for smart because the native governor owns the
  # frequencies, but a branch asking "is this battery?" must not be told "balanced"
  # when the user picked smart.
  ASB_PROFILE="$_ASB_REQUESTED"
  unset _ASB_REQUESTED
  # Populate the _P_* mapped variables that service.sh's apply_* helpers read.
  command -v asb_map_profile_vars >/dev/null 2>&1 && asb_map_profile_vars
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
