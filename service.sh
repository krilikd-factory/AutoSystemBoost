#!/system/bin/sh
exec >/dev/null 2>&1
MODID="AutoSystemBoost"
MODDIR="${0%/*}"
asb_resolve_moddir() {
  for _d in     "$MODDIR"     "/data/adb/modules/$MODID"     "/data/adb/modules_update/$MODID"     "/data/adb/modules/${MODID}_TMP"     "/data/adb/modules_update/${MODID}_TMP"
  do
    [ -n "$_d" ] || continue
    [ -f "$_d/module.prop" ] && { echo "$_d"; return 0; }
  done
  echo "/data/adb/modules/$MODID"
}
MODDIR="$(asb_resolve_moddir)"

[ -r "$MODDIR/common/profile_core.sh" ] && . "$MODDIR/common/profile_core.sh"
ASB_STATE_LOG="/dev/.asb_profile_state/runtime_apply.log"
asb_log(){ echo "[$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo now)] $*" >> "$ASB_STATE_LOG" 2>/dev/null || true; }

asb_map_profile_vars() {
  _P_RAVG="$RAVG_TICKS"
  _P_IDLE="$WALT_IDLE"
  _P_IDLEC="$WALT_IDLE_CLUST"
  _P_CLUT="$WALT_CLUSTER"
  _P_CLUTC="$WALT_CLUSTER_CLUST"
  _P_COLOC="$WALT_COLOC"
  _P_PIPE="$WALT_PIPE"
  _P_PIPEN="$WALT_PIPE_NONSP"
  _P_PIPES="$WALT_PIPE_SP"
  _P_CPUL="$CPU_MIN_LITTLE"
  _P_CPUB="$CPU_MIN_BIG"
  _P_SWAP="$VM_SWAPPINESS"
  _P_DEXP="$VM_DIRTY_EXPIRE"
  _P_DWB="$VM_DIRTY_WRITEBACK"
  _P_GTMR="$GPU_IDLE_TIMER"
  _P_BHYST="$WALT_BUSY_HYST"
  _P_EDB="$WALT_ED_BOOST"
  _P_TOPW="$WALT_TOPAPP_WEIGHT"
  _P_MINTB="$WALT_BOOST_MIN_UTIL"
  _P_SBOOST="$WALT_SCHED_BOOST"
  _P_UCL_BG="$UCL_BG_MIN"
  _P_UCL_FG="$UCL_FG_MIN"
  _P_UCL_TOP="$UCL_TOP_MIN"
  _P_CPUCAP_L="${CPU_CAP_LITTLE:-}"
  _P_CPUCAP_B="${CPU_CAP_BIG:-}"
  _P_CPU_MAXL="$CPU_MAX_LITTLE"
  _P_CPU_MAXB="$CPU_MAX_BIG"
  case "$WIFI_PM_MODE" in
    off) _P_WLAN_PM=0 ;;
    on) _P_WLAN_PM=1 ;;
    *) _P_WLAN_PM=2 ;;
  esac
  _P_WLAN_TXQLEN="$WIFI_TXQLEN"
  _P_LATENCY_SENSITIVE="$LATENCY_SENSITIVE"
  _P_GPU_MIN_PCT="$GPU_MIN_PCT"
  _P_GPU_MAX_PCT="$GPU_MAX_PCT"
  _P_VFS="$VM_VFS"
  _P_STATINT="$VM_STAT_INTERVAL"
  _P_WMARK="$VM_WMARK"
  _P_MINFREE="$VM_MINFREE"
  _P_QDISC="$NET_QDISC"
  _P_TCP_RMEM="$NET_TCP_RMEM"
  _P_TCP_WMEM="$NET_TCP_WMEM"
  _P_TCP_NOTSENT="$NET_TCP_NOTSENT"
  _P_NET_BACKLOG="$NET_BACKLOG"
  _P_NET_BUDGET="$NET_BUDGET"
  _P_NET_BUDGET_US="$NET_BUDGET_USECS"
  _P_DEV_WEIGHT="$NET_DEV_WEIGHT"
  _P_TCP_FASTOPEN="$NET_TCP_FASTOPEN"
  _P_TCP_KEEPIDLE="$NET_TCP_KEEPIDLE"
  _P_TCP_FIN="$NET_TCP_FIN"
}

asb_load_profile() {
  ASB_PROFILE="$(cat "$MODDIR/current_profile" 2>/dev/null)"
  case "$ASB_PROFILE" in
    performance|battery|balanced) : ;;

    *) ASB_PROFILE=balanced ;;
  esac
  PROFILE="$ASB_PROFILE"
  if [ -r "$MODDIR/profiles/$ASB_PROFILE.sh" ]; then
    . "$MODDIR/profiles/$ASB_PROFILE.sh"
  elif [ -r "$MODDIR/profiles/balanced.sh" ]; then
    PROFILE=balanced
    ASB_PROFILE=balanced
    . "$MODDIR/profiles/balanced.sh"
  fi
  asb_map_profile_vars
}
asb_load_profile

asb_feature_enabled() {
  _key="$1"
  [ -r "$MODDIR/features.conf" ] || return 0
  _line="$(grep -E "^${_key}=" "$MODDIR/features.conf" 2>/dev/null | tail -n 1)"
  [ -z "$_line" ] && return 0
  [ "${_line#*=}" = "1" ]
}

has() { command -v "$1" >/dev/null 2>&1; }
asb_has_risky_vendor_stack() {
  for _d in /data/adb/modules /data/adb/modules_update /data/adb/ksu/modules /data/adb/ksu/modules_update; do
    [ -d "$_d" ] || continue
    ls "$_d" 2>/dev/null | grep -qiE 'zeromount|overlayfs|susfs' && return 0
  done
  return 1
}
writef() { [ -w "$1" ] || return 1; echo "$2" > "$1" 2>/dev/null; }
readf() { [ -r "$1" ] && cat "$1" 2>/dev/null; }
writef_retry() {
  local _p="$1" _v="$2" _tries="${3:-3}" _delay="${4:-0.25}"
  [ -e "$_p" ] || return 1
  local i=1
  while [ $i -le $_tries ]; do
    [ -w "$_p" ] || return 1
    echo "$_v" > "$_p" 2>/dev/null || true
    [ -r "$_p" ] || return 0
    [ "$(cat "$_p" 2>/dev/null)" = "$_v" ] && return 0
    sleep "$_delay"
    i=$((i+1))
  done
  return 1
}
wait_path() {
  local _p="$1" _t="${2:-8}" i=0
  while [ $i -lt $_t ]; do
    [ -e "$_p" ] && return 0
    sleep 1
    i=$((i+1))
  done
  return 1
}
writef_verify() {
  _p="$1"; _v="$2"
  writef "$_p" "$_v" || return 1
  [ -r "$_p" ] || return 0
  _cur="$(cat "$_p" 2>/dev/null)"
  [ "$_cur" = "$_v" ] && return 0
  return 1
}
asb_update_desc() {
  _p="$(cat "$MODDIR/current_profile" 2>/dev/null)"
  case "$_p" in
    performance) _s="description=status: performance 🔥 | active ✅ | benchmark tuned" ;;
    battery) _s="description=status: battery 🔋 | active ✅ | ultra saver" ;;
    *) _s="description=status: balanced ⚖️ | active ✅ | default profile" ;;
  esac
  sed "s/^description=.*/$_s/g" "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null || true
  grep -q "^description=" "$MODDIR/module.prop.tmp" 2>/dev/null && cat "$MODDIR/module.prop.tmp" > "$MODDIR/module.prop"
  rm -f "$MODDIR/module.prop.tmp"
}
sysctlw() {
  k="$1"; v="$2"
  if has sysctl; then
    sysctl -w "$k=$v" >/dev/null 2>&1 && return 0
  fi
  p="/proc/sys/$(echo "$k" | tr . /)"
  [ -w "$p" ] || return 1
  echo "$v" > "$p" 2>/dev/null
}
until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; do
  sleep 2
done
sleep 15
asb_update_desc

ASB_GOV="$MODDIR/bin/asb"
ASB_GOV_ENABLED=0

asb_governor_running() {
  [ -f /dev/.asb/governor.pid ] || return 1
  _gpid="$(cat /dev/.asb/governor.pid 2>/dev/null)"
  [ -n "$_gpid" ] && kill -0 "$_gpid" 2>/dev/null
}

asb_governor_start() {
  [ -x "$ASB_GOV" ] || return 1
  asb_governor_running && return 0
  mkdir -p /dev/.asb
  nice -n 10 "$ASB_GOV" >/dev/null 2>&1 &
  sleep 0.3
  asb_governor_running || return 1
  ASB_GOV_ENABLED=1
  asb_log "governor started (pid=$(cat /dev/.asb/governor.pid 2>/dev/null))"
  return 0
}

asb_governor_set_profile() {
  [ "$ASB_GOV_ENABLED" -eq 1 ] || return 0
  asb_governor_running || return 0
  "$ASB_GOV" "profile:$ASB_PROFILE" >/dev/null 2>&1 || true
}

if asb_feature_enabled CPU && [ -x "$ASB_GOV" ]; then
  asb_governor_start && ASB_GOV_ENABLED=1
fi

# ASB:CPU:BEGIN
KREL="$(uname -r 2>/dev/null)"
IS_WILD=0
echo "$KREL" | grep -qi "wild" && IS_WILD=1
cpu_present="$(cat /sys/devices/system/cpu/present 2>/dev/null | tr -d '\n')"
cpu_max="7"
case "$cpu_present" in
  *-*) cpu_max="${cpu_present##*-}" ;;
  *) cpu_max="$cpu_present" ;;
esac
[ -n "$cpu_max" ] || cpu_max="7"
N=$((cpu_max + 1))
_ref_freq="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)"
_big_start="$N"
if [ -n "$_ref_freq" ]; then
  _i=1
  while [ $_i -le $cpu_max ]; do
    _f="$(cat /sys/devices/system/cpu/cpu${_i}/cpufreq/cpuinfo_max_freq 2>/dev/null)"
    if [ -n "$_f" ] && [ "$_f" != "$_ref_freq" ]; then
      _big_start=$_i
      break
    fi
    _i=$((_i + 1))
  done
fi
[ "$_big_start" -ge "$N" ] && _big_start=$((N / 2))
[ "$_big_start" -lt 2 ] && _big_start=2
little_end=$((_big_start - 1))
LITTLE_POLICY="/sys/devices/system/cpu/cpufreq/policy0"
BIG_POLICY="/sys/devices/system/cpu/cpufreq/policy${_big_start}"
[ -d "$BIG_POLICY" ] || BIG_POLICY="$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null | sort -t'y' -k2 -n | tail -1)"
[ -d "$BIG_POLICY" ] || BIG_POLICY="$LITTLE_POLICY"
apply_cpuset_groups() {
  writef_retry /dev/cpuset/background/cpus        "0-${little_end}" 3 0.25 || true
  writef_retry /dev/cpuset/system-background/cpus "0-${little_end}" 3 0.25 || true
  if [ "$ASB_PROFILE" = "battery" ]; then
    writef_retry /dev/cpuset/foreground/cpus      "0-${little_end}" 3 0.25 || true
    writef_retry /dev/cpuset/top-app/cpus         "0-${little_end}" 3 0.25 || true
  else
    writef_retry /dev/cpuset/foreground/cpus      "0-${cpu_max}" 3 0.25 || true
    writef_retry /dev/cpuset/top-app/cpus         "0-${cpu_max}" 3 0.25 || true
  fi
}
apply_cpuset_groups_all() {
  for _cg_root in /dev/cpuset /sys/fs/cgroup; do
    [ -d "$_cg_root" ] || continue
    _bg="0-${little_end}"
    _fg="0-${cpu_max}"
    if [ "$ASB_PROFILE" = "battery" ]; then
      _fg="0-${little_end}"
    fi
    for _grp in background system-background; do
      [ -e "$_cg_root/$_grp/cpus" ] && writef_retry "$_cg_root/$_grp/cpus" "$_bg" 5 0.3 || true
      [ -e "$_cg_root/$_grp/cpuset.cpus" ] && writef_retry "$_cg_root/$_grp/cpuset.cpus" "$_bg" 5 0.3 || true
    done
    for _grp in foreground top-app; do
      [ -e "$_cg_root/$_grp/cpus" ] && writef_retry "$_cg_root/$_grp/cpus" "$_fg" 5 0.3 || true
      [ -e "$_cg_root/$_grp/cpuset.cpus" ] && writef_retry "$_cg_root/$_grp/cpuset.cpus" "$_fg" 5 0.3 || true
    done
  done
}
apply_uclamp() {
  writef_retry /dev/cpuctl/top-app/uclamp.latency_sensitive $_P_LATENCY_SENSITIVE 5 0.3 || true
  writef_retry /dev/cpuctl/background/cpu.uclamp.min        $_P_UCL_BG  5 0.3 || true
  writef_retry /dev/cpuctl/system-background/cpu.uclamp.min $_P_UCL_BG  5 0.3 || true
  writef_retry /dev/cpuctl/foreground/cpu.uclamp.min        $_P_UCL_FG 5 0.3 || true
  writef_retry /dev/cpuctl/top-app/cpu.uclamp.min           $_P_UCL_TOP 5 0.3 || true
  _ucl_bg_max="${UCL_BG_MAX:-40}"
  _ucl_fg_max="${UCL_FG_MAX:-70}"
  _ucl_top_max="${UCL_TOP_MAX:-85}"
  writef_retry /dev/cpuctl/background/cpu.uclamp.max        $_ucl_bg_max 5 0.3 || true
  writef_retry /dev/cpuctl/system-background/cpu.uclamp.max $_ucl_bg_max 5 0.3 || true
  writef_retry /dev/cpuctl/foreground/cpu.uclamp.max        $_ucl_fg_max 5 0.3 || true
  writef_retry /dev/cpuctl/top-app/cpu.uclamp.max           $_ucl_top_max 5 0.3 || true
  writef_retry /dev/cpuctl/background/uclamp.min        $_P_UCL_BG  5 0.3 || true
  writef_retry /dev/cpuctl/system-background/uclamp.min $_P_UCL_BG  5 0.3 || true
  writef_retry /dev/cpuctl/foreground/uclamp.min        $_P_UCL_FG 5 0.3 || true
  writef_retry /dev/cpuctl/top-app/uclamp.min           $_P_UCL_TOP 5 0.3 || true
  for _cg_root in /sys/fs/cgroup /dev/cgroup; do
    [ -d "$_cg_root" ] || continue
    for _tier in background system-background foreground top-app; do
      _uval=$_P_UCL_BG
      [ "$_tier" = "foreground" ] && _uval=$_P_UCL_FG
      [ "$_tier" = "top-app" ]    && _uval=$_P_UCL_TOP
      _node="$_cg_root/$_tier/cpu.uclamp.min"
      [ -f "$_node" ] && writef_retry "$_node" "$_uval" 5 0.3 || true
      _mnode="$_cg_root/$_tier/cpu.uclamp.max"
      _mval=$_ucl_bg_max
      [ "$_tier" = "foreground" ] && _mval=$_ucl_fg_max
      [ "$_tier" = "top-app" ] && _mval=$_ucl_top_max
      [ -f "$_mnode" ] && writef_retry "$_mnode" "$_mval" 5 0.3 || true
    done
    _lat="$_cg_root/top-app/cpu.uclamp.latency_sensitive"
    [ -f "$_lat" ] && writef_retry "$_lat" $_P_LATENCY_SENSITIVE 5 0.3 || true
  done
  [ -w /proc/sys/kernel/sched_util_clamp_min ] && \
    writef_retry /proc/sys/kernel/sched_util_clamp_min 0 5 0.3 || true
}
wait_path /dev/cpuset/background/cpus 8 || true
wait_path /dev/cpuctl/top-app 8 || true
asb_feature_enabled CPU && apply_uclamp
if asb_feature_enabled CPU; then
  apply_cpuset_groups
  apply_cpuset_groups_all
fi
apply_cpugov_hints() {
  _rate="${SCHED_RATE:-3000}"
  _up_rate="${SCHED_UP_RATE:-1200}"
  _down_rate="${SCHED_DOWN_RATE:-4000}"
  _hispeed="${SCHED_HISPEED_LOAD:-88}"
  for _pol in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol" ] || continue
    [ -w "$_pol/schedutil/rate_limit_us" ] && writef_retry "$_pol/schedutil/rate_limit_us" "$_rate" 3 0.2 || true
    [ -w "$_pol/schedutil/up_rate_limit_us" ] && writef_retry "$_pol/schedutil/up_rate_limit_us" "$_up_rate" 3 0.2 || true
    [ -w "$_pol/schedutil/down_rate_limit_us" ] && writef_retry "$_pol/schedutil/down_rate_limit_us" "$_down_rate" 3 0.2 || true
    [ -w "$_pol/schedutil/hispeed_load" ] && writef_retry "$_pol/schedutil/hispeed_load" "$_hispeed" 3 0.2 || true
    [ -w "$_pol/schedutil/hispeed_freq" ] && [ -n "$SCHED_HISPEED_FREQ" ] && writef_retry "$_pol/schedutil/hispeed_freq" "$SCHED_HISPEED_FREQ" 3 0.2 || true
  done
}
asb_feature_enabled CPU && apply_cpugov_hints
# ASB:CPU:END
if has pm; then
  pm disable-user --user 0 com.android.traceur >/dev/null 2>&1 || true
fi
# ASB:VM:BEGIN
apply_vm() {
  sysctlw vm.swappiness $_P_SWAP
  if [ -e /proc/sys/vm/dirty_bytes ] && [ -e /proc/sys/vm/dirty_background_bytes ]; then
    sysctlw vm.dirty_ratio 0
    sysctlw vm.dirty_background_ratio 0
    case "$ASB_PROFILE" in
      performance)
        sysctlw vm.dirty_bytes 33554432
        sysctlw vm.dirty_background_bytes 8388608 ;;
      battery)
        sysctlw vm.dirty_bytes 134217728
        sysctlw vm.dirty_background_bytes 33554432 ;;
      *)
        sysctlw vm.dirty_bytes 67108864
        sysctlw vm.dirty_background_bytes 16777216 ;;
    esac
  else
    case "$ASB_PROFILE" in
      performance) sysctlw vm.dirty_ratio 5; sysctlw vm.dirty_background_ratio 2 ;;
      battery) sysctlw vm.dirty_ratio 40; sysctlw vm.dirty_background_ratio 10 ;;
      *) sysctlw vm.dirty_ratio 20; sysctlw vm.dirty_background_ratio 5 ;;
    esac
  fi
  sysctlw vm.dirty_expire_centisecs $_P_DEXP
  sysctlw vm.dirty_writeback_centisecs $_P_DWB
  sysctlw vm.vfs_cache_pressure $_P_VFS
  [ -e /proc/sys/vm/compaction_proactiveness ] && sysctlw vm.compaction_proactiveness 0
  [ -e /proc/sys/vm/stat_interval ] && sysctlw vm.stat_interval $_P_STATINT
  case "$ASB_PROFILE" in
    performance) writef_retry /proc/sys/vm/page-cluster 0 1 0 || true ;;
    battery) writef_retry /proc/sys/vm/page-cluster 3 1 0 || true ;;
    *) writef_retry /proc/sys/vm/page-cluster 1 1 0 || true ;;
  esac
  sysctlw vm.watermark_scale_factor $_P_WMARK
  sysctlw vm.min_free_kbytes $_P_MINFREE
  sysctlw vm.oom_kill_allocating_task 1
  if [ "$ASB_PROFILE" = "battery" ]; then
    [ -e /proc/sys/vm/drop_caches ] || true
    [ -e /proc/sys/vm/laptop_mode ] && sysctlw vm.laptop_mode 1 || true
    [ -e /proc/sys/vm/block_dump ] && writef_retry /proc/sys/vm/block_dump 0 1 0 || true
  else
    [ -e /proc/sys/vm/laptop_mode ] && sysctlw vm.laptop_mode 0 || true
  fi
}
asb_feature_enabled VM && apply_vm
# ASB:VM:END
sysctl_try() {
  k="$1"; shift
  p="/proc/sys/$(echo "$k" | tr . /)"
  avail=""
  if [ "$k" = "net.ipv4.tcp_congestion_control" ] && [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
    avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
  fi
  for v in "$@"; do
    if [ -n "$avail" ]; then
      echo "$avail" | grep -qw "$v" || continue
    fi
    if has sysctl; then
      sysctl -w "${k}=${v}" >/dev/null 2>&1 && return 0
    fi
    [ -e "$p" ] || return 0
    echo "$v" > "$p" 2>/dev/null && return 0
  done
  return 0
}
# ASB:NET:BEGIN
apply_net() {
  sysctl_try net.core.default_qdisc fq_codel fq pfifo_fast
  if [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
    _cc_avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
    if echo "$_cc_avail" | grep -qw bbr; then
      sysctlw net.ipv4.tcp_congestion_control bbr
      [ -e /proc/sys/net/ipv6/tcp_congestion_control ] && sysctlw net.ipv6.tcp_congestion_control bbr
    elif echo "$_cc_avail" | grep -qw cubic; then
      sysctlw net.ipv4.tcp_congestion_control cubic
      [ -e /proc/sys/net/ipv6/tcp_congestion_control ] && sysctlw net.ipv6.tcp_congestion_control cubic
    else
      :
    fi
  else
    sysctl_try net.ipv4.tcp_congestion_control bbr cubic reno
    [ -e /proc/sys/net/ipv6/tcp_congestion_control ] && sysctl_try net.ipv6.tcp_congestion_control bbr cubic reno
  fi
  case "$ASB_PROFILE" in
    performance) _pca=160; _pss=240 ;;
    battery)     _pca=80;  _pss=110 ;;
    *)           _pca=110; _pss=170 ;;
  esac
  sysctlw net.ipv4.tcp_pacing_ca_ratio $_pca
  sysctlw net.ipv4.tcp_pacing_ss_ratio $_pss
  [ -e /proc/sys/net/ipv6/tcp_ecn ] && sysctlw net.ipv6.tcp_ecn 0
  [ -e /proc/sys/net/ipv6/tcp_rmem ] && sysctlw net.ipv6.tcp_rmem "$_P_TCP_RMEM"
  [ -e /proc/sys/net/ipv6/tcp_wmem ] && sysctlw net.ipv6.tcp_wmem "$_P_TCP_WMEM"
  sysctlw net.ipv4.tcp_moderate_rcvbuf 1
  sysctlw net.ipv4.tcp_rmem "$_P_TCP_RMEM"
  sysctlw net.ipv4.tcp_wmem "$_P_TCP_WMEM"
  sysctlw net.core.rmem_max "$NET_RMEM_MAX"
  sysctlw net.core.wmem_max "$NET_WMEM_MAX"
  sysctlw net.core.optmem_max "$NET_OPTMEM_MAX"
  sysctlw net.ipv4.tcp_fastopen $_P_TCP_FASTOPEN
  sysctlw net.ipv4.tcp_sack 1
  sysctlw net.ipv4.tcp_dsack 1
  sysctlw net.ipv4.tcp_window_scaling 1
  sysctlw net.ipv4.tcp_timestamps 1
  sysctlw net.ipv4.tcp_ecn 0
  sysctlw net.ipv4.tcp_early_retrans 3
  [ -e /proc/sys/net/ipv4/tcp_notsent_lowat ] && sysctlw net.ipv4.tcp_notsent_lowat $_P_TCP_NOTSENT
  sysctlw net.ipv4.udp_rmem_min 65536
  sysctlw net.ipv4.udp_wmem_min 65536
  [ -e /proc/sys/net/ipv6/udp_rmem_min ] && sysctlw net.ipv6.udp_rmem_min 65536
  [ -e /proc/sys/net/ipv6/udp_wmem_min ] && sysctlw net.ipv6.udp_wmem_min 65536
  sysctlw net.ipv4.tcp_mtu_probing 1
  sysctlw net.ipv4.tcp_slow_start_after_idle 0
  sysctlw net.ipv4.tcp_recovery 1
  sysctlw net.ipv4.tcp_retrans_collapse 0
  sysctlw net.ipv4.tcp_max_orphans 8192
  sysctlw net.ipv4.tcp_keepalive_time   $_P_TCP_KEEPIDLE
  sysctlw net.ipv4.tcp_keepalive_intvl  75
  sysctlw net.ipv4.tcp_keepalive_probes 9
  sysctlw net.ipv4.tcp_fin_timeout          $_P_TCP_FIN
  sysctlw net.ipv4.tcp_no_metrics_save 1
  sysctlw net.core.somaxconn 512
  sysctlw net.ipv4.tcp_max_syn_backlog 2048
  sysctlw net.core.netdev_max_backlog $_P_NET_BACKLOG
  sysctlw net.core.netdev_budget $_P_NET_BUDGET
  sysctlw net.core.netdev_budget_usecs $_P_NET_BUDGET_US
  sysctlw net.core.dev_weight $_P_DEV_WEIGHT
  sysctlw net.core.bpf_jit_enable 1
  sysctlw net.core.bpf_jit_harden 0
  sysctlw net.core.bpf_jit_kallsyms 1
  [ -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established ] && \
  sysctlw net.netfilter.nf_conntrack_tcp_timeout_established 600
  [ -e /proc/sys/net/netfilter/nf_conntrack_buckets ] && \
  sysctlw net.netfilter.nf_conntrack_buckets 16384
  [ -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait ] && \
  sysctlw net.netfilter.nf_conntrack_tcp_timeout_time_wait 30
  sysctlw net.ipv4.tcp_syncookies 1
  sysctlw net.ipv4.tcp_rfc1337 1
  sysctlw net.ipv4.conf.all.rp_filter 0
  sysctlw net.ipv4.conf.default.rp_filter 0
  sysctlw net.ipv4.ip_nonlocal_bind 1
  [ -e /proc/sys/net/ipv6/ip_nonlocal_bind ] && sysctlw net.ipv6.ip_nonlocal_bind 1
  sysctlw net.ipv4.conf.all.accept_redirects 0
  sysctlw net.ipv4.conf.all.send_redirects 0
  sysctlw net.ipv4.conf.all.secure_redirects 0
  sysctlw net.ipv4.icmp_echo_ignore_broadcasts 1
  sysctlw net.ipv4.icmp_ignore_bogus_error_responses 1
  [ -e /proc/sys/net/ipv6/conf/all/accept_redirects ] && \
    sysctlw net.ipv6.conf.all.accept_redirects 0
  [ -e /proc/sys/net/ipv6/conf/all/accept_ra ] && \
    sysctlw net.ipv6.conf.all.accept_ra 2
  [ -e /proc/sys/net/ipv6/conf/all/accept_ra_mtu ] && \
    sysctlw net.ipv6.conf.all.accept_ra_mtu 1
  [ -e /proc/sys/net/ipv6/conf/default/accept_ra_mtu ] && \
    sysctlw net.ipv6.conf.default.accept_ra_mtu 1
  [ -e /proc/sys/net/ipv6/conf/all/use_tempaddr ] && \
    sysctlw net.ipv6.conf.all.use_tempaddr 2
  [ -e /proc/sys/net/ipv6/conf/default/use_tempaddr ] && \
    sysctlw net.ipv6.conf.default.use_tempaddr 2
  [ -e /proc/sys/net/ipv6/icmp/echo_ignore_anycast ] && \
    sysctlw net.ipv6.icmp.echo_ignore_anycast 1
  [ -e /proc/sys/net/ipv6/icmp/echo_ignore_multicast ] && \
    sysctlw net.ipv6.icmp.echo_ignore_multicast 1
  [ -e /proc/sys/net/ipv6/conf/all/proxy_ndp ] && \
    sysctlw net.ipv6.conf.all.proxy_ndp 1
  sysctlw net.ipv4.conf.all.accept_source_route 0
  [ -e /proc/sys/net/ipv6/conf/all/accept_source_route ] && \
    sysctlw net.ipv6.conf.all.accept_source_route 0
  sysctlw net.ipv4.neigh.default.gc_thresh1 128
  sysctlw net.ipv4.neigh.default.gc_thresh2 512
  sysctlw net.ipv4.neigh.default.gc_thresh3 1024
  [ -e /proc/sys/net/ipv6/neigh/default/gc_thresh1 ] && \
    sysctlw net.ipv6.neigh.default.gc_thresh1 128
  [ -e /proc/sys/net/ipv6/neigh/default/gc_thresh2 ] && \
    sysctlw net.ipv6.neigh.default.gc_thresh2 512
  [ -e /proc/sys/net/ipv6/neigh/default/gc_thresh3 ] && \
    sysctlw net.ipv6.neigh.default.gc_thresh3 1024
}
asb_feature_enabled NET && apply_net
# ASB:NET:END
apply_wifi_settings() {
  has settings || return 0
  settings put global nearby_scanning_enabled 0 >/dev/null 2>&1 || true
  settings put global wifi_scan_throttle_enabled 1 >/dev/null 2>&1 || true
  settings put global wifi_suspend_optimizations_enabled 1 >/dev/null 2>&1 || true
  settings put global wifi_verbose_logging_enabled 0 >/dev/null 2>&1 || true
}
asb_feature_enabled WIFI && apply_wifi_settings
apply_wifi_country() {
  _cc="${WIFI_COUNTRY:-IT}"
  has iw && iw reg set "$_cc" >/dev/null 2>&1 || true
  has cmd && {
    cmd -w wifi force-country-code enabled "$_cc" >/dev/null 2>&1 || true
    cmd -w wifi set-country-code "$_cc" >/dev/null 2>&1 || true
  }
  has settings && {
    settings put global wifi_country_code "$_cc" >/dev/null 2>&1 || true
    settings put global wifi_country_code_priority 1 >/dev/null 2>&1 || true
  }
}
asb_feature_enabled WIFI && apply_wifi_country
apply_wlan0_txqlen() {
  [ -e /sys/class/net/wlan0/tx_queue_len ] || return 0
  _want="${_P_WLAN_TXQLEN:-768}"
  _txq="$(cat /sys/class/net/wlan0/tx_queue_len 2>/dev/null)"
  [ "$_txq" = "$_want" ] && return 0
  echo $_want > /sys/class/net/wlan0/tx_queue_len 2>/dev/null || true
  ip link set wlan0 txqueuelen $_want >/dev/null 2>&1 || true
}
asb_feature_enabled WIFI && apply_wlan0_txqlen
netif_oper_upish() {
  _if="$1"
  [ -n "$_if" ] || return 1
  [ -r "/sys/class/net/$_if/operstate" ] || return 0
  _st="$(cat "/sys/class/net/$_if/operstate" 2>/dev/null)"
  case "$_st" in
    up|dormant|unknown) return 0 ;;
  esac
  return 1
}
netif_carrier_upish() {
  _if="$1"
  [ -n "$_if" ] || return 0
  [ -r "/sys/class/net/$_if/carrier" ] || return 0
  [ "$(cat "/sys/class/net/$_if/carrier" 2>/dev/null)" = "1" ]
}
netif_qdisc_kind() {
  _if="$1"
  has tc || return 1
  [ -n "$_if" ] || return 1
  tc qdisc show dev "$_if" 2>/dev/null | awk 'NR==1{print $2}'
}
apply_netif_qdisc() {
  _if="$1"
  has tc || return 0
  [ -n "$_if" ] || return 0
  ip link show "$_if" >/dev/null 2>&1 || return 0
  netif_oper_upish "$_if" || return 0
  netif_carrier_upish "$_if" || return 0
  _qk="$(netif_qdisc_kind "$_if")"
  case "$_qk" in
    fq_codel|fq) return 0 ;;
    mq)
      tc qdisc show dev "$_if" 2>/dev/null | while read -r line; do
        _parent="$(echo "$line" | grep -oE 'parent [0-9a-f]+:[0-9a-f]+' | awk '{print $2}')"
        [ -n "$_parent" ] || continue
        tc qdisc replace dev "$_if" parent "$_parent" fq_codel >/dev/null 2>&1 || true
      done
      return 0
      ;;
  esac
  tc qdisc replace dev "$_if" root fq_codel >/dev/null 2>&1 || \
    tc qdisc replace dev "$_if" root fq >/dev/null 2>&1 || true
}
apply_wlan0_qdisc() {
  if has tc && ip link show wlan0 >/dev/null 2>&1; then
    if [ "$ASB_PROFILE" = "performance" ]; then
      tc qdisc replace dev wlan0 root $_P_QDISC >/dev/null 2>&1 || apply_netif_qdisc wlan0
    else
      tc qdisc replace dev wlan0 root $_P_QDISC >/dev/null 2>&1 || apply_netif_qdisc wlan0
    fi
  fi
}
apply_mobile_qdisc() {
  for _dev in /sys/class/net/*; do
    [ -e "$_dev" ] || continue
    _if="${_dev##*/}"
    case "$_if" in
      rmnet*|ccmni*)
        if has tc; then
          tc qdisc replace dev "$_if" root "$_P_QDISC" >/dev/null 2>&1 || apply_netif_qdisc "$_if"
        else
          apply_netif_qdisc "$_if"
        fi ;;

    esac
  done
}
asb_feature_enabled WIFI && apply_wlan0_qdisc
asb_feature_enabled NET && apply_mobile_qdisc
# ASB:WIFI:BEGIN
apply_wifi_pm() {
  wait_path /sys/class/net/wlan0 10 || return 0
  _wt=0
  while [ $_wt -lt 15 ]; do
    _wst="$(cat /sys/class/net/wlan0/operstate 2>/dev/null)"
    case "$_wst" in up|dormant|unknown) break ;; esac
    sleep 1
    _wt=$((_wt+1))
  done
  case "$_P_WLAN_PM" in
    0)
      iw dev wlan0 set power_save off >/dev/null 2>&1 || true
      sleep 0.5
      iw dev wlan0 set power_save off >/dev/null 2>&1 || true
      writef_retry /sys/module/wlan/parameters/wlan_pm 0 4 0.5 || true
      setprop persist.vendor.wlan.scan_throttle 0 2>/dev/null || true
      setprop persist.vendor.wlan.powersave 0 2>/dev/null || true
      [ -e /sys/module/wlan/parameters/wlan_pm ] && writef_retry /sys/module/wlan/parameters/wlan_pm 0 6 0.5 || true
      ;;
    1)
      iw dev wlan0 set power_save on >/dev/null 2>&1 || true
      sleep 0.5
      iw dev wlan0 set power_save on >/dev/null 2>&1 || true
      writef_retry /sys/module/wlan/parameters/wlan_pm 1 4 0.5 || true
      setprop persist.vendor.wlan.scan_throttle 1 2>/dev/null || true
      setprop persist.vendor.wlan.powersave 1 2>/dev/null || true
      [ -e /sys/module/wlan/parameters/wlan_pm ] && writef_retry /sys/module/wlan/parameters/wlan_pm 1 6 0.5 || true
      ;;
    *)
      iw dev wlan0 set power_save on >/dev/null 2>&1 || true
      writef_retry /sys/module/wlan/parameters/wlan_pm 1 3 0.25 || true
      setprop persist.vendor.wlan.scan_throttle 1 2>/dev/null || true
      ;;
  esac
}
asb_feature_enabled WIFI && apply_wifi_pm
apply_wifi_dtim() {
  asb_has_risky_vendor_stack && return 0
  case "$ASB_PROFILE" in
    battery) iw dev wlan0 set listen-interval 10 >/dev/null 2>&1 || true ;;
    performance) iw dev wlan0 set listen-interval 1 >/dev/null 2>&1 || true ;;
    *) iw dev wlan0 set listen-interval 3 >/dev/null 2>&1 || true ;;
  esac
  writef_retry /sys/module/wlan/parameters/enable_connected_scan_result 0 3 0.25 || true
}
asb_feature_enabled WIFI && apply_wifi_dtim
# ASB:WIFI:END
(
  _skip_wlan_wait=0
  if has settings; then
    _wifi_on="$(settings get global wifi_on 2>/dev/null)"
    case "$_wifi_on" in
      0|disabled|false) _skip_wlan_wait=1 ;;
    esac
  fi
  t=0
  while [ $_skip_wlan_wait -eq 0 ] && [ $t -lt 120 ]; do
    [ -r /sys/class/net/wlan0/operstate ] || { sleep 2; t=$((t+2)); continue; }
    st="$(cat /sys/class/net/wlan0/operstate 2>/dev/null)"
    case "$st" in
      up|dormant) break ;;
    esac
    sleep 2
    t=$((t+2))
  done
  for delay in 0 15; do
    [ $delay -gt 0 ] && sleep $delay
    asb_feature_enabled WIFI && apply_wlan0_txqlen
    asb_feature_enabled WIFI && apply_wlan0_qdisc
    q="$(cat /sys/class/net/wlan0/tx_queue_len 2>/dev/null)"
    [ "$q" = "${_P_WLAN_TXQLEN:-1024}" ] && break
  done
) >/dev/null 2>&1 &
# ASB:GPS:BEGIN
apply_gps_hygiene() {
  has settings || return 0
  [ "$(settings get global assisted_gps_enabled 2>/dev/null)" = "1" ] && return 0
  settings put global assisted_gps_enabled 1 >/dev/null 2>&1 || true
  settings put global gps_xtra_server "http://xtrapath4.izatcloud.net/xtra3grcej.bin" >/dev/null 2>&1 || true
  settings put global gps_xtra_server_1 "http://xtrapath1.izatcloud.net/xtra3grcej.bin" >/dev/null 2>&1 || true
  settings put global gps_xtra_server_2 "http://xtrapath2.izatcloud.net/xtra3grcej.bin" >/dev/null 2>&1 || true
  settings put global ntp_server time.google.com >/dev/null 2>&1 || true
  settings put global ntp_server_2 0.it.pool.ntp.org >/dev/null 2>&1 || true
  settings put global ntp_server_3 1.it.pool.ntp.org >/dev/null 2>&1 || true
  settings put global ntp_server_4 ntp1.inrim.it >/dev/null 2>&1 || true
}
asb_feature_enabled GPS && apply_gps_hygiene
# ASB:GPS:END
tune_io_queues() {
  for _b in /sys/block/sd* /sys/block/mmcblk* /sys/block/dm-*; do
    [ -d "$_b/queue" ] || continue
    [ -r "$_b/queue/rotational" ] && [ "$(cat "$_b/queue/rotational" 2>/dev/null)" = "1" ] && continue
    writef "$_b/queue/iostats" 0
    writef "$_b/queue/add_random" 0
    writef "$_b/queue/rq_affinity" 2
    case "$ASB_PROFILE" in
      performance)
        writef "$_b/queue/read_ahead_kb" 512
        [ -w "$_b/queue/nr_requests" ] && writef "$_b/queue/nr_requests" 256 || true ;;
      battery)
        writef "$_b/queue/read_ahead_kb" 64
        [ -w "$_b/queue/nr_requests" ] && writef "$_b/queue/nr_requests" 64 || true ;;
      *)
        writef "$_b/queue/read_ahead_kb" 128
        [ -w "$_b/queue/nr_requests" ] && writef "$_b/queue/nr_requests" 128 || true ;;
    esac
  done
}
# ASB:KERNEL:BEGIN
apply_kernel() {
  sysctlw kernel.perf_cpu_time_max_percent 2
  sysctlw kernel.sched_schedstats 0
  sysctlw kernel.timer_migration 0
  sysctlw kernel.panic 0
  sysctlw kernel.panic_on_oops 0
  sysctlw vm.panic_on_oom 0
  [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4
  writef_retry /proc/sys/kernel/printk_devkmsg off 1 0 || true
  writef_retry /proc/sys/kernel/printk "0 0 0 0" 1 0 || true
  [ -e /proc/sys/kernel/printk_ratelimit ] && \
    sysctlw kernel.printk_ratelimit 1
  [ -e /proc/sys/kernel/printk_ratelimit_burst ] && \
    sysctlw kernel.printk_ratelimit_burst 5
  [ -e /proc/sys/vm/oom_dump_tasks ] && sysctlw vm.oom_dump_tasks 0
  [ -e /proc/sys/debug/exception-trace ] && \
    writef_retry /proc/sys/debug/exception-trace 0 1 0 || true
  [ -e /proc/sys/walt/sched_boost ] && \
    writef_retry /proc/sys/walt/sched_boost 0 1 0 || true
  [ -e /proc/sys/walt/sched_idle_enough ] && \
    writef_retry /proc/sys/walt/sched_idle_enough $_P_IDLE 1 0 || true
  [ -e /proc/sys/walt/sched_idle_enough_clust ] && \
    writef_retry /proc/sys/walt/sched_idle_enough_clust "$_P_IDLEC" 1 0 || true
  writef_retry /proc/sys/kernel/sched_util_clamp_min 0 3 0.25 || true
  [ -w $LITTLE_POLICY/scaling_min_freq ] && writef_retry $LITTLE_POLICY/scaling_min_freq $_P_CPUL 3 0.25 || true
  [ -w $BIG_POLICY/scaling_min_freq ] && writef_retry $BIG_POLICY/scaling_min_freq $_P_CPUB 3 0.25 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct $_P_CLUT 1 0 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct_clust ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct_clust "$_P_CLUTC" 1 0 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_colocation ] && writef_retry /proc/sys/walt/sched_min_task_util_for_colocation $_P_COLOC 1 0 || true
  [ -e /proc/sys/walt/sched_busy_hyst_ns ] && writef_retry /proc/sys/walt/sched_busy_hyst_ns $_P_BHYST 1 0 || true
  [ -e /proc/sys/walt/sched_boost ] && writef_retry /proc/sys/walt/sched_boost $_P_SBOOST 1 0 || true
  [ -e /proc/sys/walt/sched_ravg_window_nr_ticks ] && writef_retry /proc/sys/walt/sched_ravg_window_nr_ticks $_P_RAVG 3 0.5 || true
  [ -e /proc/sys/walt/sched_pipeline_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_util_thres $_P_PIPE 1 0 || true
  [ -e /proc/sys/walt/sched_pipeline_non_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_non_special_task_util_thres $_P_PIPEN 1 0 || true
  [ -e /proc/sys/walt/sched_pipeline_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_special_task_util_thres $_P_PIPES 1 0 || true
  [ -e /proc/sys/walt/sched_ed_boost ] && writef_retry /proc/sys/walt/sched_ed_boost $_P_EDB 1 0 || true
  [ -e /proc/sys/walt/sched_topapp_weight_pct ] && writef_retry /proc/sys/walt/sched_topapp_weight_pct $_P_TOPW 1 0 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_boost ] && writef_retry /proc/sys/walt/sched_min_task_util_for_boost $_P_MINTB 1 0 || true
  case "$ASB_PROFILE" in
    battery)
      [ -e /proc/sys/kernel/sched_energy_aware ] && sysctlw kernel.sched_energy_aware 1 || true
      [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 2 || true
      [ -e /proc/sys/kernel/hrtimer_migration ] && writef_retry /proc/sys/kernel/hrtimer_migration 0 1 0 || true
      [ -e /proc/sys/kernel/timer_migration ] && sysctlw kernel.timer_migration 0 || true
      [ -e /proc/sys/walt/sched_conservative_pl ] && writef_retry /proc/sys/walt/sched_conservative_pl 1 1 0 || true
      [ -e /proc/sys/walt/sched_suppress_region2_cpus ] && writef_retry /proc/sys/walt/sched_suppress_region2_cpus 1 1 0 || true
      writef /sys/module/lpm_levels/parameters/sleep_disabled 0 || true
      [ -e /sys/module/lpm_levels/parameters/lpm_prediction ] &&         writef /sys/module/lpm_levels/parameters/lpm_prediction 1 || true
      ;;
    performance)
      [ -e /proc/sys/kernel/sched_energy_aware ] && sysctlw kernel.sched_energy_aware 0 || true
      [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 8 || true
      [ -e /proc/sys/walt/sched_conservative_pl ] && writef_retry /proc/sys/walt/sched_conservative_pl 0 1 0 || true
      [ -e /proc/sys/walt/sched_suppress_region2_cpus ] && writef_retry /proc/sys/walt/sched_suppress_region2_cpus 0 1 0 || true
      ;;
    *)
      [ -e /proc/sys/kernel/sched_energy_aware ] && sysctlw kernel.sched_energy_aware 1 || true
      [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4 || true
      ;;
  esac
  tune_io_queues
}
asb_feature_enabled KERNEL && apply_kernel
# ASB:KERNEL:END
asb_freq_pick_pct() {
  _dir="$1"; _pct="$2"
  [ -d "$_dir" ] || return 1
  _max="$(cat "$_dir/cpuinfo_max_freq" 2>/dev/null)"
  [ -n "$_max" ] || return 1
  _target=$(( _max * _pct / 100 ))
  _avail="$_dir/scaling_available_frequencies"
  if [ -r "$_avail" ]; then
    _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | awk -v t="$_target" '$1<=t{v=$1} END{print v}')"
    [ -n "$_pick" ] || _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | head -1)"
  else
    _pick="$_target"
  fi
  [ -n "$_pick" ] && echo "$_pick"
}
asb_gpu_pick_pct() {
  _base="/sys/class/kgsl/kgsl-3d0/devfreq"
  [ -d "$_base" ] || return 1
  _max="$(cat "$_base/max_freq" 2>/dev/null)"
  [ -n "$_max" ] || return 1
  _target=$(( _max * $1 / 100 ))
  _avail="$_base/available_frequencies"
  if [ -r "$_avail" ]; then
    _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | awk -v t="$_target" '$1<=t{v=$1} END{print v}')"
    [ -n "$_pick" ] || _pick="$(tr ' ' '
' < "$_avail" | grep -v '^$' | sort -n | head -1)"
  else
    _pick="$_target"
  fi
  [ -n "$_pick" ] && echo "$_pick"
}
apply_gpu_caps() {
  _gbase="/sys/class/kgsl/kgsl-3d0/devfreq"
  [ -d "$_gbase" ] || return 0
  _gmax="$(asb_gpu_pick_pct ${_P_GPU_MAX_PCT:-100})"
  [ -n "$_gmax" ] && writef_retry "$_gbase/max_freq" "$_gmax" 3 0.25 || true
  if [ "${_P_GPU_MIN_PCT:-0}" -gt 0 ] 2>/dev/null; then
    _gmin="$(asb_gpu_pick_pct ${_P_GPU_MIN_PCT})"
  else
    _gmin="$(cat "$_gbase/available_frequencies" 2>/dev/null | tr ' ' '
' | grep -v '^$' | sort -n | head -1)"
    [ -n "$_gmin" ] || _gmin="$(cat "$_gbase/min_freq" 2>/dev/null)"
  fi
  [ -n "$_gmin" ] && writef_retry "$_gbase/min_freq" "$_gmin" 3 0.25 || true
}
apply_cpufreq_caps() {
  for _pol_dir in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol_dir" ] || continue
    _smax="$_pol_dir/scaling_max_freq"
    [ -w "$_smax" ] || continue
    _rel="$(cat "$_pol_dir/related_cpus" 2>/dev/null | awk '{print $1}')"
    case "$_rel" in ''|*[!0-9]*) _rel=0 ;; esac
    if [ "$_rel" -le "$little_end" ]; then
      _pct="$_P_CPUCAP_L"
    else
      _pct="$_P_CPUCAP_B"
    fi
    if [ "$_rel" -le "$little_end" ]; then
      _abs="$_P_CPU_MAXL"
    else
      _abs="$_P_CPU_MAXB"
    fi
    if [ -n "$_abs" ]; then
      _want="$_abs"
    elif [ "$_pct" -ge 100 ] 2>/dev/null; then
      _want="$(cat "$_pol_dir/cpuinfo_max_freq" 2>/dev/null)"
    else
      _want="$(asb_freq_pick_pct "$_pol_dir" "$_pct")"
    fi
    [ -n "$_want" ] && writef_retry "$_smax" "$_want" 3 0.25 || true
  done
}
asb_feature_enabled CPU && apply_cpufreq_caps

asb_screen_on() {
  for _dp in /sys/kernel/oplus_display/panel_power_status               /sys/kernel/oplus_display/disp_on_notify; do
    [ -r "$_dp" ] || continue
    _dpv="$(cat "$_dp" 2>/dev/null)"
    case "$_dpv" in 1|on|ON) return 0 ;; 0|off|OFF) return 1 ;; esac
  done
  for _df in /sys/class/drm/card0-DSI-1/status /sys/class/drm/card0-DSI-2/status; do
    [ -r "$_df" ] || continue
    [ "$(cat "$_df" 2>/dev/null)" = "connected" ] && return 0
    return 1
  done
  for _bl in /sys/class/backlight/panel0-backlight/brightness               /sys/class/leds/lcd-backlight/brightness; do
    [ -r "$_bl" ] || continue
    _blv="$(cat "$_bl" 2>/dev/null)"
    [ "${_blv:-0}" -gt 0 ] 2>/dev/null && return 0
    return 1
  done
  dumpsys power 2>/dev/null | grep -q "mHoldingDisplaySuspendBlocker=true"
}
apply_screen_aware_caps() {
  asb_feature_enabled CPU || return 0
  asb_load_profile
  _son=0
  asb_screen_on && _son=1
  case "$ASB_PROFILE" in
    balanced)
      if [ "$_son" -eq 1 ]; then
        _P_CPUCAP_L=""
        _P_CPUCAP_B=""
        CPU_CAP_LITTLE=""
        CPU_CAP_BIG=""
      fi
      ;;
    battery)
      if [ "$_son" -eq 1 ]; then
        CPU_CAP_LITTLE=729600
        CPU_CAP_BIG=1075200
      else
        CPU_CAP_LITTLE=384000
        CPU_CAP_BIG=768000
      fi
      _P_CPUCAP_L="$CPU_CAP_LITTLE"
      _P_CPUCAP_B="$CPU_CAP_BIG"
      ;;
    performance)
      if [ "$_son" -eq 1 ]; then
        CPU_CAP_LITTLE=3072000
        CPU_CAP_BIG=3648000
      else
        CPU_CAP_LITTLE=""
        CPU_CAP_BIG=""
      fi
      _P_CPUCAP_L="${CPU_CAP_LITTLE:-}"
      _P_CPUCAP_B="${CPU_CAP_BIG:-}"
      ;;
    *)
      return 0
      ;;
  esac
  apply_cpufreq_caps
  asb_log "screen_aware_caps: profile=$ASB_PROFILE screen_on=$_son cap_l=${CPU_CAP_LITTLE:-(none)} cap_b=${CPU_CAP_BIG:-(none)}"
}
asb_cpufreq_caps_drifted() {
  asb_feature_enabled CPU || return 1
  for _pol_dir in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol_dir" ] || continue
    _smax="$_pol_dir/scaling_max_freq"
    [ -r "$_smax" ] || continue
    _rel="$(cat "$_pol_dir/related_cpus" 2>/dev/null | awk '{print $1}')"
    case "$_rel" in ''|*[!0-9]*) _rel=0 ;; esac
    if [ "$_rel" -le "$little_end" ]; then
      _want="$_P_CPU_MAXL"
    else
      _want="$_P_CPU_MAXB"
    fi
    [ -n "$_want" ] || continue
    _cur="$(cat "$_smax" 2>/dev/null | tr -d '\r')"
    [ -n "$_cur" ] || continue
    [ "$_cur" != "$_want" ] && return 0
  done
  return 1
}
asb_feature_enabled CPU && apply_gpu_caps
apply_walt_live() {
  asb_feature_enabled CPU || return 0
  [ -d /proc/sys/walt ] || return 0
  [ -e /proc/sys/walt/sched_ravg_window_nr_ticks ] && writef_retry /proc/sys/walt/sched_ravg_window_nr_ticks "$RAVG_TICKS" 10 0.25 || true
  [ -e /proc/sys/walt/sched_idle_enough ] && writef_retry /proc/sys/walt/sched_idle_enough "$WALT_IDLE" 10 0.25 || true
  [ -e /proc/sys/walt/sched_idle_enough_clust ] && writef_retry /proc/sys/walt/sched_idle_enough_clust "$WALT_IDLE_CLUST" 10 0.25 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct "$WALT_CLUSTER" 10 0.25 || true
  [ -e /proc/sys/walt/sched_cluster_util_thres_pct_clust ] && writef_retry /proc/sys/walt/sched_cluster_util_thres_pct_clust "$WALT_CLUSTER_CLUST" 10 0.25 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_colocation ] && writef_retry /proc/sys/walt/sched_min_task_util_for_colocation "$WALT_COLOC" 10 0.25 || true
  [ -e /proc/sys/walt/sched_pipeline_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_util_thres "$WALT_PIPE" 10 0.25 || true
  [ -e /proc/sys/walt/sched_pipeline_non_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_non_special_task_util_thres "$WALT_PIPE_NONSP" 10 0.25 || true
  [ -e /proc/sys/walt/sched_pipeline_special_task_util_thres ] && writef_retry /proc/sys/walt/sched_pipeline_special_task_util_thres "$WALT_PIPE_SP" 10 0.25 || true
  [ -e /proc/sys/walt/sched_busy_hyst_ns ] && writef_retry /proc/sys/walt/sched_busy_hyst_ns "$WALT_BUSY_HYST" 10 0.25 || true
  [ -e /proc/sys/walt/sched_ed_boost ] && writef_retry /proc/sys/walt/sched_ed_boost "$WALT_ED_BOOST" 10 0.25 || true
  [ -e /proc/sys/walt/sched_topapp_weight_pct ] && writef_retry /proc/sys/walt/sched_topapp_weight_pct "$WALT_TOPAPP_WEIGHT" 10 0.25 || true
  [ -e /proc/sys/walt/sched_min_task_util_for_boost ] && writef_retry /proc/sys/walt/sched_min_task_util_for_boost "$WALT_BOOST_MIN_UTIL" 10 0.25 || true
  [ -e /proc/sys/walt/sched_boost ] && writef_retry /proc/sys/walt/sched_boost "$WALT_SCHED_BOOST" 10 0.25 || true
}
apply_idle() {
  writef /sys/module/lpm_levels/parameters/sleep_disabled 0
  [ -w /sys/class/kgsl/kgsl-3d0/idle_timer ] &&     echo $_P_GTMR > /sys/class/kgsl/kgsl-3d0/idle_timer 2>/dev/null || true
  writef_retry /sys/class/kgsl/kgsl-3d0/force_rail_on 0 3 0.25 || true
  writef_retry /sys/class/kgsl/kgsl-3d0/force_clk_on  0 3 0.25 || true
  writef_retry /sys/class/kgsl/kgsl-3d0/force_bus_on  0 3 0.25 || true
  [ -w /sys/class/kgsl/kgsl-3d0/force_no_nap ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/force_no_nap "${GPU_FORCE_NO_NAP:-0}" 3 0.25 || true
  [ -w /sys/class/kgsl/kgsl-3d0/bus_split ] && [ -n "$GPU_BUS_SPLIT" ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/bus_split "$GPU_BUS_SPLIT" 3 0.25 || true
  [ -w /sys/class/kgsl/kgsl-3d0/throttling ] && [ -n "$GPU_THROTTLING" ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/throttling "$GPU_THROTTLING" 3 0.25 || true
  [ -w /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel ] && [ -n "$GPU_THERMAL_PWRLEVEL" ] && \
    writef_retry /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel "$GPU_THERMAL_PWRLEVEL" 3 0.25 || true
  [ -w /sys/class/kgsl/kgsl-3d0/pwrscale/policy/governor ] &&     echo msm-adreno-tz > /sys/class/kgsl/kgsl-3d0/pwrscale/policy/governor 2>/dev/null || true
}
asb_feature_enabled CPU && apply_idle
apply_freq_floors() {
  for _pol_dir in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol_dir" ] || continue
    _smin="$_pol_dir/scaling_min_freq"
    [ -w "$_smin" ] || continue
    _avail="$_pol_dir/scaling_available_frequencies"
    if [ -r "$_avail" ]; then
      _low="$(tr ' ' '\n' < "$_avail" | grep -v '^$' | sort -n | head -1)"
      [ -n "$_low" ] && writef_retry "$_smin" "$_low" 3 0.25 || true
    else
      _cmin="$(cat "$_pol_dir/cpuinfo_min_freq" 2>/dev/null)"
      [ -n "$_cmin" ] && writef_retry "$_smin" "$_cmin" 3 0.25 || true
    fi
  done
}

# ASB:CPU:BEGIN
apply_runtime_profile_now() {
  asb_load_profile
  PROFILE="$ASB_PROFILE"
  asb_log "apply_runtime_profile_now profile=$ASB_PROFILE"
  asb_feature_enabled CPU && asb_apply_profile_once
  if asb_feature_enabled CPU; then
    apply_walt_live
    apply_uclamp
    apply_cpuset_groups
    apply_cpuset_groups_all
    apply_idle
    apply_screen_aware_caps
    apply_gpu_caps
    [ -w "$LITTLE_POLICY/scaling_min_freq" ] && writef_retry "$LITTLE_POLICY/scaling_min_freq" "$_P_CPUL" 4 0.25 || true
    [ -w "$BIG_POLICY/scaling_min_freq" ] && writef_retry "$BIG_POLICY/scaling_min_freq" "$_P_CPUB" 4 0.25 || true
    apply_cpugov_hints
  fi
  asb_feature_enabled VM && apply_vm
  asb_feature_enabled NET && apply_net
  asb_feature_enabled WIFI && apply_wlan0_txqlen
  asb_feature_enabled WIFI && apply_wlan0_qdisc
  asb_feature_enabled WIFI && apply_wifi_pm
  asb_feature_enabled WIFI && apply_wifi_dtim
  asb_feature_enabled VM && apply_doze
  (
    sleep 10
    asb_load_profile
    asb_feature_enabled CPU && apply_walt_live
    asb_feature_enabled CPU && apply_uclamp
    asb_feature_enabled CPU && apply_screen_aware_caps
    asb_feature_enabled CPU && apply_gpu_caps
    asb_feature_enabled WIFI && apply_wifi_pm
    asb_feature_enabled WIFI && apply_wifi_dtim
  ) >/dev/null 2>&1 &
}
# ASB:CPU:END
apply_bt_settings() {
  if has settings; then
    settings put global bluetooth_btsnoop_default_mode 0 >/dev/null 2>&1 || true
    settings put secure bluetooth_btsnoop_default_mode 0 >/dev/null 2>&1 || true
    settings put global bluetooth_btsnoop_log_mode disabled >/dev/null 2>&1 || true
    settings delete global bluetooth_disabled_profiles >/dev/null 2>&1 || true
  fi
}
asb_feature_enabled BT && apply_bt_settings
apply_bt_codec_policy() {
  if has settings; then
    settings put global bluetooth_a2dp_optional_codecs_enabled 1 2>/dev/null || true
    settings put global bluetooth_a2dp_codec_priority_lhdc 1200 2>/dev/null || true
    settings put global bluetooth_a2dp_codec_priority_ldac 1100 2>/dev/null || true
    settings put global bluetooth_a2dp_codec_priority_aac 1000 2>/dev/null || true
    settings put global bluetooth_a2dp_ldac_quality_index 0 2>/dev/null || true
    settings put global bluetooth_a2dp_codec_ldac_quality_index 0 2>/dev/null || true
    settings put global bluetooth_a2dp_codec_ldac_playback_quality 990 2>/dev/null || true
  fi
  if has resetprop; then
    resetprop -n persist.vendor.qcom.bluetooth.aac_frm_ctl.enabled true >/dev/null 2>&1 || true
    resetprop -n persist.vendor.qcom.bluetooth.aac_vbr_ctl.enabled true >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.quality best >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.quality best >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.channelmode stereo >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.channelmode stereo >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.version 5 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.version 5 >/dev/null 2>&1 || true
  fi
}
asb_feature_enabled BT && apply_bt_codec_policy
apply_bt_volume_behavior() {
  if has settings; then
    settings put global bluetooth_disable_absolute_volume 0 2>/dev/null || true
    settings put secure bluetooth_disable_absolute_volume 0 2>/dev/null || true
  fi
  if has resetprop; then
    resetprop -n persist.bluetooth.disableabsvol false >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.disableabsvol false >/dev/null 2>&1 || true
    resetprop -p --delete persist.asb.force_disableabsvol >/dev/null 2>&1 || true
    resetprop -p --delete persist.asb.force_enableabsvol >/dev/null 2>&1 || true
  fi
}
asb_feature_enabled BT && apply_bt_volume_behavior
apply_bt_audio_hygiene() {
  if has resetprop; then
    resetprop -p --delete persist.vendor.bt.a2dp.lhdc.bitrate >/dev/null 2>&1 || true
    resetprop -p --delete persist.bluetooth.a2dp.lhdc.bitrate >/dev/null 2>&1 || true
  fi
  if has resetprop; then
    resetprop -n persist.bluetooth.a2dp.lhdc.samplerate 96000 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.samplerate 96000 >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.bitdepth 24 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.bitdepth 24 >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.quality best >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.quality best >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.channelmode stereo >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.channelmode stereo >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.a2dp.lhdc.version 5 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bluetooth.a2dp.lhdc.version 5 >/dev/null 2>&1 || true
    resetprop -n persist.vendor.qcom.bluetooth.enable.lpa true >/dev/null 2>&1 || true
    resetprop -n persist.vendor.btstack.enable.lpa true >/dev/null 2>&1 || true
    resetprop -n persist.vendor.bt.enable.lpa true >/dev/null 2>&1 || true
    resetprop -n persist.vendor.qcom.bluetooth.lc3_offload.enable true >/dev/null 2>&1 || true
    resetprop -n persist.vendor.qcom.bluetooth.leaudio.enable true >/dev/null 2>&1 || true
    resetprop -n persist.bluetooth.leaudio.enabled true >/dev/null 2>&1 || true
  fi
}
asb_feature_enabled BT && apply_bt_audio_hygiene
apply_audio_effect_hygiene() {
  if has resetprop; then
    resetprop -n persist.vendor.audio_fx.waves.maxxsense false >/dev/null 2>&1 || true
    resetprop -n persist.vendor.audio_fx.waves.proc_twks false >/dev/null 2>&1 || true
    resetprop -n persist.vendor.audio_fx.waves.processing false >/dev/null 2>&1 || true
    resetprop -p --delete persist.audio.matrix.limiter.enable >/dev/null 2>&1 || true
    resetprop -p --delete persist.vendor.audio.matrix.limiter.enable >/dev/null 2>&1 || true
    resetprop -p --delete persist.bluetooth.gamemode >/dev/null 2>&1 || true
  fi
}
if has resetprop; then
    for _k in media.resolution.limit.16bit media.resolution.limit.24bit media.resolution.limit.32bit \
             audio.resolution.limit.16bit audio.resolution.limit.24bit audio.resolution.limit.32bit; do
      resetprop -p --delete "$_k" >/dev/null 2>&1 || true
    done
  fi
apply_logd_props() {
  setprop persist.logd.size 32K 2>/dev/null
  setprop persist.logd.size.radio 32K 2>/dev/null
  setprop persist.logd.size.system 32K 2>/dev/null
  setprop persist.logd.size.crash 32K 2>/dev/null
  setprop persist.logd.size.kernel 32K 2>/dev/null
  setprop persist.logd.size.security 32K 2>/dev/null
  setprop persist.logd.statistics false 2>/dev/null
  setprop persist.logd.logpersistd stop 2>/dev/null
}
asb_feature_enabled LOG && apply_logd_props

apply_camera_experimental() {
  _orig="$MODDIR/config/camera_orig.conf"

  if [ ! -f "$_orig" ]; then
    mkdir -p "$MODDIR/config"
    echo "# ASB camera original values — для отката при удалении модуля" > "$_orig"
    for _prop in \
      persist.vendor.camera.mfnr.enable \
      persist.vendor.camera.eis.enable \
      persist.vendor.camera.sat.fallback.dist \
      persist.vendor.camera.main.hfr \
      persist.vendor.camera.fast.af; do
      _v="$(getprop "$_prop" 2>/dev/null)"
      echo "${_prop}=${_v}" >> "$_orig"
    done
    asb_log "camera: saved originals to camera_orig.conf"
  fi

  has resetprop || return 0
  resetprop -n persist.vendor.camera.mfnr.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.eis.enable 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.sat.fallback.dist 2.0 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.main.hfr 1 >/dev/null 2>&1 || true
  resetprop -n persist.vendor.camera.fast.af 1 >/dev/null 2>&1 || true
  asb_log "camera experimental: applied (MFNR+EIS+SAT+HFR+FastAF)"
}
asb_feature_enabled CAMERA && apply_camera_experimental

apply_audio_boost() {
  _as_pid="$(pidof audioserver 2>/dev/null | head -1)"
  [ -z "$_as_pid" ] && return 0
  has chrt || return 0
  renice -10 "$_as_pid" >/dev/null 2>&1 || true
  chrt -r -p 52 "$_as_pid" >/dev/null 2>&1 || true
  asb_log "audio boost: audioserver pid=$_as_pid renice=-10 chrt=RR/52"
}
asb_feature_enabled BT && ( sleep 15 && apply_audio_boost ) >/dev/null 2>&1 &

asb_check_perfhal_drift() {
  asb_load_profile
  [ -z "$CPU_CAP_BIG" ] && return 0
  _want="$CPU_CAP_BIG"
  _drift_pol=""
  for _pol in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_pol" ] || continue
    _rel="$(cat "$_pol/related_cpus" 2>/dev/null | awk '{print $1}')"
    case "$_rel" in ''|*[!0-9]*) continue ;; esac
    [ "$_rel" -gt "$little_end" ] 2>/dev/null && { _drift_pol="$_pol"; break; }
  done
  [ -z "$_drift_pol" ] && return 0
  _cur="$(cat "$_drift_pol/scaling_max_freq" 2>/dev/null)"
  [ -z "$_cur" ] && return 0
  if [ "$_cur" != "$_want" ]; then
    asb_log "PERF-HAL DRIFT: $(basename $_drift_pol) max=${_cur} (expected ${_want}) — likely overridden by PowerHAL/thermal"
  fi
}

svc_state() { getprop "init.svc.$1" 2>/dev/null; }
svc_exists() { [ -n "$(svc_state "$1")" ]; }
svc_running() { [ "$(svc_state "$1")" = "running" ]; }
svc_busy() {
  st="$(svc_state "$1")"
  [ "$st" = "stopping" ] || [ "$st" = "restarting" ]
}
svc_stop() {
  s="$1"
  svc_exists "$s" || return 0
  svc_running "$s" || return 0
  svc_busy "$s" && return 0
  sleep 0.5
  svc_running "$s" && stop "$s" 2>/dev/null || true
  return 0
}
svc_stop_guarded() {
  s="$1"
  for i in 1 2 3; do
    svc_stop "$s"
    svc_running "$s" || return 0
    sleep 2
  done
  return 0
}
for s in \
  qseelogd wlanramdumpcollector mqsasd mtdoopslog debuggerd \
  minidump minidump32 minidump64 bootstat poweroff_charger_log \
  ostatsd charge_logger iorapd cnss_diag diag_mdlog diag_mdlog_start \
  mmi-diag qcom-diag tftp_server tcpdump modem_svc logcat-debug \
  midasd batterysecret \
  mdnsd \
  oplus_sensor_fb vendor.oplus.sensor.fb \
  oplus_crash_report \
  oplusdebuglogauto \
  vendor.oplus.logkit oplus_logctl \
  qcom_diag_relay vendor.qti.diag \
  oplusd mlipay \
; do
  svc_stop_guarded "$s"
done
apply_zram() {
  [ -e /sys/block/zram0 ] || return 0
  CPU_CORES=$(nproc 2>/dev/null || echo 8)
  ZRAM_SIZE_MB=8192
  swapoff /dev/block/zram0 >/dev/null 2>&1 || true
  echo 1 > /sys/block/zram0/reset 2>/dev/null || return 0
  sleep 2
  echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || \
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  echo "$CPU_CORES" > /sys/block/zram0/max_comp_streams 2>/dev/null || true
  [ -f /sys/block/zram0/use_dedup ] && echo 1 > /sys/block/zram0/use_dedup 2>/dev/null || true
  echo "${ZRAM_SIZE_MB}M" > /sys/block/zram0/disksize 2>/dev/null || return 0
  echo 0 > /sys/block/zram0/queue/iostats 2>/dev/null || true
  echo 0 > /sys/block/zram0/queue/add_random 2>/dev/null || true
  mkswap /dev/block/zram0 >/dev/null 2>&1 && \
    swapon /dev/block/zram0 >/dev/null 2>&1 || true
}
apply_walt_boost() {
  for _pol in 0 4 7; do
    _wp="/sys/devices/system/cpu/cpufreq/policy${_pol}/walt"
    [ -d "$_wp" ] || continue
    writef_retry "$_wp/input_boost_freq" 0  3 0.25 || true
    writef_retry "$_wp/input_boost_ms"   25 3 0.25 || true
  done
  [ -w /proc/sys/kernel/sched_boost ] && \
    writef_retry /proc/sys/kernel/sched_boost 0 3 0.25 || true
  writef_retry /proc/sys/kernel/sched_energy_aware 1 3 0.25 || true
}
( sleep 5; asb_load_profile; apply_walt_boost; apply_walt_live ) >/dev/null 2>&1 &
asb_feature_enabled VM && apply_zram
apply_doze() {
  has settings || return 0
  case "$ASB_PROFILE" in
    battery)
      _DIC="light_after_inactive_to=15000,light_pre_idle_to=2000,light_max_idle_to=86400000,light_idle_to=5000,light_idle_factor=3.0,light_idle_maintenance_min_budget=1000,light_idle_maintenance_max_budget=5000,inactive_to=30000,sensing_to=0,locating_to=0,location_accuracy=2000.0,motion_inactive_to=0,idle_after_inactive_to=3000,idle_pending_to=1500,max_idle_pending_to=3000,idle_pending_factor=3.0,idle_to=900000,max_idle_to=43200000,idle_factor=3.0,min_time_to_alarm=30000,max_temp_app_whitelist_duration=20000,mms_temp_app_whitelist_duration=10000,sms_temp_app_whitelist_duration=8000" ;;
    performance)
      _DIC="light_after_inactive_to=60000,light_pre_idle_to=10000,light_max_idle_to=86400000,light_idle_to=15000,light_idle_factor=2.0,light_idle_maintenance_min_budget=2000,light_idle_maintenance_max_budget=15000,inactive_to=300000,sensing_to=0,locating_to=0,location_accuracy=2000.0,motion_inactive_to=0,idle_after_inactive_to=20000,idle_pending_to=10000,max_idle_pending_to=15000,idle_pending_factor=2.0,idle_to=3600000,max_idle_to=10800000,idle_factor=2.0,min_time_to_alarm=60000,max_temp_app_whitelist_duration=60000,mms_temp_app_whitelist_duration=30000,sms_temp_app_whitelist_duration=20000" ;;
    *)
      _DIC="light_after_inactive_to=30000,light_pre_idle_to=5000,light_max_idle_to=86400000,light_idle_to=10000,light_idle_factor=2.0,light_idle_maintenance_min_budget=2000,light_idle_maintenance_max_budget=15000,inactive_to=180000,sensing_to=0,locating_to=0,location_accuracy=2000.0,motion_inactive_to=0,idle_after_inactive_to=10000,idle_pending_to=5000,max_idle_pending_to=10000,idle_pending_factor=2.0,idle_to=3600000,max_idle_to=21600000,idle_factor=2.0,min_time_to_alarm=60000,max_temp_app_whitelist_duration=60000,mms_temp_app_whitelist_duration=30000,sms_temp_app_whitelist_duration=20000" ;;
  esac
  settings put global device_idle_constants "$_DIC" >/dev/null 2>&1 || true
}
asb_feature_enabled VM && apply_doze
apply_extra_settings() {
  has settings || return 0
  settings put global audio_safe_volume_state 0 >/dev/null 2>&1 || true
  settings delete global netstats_enabled >/dev/null 2>&1 || true
  settings delete global app_usage_enabled >/dev/null 2>&1 || true
  settings delete global package_usage_stats_enabled >/dev/null 2>&1 || true
  settings put global bluetooth_voip_support 1 >/dev/null 2>&1 || true
  settings put global dropbox_max_files 5 >/dev/null 2>&1 || true
  settings put global network_recommendations_enabled 0 >/dev/null 2>&1 || true
  settings put global activity_starts_logging_enabled    0 >/dev/null 2>&1 || true
  settings put global settings_enable_monitor_phantom_procs false >/dev/null 2>&1 || true
  settings put global send_action_app_error              0 >/dev/null 2>&1 || true
  settings put global enhanced_connectivity_enabled      0 >/dev/null 2>&1 || true
  settings put global adaptive_connectivity_enabled 0 >/dev/null 2>&1 || true
}
apply_extra_settings
(
  sleep 30
  _fg="$(getprop persist.sys.power.fuel.gauge 2>/dev/null)"
  [ "$_fg" != "0" ] && setprop persist.sys.power.fuel.gauge 0 2>/dev/null
) >/dev/null 2>&1 &
(
  _last_profile=""
  _last_screen="-1"
  _reconcile_fast=3
  _last_wifi_check=0
  while true; do
    if [ "$ASB_GOV_ENABLED" = "1" ] && asb_governor_running; then
      _rec_scr=0
      for _rsp in /sys/kernel/oplus_display/panel_power_status                   /sys/class/backlight/panel0-backlight/brightness; do
        [ -r "$_rsp" ] || continue
        _rspv="$(cat "$_rsp" 2>/dev/null)"
        case "$_rspv" in 0|"") ;; *) _rec_scr=1 ;; esac
        break
      done
      [ "$_rec_scr" -eq 1 ] && sleep 120 || sleep 180
    elif [ "$_reconcile_fast" -gt 0 ]; then
      sleep 45
      _reconcile_fast=$((_reconcile_fast - 1))
    else
      _scr_idle=0
      for _dpp in /sys/kernel/oplus_display/panel_power_status                   /sys/class/backlight/panel0-backlight/brightness; do
        [ -r "$_dpp" ] || continue
        _dppv="$(cat "$_dpp" 2>/dev/null)"
        case "$_dppv" in
          0|"") _scr_idle=1 ;;
        esac
        break
      done
      [ "$_scr_idle" -eq 1 ] && sleep 90 || sleep 45
    fi
    _now="$(cat "$MODDIR/current_profile" 2>/dev/null)"
    case "$_now" in
      battery|balanced|performance) : ;;
      *) _now="balanced" ;;
    esac
    asb_load_profile
    _need=0
    _reason=""
    if [ "$_now" != "$_last_profile" ]; then
      _need=1
      _reason="profile-change"
    else
      _cur_screen=0
      asb_screen_on && _cur_screen=1
      if [ "$_cur_screen" != "$_last_screen" ]; then
        _need=1
        _reason="screen-state"
        _last_screen="$_cur_screen"
      fi
      if [ $_need -eq 0 ] && asb_feature_enabled CPU; then
        if [ "$ASB_GOV_ENABLED" != "1" ] || ! asb_governor_running; then
          _cur_topw="$(cat /proc/sys/walt/sched_topapp_weight_pct 2>/dev/null)"
          [ -n "$_cur_topw" ] && [ "$_cur_topw" != "$WALT_TOPAPP_WEIGHT" ] && { _need=1; _reason="walt-topapp"; }
          _cur_edb="$(cat /proc/sys/walt/sched_ed_boost 2>/dev/null)"
          [ $_need -eq 0 ] && [ -n "$_cur_edb" ] && [ "$_cur_edb" != "$WALT_ED_BOOST" ] && { _need=1; _reason="walt-edboost"; }
          _cur_ravg="$(cat /proc/sys/walt/sched_ravg_window_nr_ticks 2>/dev/null)"
          [ $_need -eq 0 ] && [ -n "$_cur_ravg" ] && [ "$_cur_ravg" != "$RAVG_TICKS" ] && { _need=1; _reason="walt-ravg"; }
          _cur_ucl="$(cat /dev/cpuctl/top-app/cpu.uclamp.max 2>/dev/null | tr -d '\r')"
          case "$_cur_ucl" in max) _cur_ucl="100" ;; esac
          _want_ucl="${UCL_TOP_MAX:-85}"
          case "$_want_ucl" in max) _want_ucl="100" ;; esac
          [ $_need -eq 0 ] && [ -n "$_cur_ucl" ] && [ "$_cur_ucl" != "$_want_ucl" ] && { _need=1; _reason="uclamp"; }
        fi
      fi
      if [ $_need -eq 0 ] && asb_feature_enabled WIFI; then
        _ts_now="$(date +%s 2>/dev/null || echo 0)"
        _wifi_delta=$((_ts_now - _last_wifi_check))
        if [ "$_wifi_delta" -ge 300 ] 2>/dev/null; then
          _last_wifi_check="$_ts_now"
          _want_pm="$WIFI_PM_MODE"
          _cur_pm=""
          has iw && _cur_pm="$(iw dev wlan0 get power_save 2>/dev/null | awk -F': ' '/Power save/ {print tolower($2)}')"
          case "$_want_pm" in
            on)  [ -n "$_cur_pm" ] && [ "$_cur_pm" != "on"  ] && { _need=1; _reason="wifi-pm"; } ;;
            off) [ -n "$_cur_pm" ] && [ "$_cur_pm" != "off" ] && { _need=1; _reason="wifi-pm"; } ;;
          esac
        fi
      fi
    fi
    if [ $_need -eq 1 ]; then
      _reconcile_fast=3
      asb_update_desc
      asb_log "runtime reconcile reason=$_reason profile=$_now"
      if [ "$ASB_GOV_ENABLED" = "1" ] && asb_governor_running; then
        if [ "$_reason" = "profile-change" ]; then
          asb_governor_set_profile
          asb_feature_enabled VM   && apply_vm
          asb_feature_enabled NET  && apply_net
          asb_feature_enabled WIFI && apply_wlan0_txqlen
          asb_feature_enabled WIFI && apply_wifi_pm
          asb_feature_enabled VM   && apply_doze
        elif [ "$_reason" = "wifi-pm" ]; then
          asb_feature_enabled WIFI && apply_wifi_pm
          asb_feature_enabled WIFI && apply_wifi_dtim
        fi
      else
        if [ "$_reason" = "screen-state" ]; then
          asb_feature_enabled CPU && apply_screen_aware_caps
        else
          apply_runtime_profile_now
          [ "$_reason" = "profile-change" ] && sleep 2 && asb_load_profile && apply_runtime_profile_now
        fi
      fi
      asb_feature_enabled LOG && asb_check_perfhal_drift
      _last_profile="$_now"
    fi
  done
) >/dev/null 2>&1 &
(
  sleep 60
  asb_load_profile
  if asb_feature_enabled KERNEL; then
    writef_retry /proc/sys/kernel/sched_util_clamp_min 0 3 0.25 || true
    sysctlw kernel.sched_schedstats 0
    sysctlw kernel.timer_migration 0
    [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4
  fi
  if asb_feature_enabled CPU; then
    if [ "$ASB_GOV_ENABLED" != "1" ] || ! asb_governor_running; then
      apply_walt_live
    fi
  fi
  asb_log "light reinforce 60s profile=$ASB_PROFILE"
  has settings && settings put global network_recommendations_enabled 0 >/dev/null 2>&1 || true
  sleep 240
  asb_load_profile
  if asb_feature_enabled KERNEL; then
    writef_retry /proc/sys/kernel/sched_util_clamp_min 0 3 0.25 || true
    sysctlw kernel.sched_schedstats 0
    sysctlw kernel.timer_migration 0
    [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4
  fi
  asb_log "full reinforce 5m profile=$ASB_PROFILE"
  if [ "$ASB_GOV_ENABLED" != "1" ] || ! asb_governor_running; then
    asb_feature_enabled CPU && apply_walt_live
    asb_feature_enabled CPU && apply_uclamp
    asb_feature_enabled CPU && apply_screen_aware_caps
    asb_feature_enabled CPU && apply_gpu_caps
  fi
  asb_feature_enabled VM && apply_vm
  asb_feature_enabled VM && apply_doze
) >/dev/null 2>&1 &
(
  [ "$ASB_GOV_ENABLED" -eq 1 ] || exit 0
  while true; do
    sleep 300
    if ! asb_governor_running; then
      asb_log "governor watchdog: process died, restarting"
      asb_governor_start || {
        asb_log "governor restart failed, entering shell fallback"
        asb_load_profile
        asb_feature_enabled CPU && apply_runtime_profile_now
        ASB_GOV_ENABLED=0
        exit 0
      }
      continue
    fi
    _state_age=0
    if [ -f /dev/.asb/state ]; then
      _state_mtime="$(stat -c %Y /dev/.asb/state 2>/dev/null || echo 0)"
      _now_ts="$(date +%s 2>/dev/null || echo 0)"
      _state_age=$((_now_ts - _state_mtime))
    fi
    if [ "$_state_age" -gt 90 ] 2>/dev/null; then
      asb_log "governor watchdog: state stale (${_state_age}s), restarting"
      _gpid="$(cat /dev/.asb/governor.pid 2>/dev/null)"
      [ -n "$_gpid" ] && kill "$_gpid" 2>/dev/null
      sleep 1
      asb_governor_start || {
        asb_log "governor restart failed after stale, shell fallback"
        asb_load_profile
        asb_feature_enabled CPU && apply_runtime_profile_now
        ASB_GOV_ENABLED=0
        exit 0
      }
    fi
  done
) >/dev/null 2>&1 &

exit 0
