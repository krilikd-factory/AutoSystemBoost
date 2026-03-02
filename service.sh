#!/system/bin/sh
exec >/dev/null 2>&1

MODID="AutoSystemBoost"

has() { command -v "$1" >/dev/null 2>&1; }
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

apply_cpuset_groups() {
  writef_retry /dev/cpuset/background/cpus           "0-${little_end}" 3 0.25 || true
  writef_retry /dev/cpuset/system-background/cpus    "0-${little_end}" 3 0.25 || true
  writef_retry /dev/cpuset/foreground/cpus           "0-${cpu_max}" 3 0.25 || true
  writef_retry /dev/cpuset/top-app/cpus              "0-${cpu_max}" 3 0.25 || true
}

apply_uclamp() {
  # ASB:UCLAMP V15.3 — multi-path write for kernel 6.12+ cgroup layout
  # Path A: /dev/cpuctl (legacy, Android < 15)
  writef_retry /dev/cpuctl/top-app/uclamp.latency_sensitive 1 5 0.3 || true

  writef_retry /dev/cpuctl/background/cpu.uclamp.min        0  5 0.3 || true
  writef_retry /dev/cpuctl/system-background/cpu.uclamp.min 0  5 0.3 || true
  writef_retry /dev/cpuctl/foreground/cpu.uclamp.min        15 5 0.3 || true
  writef_retry /dev/cpuctl/top-app/cpu.uclamp.min           45 5 0.3 || true

  writef_retry /dev/cpuctl/background/uclamp.min        0  5 0.3 || true
  writef_retry /dev/cpuctl/system-background/uclamp.min 0  5 0.3 || true
  writef_retry /dev/cpuctl/foreground/uclamp.min        15 5 0.3 || true
  writef_retry /dev/cpuctl/top-app/uclamp.min           45 5 0.3 || true

  # Path B: /sys/fs/cgroup (Android 15+ / kernel 6.6+)
  for _cg_root in /sys/fs/cgroup /dev/cgroup; do
    [ -d "$_cg_root" ] || continue
    for _tier in background system-background foreground top-app; do
      _uval=0
      [ "$_tier" = "foreground" ] && _uval=15
      [ "$_tier" = "top-app" ]    && _uval=45
      _node="$_cg_root/$_tier/cpu.uclamp.min"
      [ -f "$_node" ] && writef_retry "$_node" "$_uval" 5 0.3 || true
    done
    _lat="$_cg_root/top-app/cpu.uclamp.latency_sensitive"
    [ -f "$_lat" ] && writef_retry "$_lat" 1 5 0.3 || true
  done

  [ -w /proc/sys/kernel/sched_util_clamp_min ] && \
    writef_retry /proc/sys/kernel/sched_util_clamp_min 0 5 0.3 || true
}
wait_path /dev/cpuset/background/cpus 8 || true
wait_path /dev/cpuctl/top-app 8 || true

apply_uclamp

if [ $IS_WILD -eq 0 ]; then
  apply_cpuset_groups
fi

# ASB:V15.6 CPU governor battery hints
apply_cpugov_hints() {
  # schedutil rate_limit_us 0→2000: fewer governor timer wakeups from idle
  for _pol in /sys/devices/system/cpu/cpufreq/policy*/schedutil/rate_limit_us; do
    [ -w "$_pol" ] && echo 2000 > "$_pol" 2>/dev/null || true
  done
  # Small/mid clusters: raise hispeed_load → avoid unnecessary freq spikes
  for _pol in /sys/devices/system/cpu/cpufreq/policy0               /sys/devices/system/cpu/cpufreq/policy4; do
    [ -w "$_pol/schedutil/hispeed_load" ] &&       echo 90 > "$_pol/schedutil/hispeed_load" 2>/dev/null || true
    [ -w "$_pol/schedutil/hispeed_freq" ] &&       echo 0   > "$_pol/schedutil/hispeed_freq" 2>/dev/null || true
  done
}
apply_cpugov_hints
# ASB:CPU:END

if has pm; then
  pm disable-user --user 0 com.android.traceur >/dev/null 2>&1 || true
fi

# ASB:VM:BEGIN
apply_vm() {
  sysctlw vm.swappiness 20

  if [ -e /proc/sys/vm/dirty_bytes ] && [ -e /proc/sys/vm/dirty_background_bytes ]; then
    sysctlw vm.dirty_ratio 0
    sysctlw vm.dirty_background_ratio 0
    sysctlw vm.dirty_bytes 67108864
    sysctlw vm.dirty_background_bytes 16777216
  else
    sysctlw vm.dirty_ratio 20
    sysctlw vm.dirty_background_ratio 5
  fi

  sysctlw vm.dirty_expire_centisecs 6000  # 60s — less writeback churn in standby
  sysctlw vm.dirty_writeback_centisecs 5000
  sysctlw vm.vfs_cache_pressure 50

  [ -e /proc/sys/vm/compaction_proactiveness ] && sysctlw vm.compaction_proactiveness 0
  [ -e /proc/sys/vm/stat_interval ] && sysctlw vm.stat_interval 15  # 15s = fewer vmstat wakeups than default 1s

  writef_retry /proc/sys/vm/page-cluster 0 1 0 || true
  sysctlw vm.watermark_scale_factor 60
  sysctlw vm.min_free_kbytes 32768
  # ASB:V15.4 OOM — kill allocating task instead of full scan (faster + saves battery)
  sysctlw vm.oom_kill_allocating_task 1
}
apply_vm
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

  sysctlw net.ipv4.tcp_pacing_ca_ratio 110
  sysctlw net.ipv4.tcp_pacing_ss_ratio 170
  [ -e /proc/sys/net/ipv6/tcp_ecn ] && sysctlw net.ipv6.tcp_ecn 0
  [ -e /proc/sys/net/ipv6/tcp_rmem ] && sysctlw net.ipv6.tcp_rmem "4096 262144 16777216"
  [ -e /proc/sys/net/ipv6/tcp_wmem ] && sysctlw net.ipv6.tcp_wmem "4096 262144 16777216"

  sysctlw net.ipv4.tcp_moderate_rcvbuf 1
  sysctlw net.ipv4.tcp_rmem "4096 262144 16777216"
  sysctlw net.ipv4.tcp_wmem "4096 262144 16777216"
  sysctlw net.core.rmem_max 16777216
  sysctlw net.core.wmem_max 16777216
  sysctlw net.core.optmem_max 1048576

  sysctlw net.ipv4.tcp_fastopen 3
  sysctlw net.ipv4.tcp_sack 1
  sysctlw net.ipv4.tcp_dsack 1
  sysctlw net.ipv4.tcp_window_scaling 1
  sysctlw net.ipv4.tcp_timestamps 1
  sysctlw net.ipv4.tcp_ecn 0
  sysctlw net.ipv4.tcp_early_retrans 3

  [ -e /proc/sys/net/ipv4/tcp_notsent_lowat ] && sysctlw net.ipv4.tcp_notsent_lowat 131072

  sysctlw net.ipv4.udp_rmem_min 65536
  sysctlw net.ipv4.udp_wmem_min 65536
  [ -e /proc/sys/net/ipv6/udp_rmem_min ] && sysctlw net.ipv6.udp_rmem_min 65536
  [ -e /proc/sys/net/ipv6/udp_wmem_min ] && sysctlw net.ipv6.udp_wmem_min 65536

  sysctlw net.ipv4.tcp_mtu_probing 1
  sysctlw net.ipv4.tcp_slow_start_after_idle 0
  sysctlw net.ipv4.tcp_recovery 1
  sysctlw net.ipv4.tcp_max_orphans 8192
  # ASB:V15.4 TCP keepalive — free dead connections faster on cellular
  # ASB:V15.5 TCP keepalive — restored to kernel defaults
  #   V15.4 used 1800s/30s/3 — can cause extra RRC wakeups on cellular
  #   tcp_fin_timeout=30 retained (safe, only affects FIN_WAIT state)
  # sysctlw net.ipv4.tcp_keepalive_time   1800  # reverted
  sysctlw net.ipv4.tcp_keepalive_time   7200
  sysctlw net.ipv4.tcp_keepalive_intvl  75
  sysctlw net.ipv4.tcp_keepalive_probes 9
  # tcp_max_tw_buckets kept at 16384 (memory, not battery relevant)
  # ASB:V15.6 TCP battery (safe — not keepalive)
  sysctlw net.ipv4.tcp_fin_timeout          20   # reclaim FIN_WAIT sockets 3× faster
  sysctlw net.ipv4.tcp_no_metrics_save       1   # no route-metric cache churn on close


  sysctlw net.core.somaxconn 512
  sysctlw net.ipv4.tcp_max_syn_backlog 2048
  sysctlw net.core.netdev_max_backlog 2000
  sysctlw net.core.netdev_budget 180
  sysctlw net.core.netdev_budget_usecs 5000
  sysctlw net.core.dev_weight 64

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

apply_net
# ASB:NET:END

apply_wifi_settings() {
  has settings || return 0
  settings put global nearby_scanning_enabled 0 >/dev/null 2>&1 || true
  settings put global wifi_scan_throttle_enabled 1 >/dev/null 2>&1 || true
  settings put global wifi_suspend_optimizations_enabled 1 >/dev/null 2>&1 || true
}

apply_wifi_settings

apply_wlan0_txqlen() {
  [ -e /sys/class/net/wlan0/tx_queue_len ] || return 0
  _txq="$(cat /sys/class/net/wlan0/tx_queue_len 2>/dev/null)"
  [ "$_txq" = "512" ] && return 0
  echo 512 > /sys/class/net/wlan0/tx_queue_len 2>/dev/null || true
  ip link set wlan0 txqueuelen 512 >/dev/null 2>&1 || true
}

apply_wlan0_txqlen

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
  apply_netif_qdisc wlan0
}

apply_mobile_qdisc() {
  for _dev in /sys/class/net/*; do
    [ -e "$_dev" ] || continue
    _if="${_dev##*/}"
    case "$_if" in
      rmnet*|ccmni*) apply_netif_qdisc "$_if" ;;
    esac
  done
}

apply_wlan0_qdisc
apply_mobile_qdisc

# ASB:WIFI_PM:BEGIN
apply_wifi_pm() {
  # ASB:V15.5 Wi-Fi PSM — smart mode, skips during high-traffic (gaming/video)
  #   V15.4 always forced PSM ON → caused ping spikes in CODM
  #   V15.5: check tx_bytes delta; if >500 KB/s skip PSM (user is gaming/streaming)
  wait_path /sys/class/net/wlan0 10 || return 0
  _tx1=$(cat /sys/class/net/wlan0/statistics/tx_bytes 2>/dev/null || echo 0)
  sleep 1
  _tx2=$(cat /sys/class/net/wlan0/statistics/tx_bytes 2>/dev/null || echo 0)
  _delta=$(( _tx2 - _tx1 ))
  if [ "$_delta" -gt 524288 ]; then
    # >512 KB/s TX → active gaming/streaming → keep PSM OFF
    iw dev wlan0 set power_save off >/dev/null 2>&1 || true
    writef_retry /sys/module/wlan/parameters/wlan_pm 0 3 0.25 || true
  else
    # idle / light traffic → PSM ON
    iw dev wlan0 set power_save on >/dev/null 2>&1 || true
    writef_retry /sys/module/wlan/parameters/wlan_pm 1 3 0.25 || true
  fi
  setprop persist.vendor.wlan.scan_throttle 1 2>/dev/null || true
}
apply_wifi_pm
# ASB:V15.6 Wi-Fi DTIM listen interval
apply_wifi_dtim() {
  iw dev wlan0 set listen-interval 3 >/dev/null 2>&1 || true
  writef_retry /sys/module/wlan/parameters/enable_connected_scan_result 0 3 0.25 || true
}
apply_wifi_dtim
# ASB:WIFI_PM:END

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

  for delay in 0 5 10 20 30 45; do
    [ $delay -gt 0 ] && sleep $delay
    apply_wlan0_txqlen
    apply_wlan0_qdisc
    q="$(cat /sys/class/net/wlan0/tx_queue_len 2>/dev/null)"
    [ "$q" = "512" ] && break
  done
) >/dev/null 2>&1 &

apply_gps_hygiene() {
  has settings || return 0
  [ "$(settings get global assisted_gps_enabled 2>/dev/null)" = "1" ] && return 0
  settings put global assisted_gps_enabled 1 >/dev/null 2>&1 || true
}

apply_gps_hygiene

tune_io_queues() {
  for _b in /sys/block/sd* /sys/block/mmcblk* /sys/block/dm-*; do
    [ -d "$_b/queue" ] || continue
    [ -r "$_b/queue/rotational" ] && [ "$(cat "$_b/queue/rotational" 2>/dev/null)" = "1" ] && continue
    writef "$_b/queue/iostats" 0
    writef "$_b/queue/add_random" 0
    writef "$_b/queue/rq_affinity" 2
    case "${_b##*/}" in
      dm-*)  writef "$_b/queue/read_ahead_kb" 128 ;;
      *)     writef "$_b/queue/read_ahead_kb" 128 ;;
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

  [ -e /proc/sys/walt/sched_ravg_window_nr_ticks ] && \
    writef_retry /proc/sys/walt/sched_ravg_window_nr_ticks 2 1 0 || true

  writef_retry /proc/sys/kernel/sched_util_clamp_min 0 3 0.25 || true

  tune_io_queues
}
apply_kernel
# ASB:KERNEL:END

# ASB:IDLE:BEGIN
apply_idle() {
  writef /sys/module/lpm_levels/parameters/sleep_disabled 0
  # ASB:V15.4 GPU idle_timer 80→250 ms (deeper CX power-collapse)
  [ -w /sys/class/kgsl/kgsl-3d0/idle_timer ] && \
    echo 250 > /sys/class/kgsl/kgsl-3d0/idle_timer 2>/dev/null || true
  # ASB:V15.4 GPU force flags — ensure CX rail can collapse
  writef_retry /sys/class/kgsl/kgsl-3d0/force_rail_on 0 3 0.25 || true
  writef_retry /sys/class/kgsl/kgsl-3d0/force_clk_on  0 3 0.25 || true
  writef_retry /sys/class/kgsl/kgsl-3d0/force_bus_on  0 3 0.25 || true
  # ASB:V15.6 GPU NAP governor
  [ -w /sys/class/kgsl/kgsl-3d0/pwrscale/policy/governor ] && \
    echo msm-adreno-tz > /sys/class/kgsl/kgsl-3d0/pwrscale/policy/governor 2>/dev/null || true
  # min_pwrlevel intentionally NOT set — level 6 blocks levels 7-8 (deep idle/sleep)
  # Adreno idle reports level 9/17 in diag; setting min=6 was the V15.1 regression
}
apply_idle
# ASB:IDLE:END

apply_bt_settings() {
  if has settings; then
    settings put global ble_scan_always_enabled 0 >/dev/null 2>&1 || true
    settings put global bluetooth_btsnoop_default_mode 0 >/dev/null 2>&1 || true
    settings put secure bluetooth_btsnoop_default_mode 0 >/dev/null 2>&1 || true
    settings put global bluetooth_btsnoop_log_mode disabled >/dev/null 2>&1 || true
    settings delete global bluetooth_disabled_profiles >/dev/null 2>&1 || true
  fi
}

apply_bt_settings

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

apply_bt_codec_policy

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

apply_bt_volume_behavior

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

apply_bt_audio_hygiene

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

apply_audio_effect_hygiene

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

apply_logd_props

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

# ASB:STOPLIST V15.4 — extended service stop list (+11 OxygenOS/QTI services)
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
  # ASB:ZRAM V15.3 — fixed 8 GB for OnePlus 15 (16 GB RAM), zstd preferred
  [ -e /sys/block/zram0 ] || return 0
  CPU_CORES=$(nproc 2>/dev/null || echo 8)
  # Fixed size: 8192 MB (~53% of RAM) — optimal for 16 GB device with Android 16
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
  # ASB:WALT_BOOST V15.5 — balanced WALT input_boost on SM8750
  # input_boost_freq=0: no freq spike on touch (saves 2-4 mAh/h)
  # input_boost_ms=25:  minimal 25 ms window preserves touch responsiveness
  #   (V15.4 used 0 ms — too aggressive, caused micro-stutter per ChatGPT feedback)
  for _pol in 0 4 7; do
    _wp="/sys/devices/system/cpu/cpufreq/policy${_pol}/walt"
    [ -d "$_wp" ] || continue
    writef_retry "$_wp/input_boost_freq" 0  3 0.25 || true
    writef_retry "$_wp/input_boost_ms"   25 3 0.25 || true
  done
  # Global WALT sched_boost = 0
  [ -w /proc/sys/kernel/sched_boost ] && \
    writef_retry /proc/sys/kernel/sched_boost 0 3 0.25 || true
  # Ensure Energy Aware Scheduling is ON
  writef_retry /proc/sys/kernel/sched_energy_aware 1 3 0.25 || true
}
( sleep 5; apply_walt_boost ) >/dev/null 2>&1 &

apply_zram


apply_doze() {
  # ASB:DOZE V15.4 — aggressive DeviceIdle constants for deep standby
  # sensing_to=0: skip motion-sensing phase (saves accelerometer wakeups)
  # locating_to=0: skip GPS location phase
  # inactive_to=180000: Doze starts after 3 min screen-off
  #   (V15.4 used 30 s — too aggressive, may affect email/calendar sync)
  #   FCM push (Telegram, WhatsApp) bypasses Doze via high-priority channel
  # idle_to=3600000: deep idle cycle 60 min
  # min_time_to_alarm=60000: suppress short alarms in deep Doze (1 min floor)
  has settings || return 0
  settings put global device_idle_constants \
"light_after_inactive_to=30000,light_pre_idle_to=5000,light_max_idle_to=86400000,light_idle_to=10000,light_idle_factor=2.0,light_idle_maintenance_min_budget=2000,light_idle_maintenance_max_budget=15000,inactive_to=180000,sensing_to=0,locating_to=0,location_accuracy=2000.0,motion_inactive_to=0,idle_after_inactive_to=10000,idle_pending_to=5000,max_idle_pending_to=10000,idle_pending_factor=2.0,idle_to=3600000,max_idle_to=21600000,idle_factor=2.0,min_time_to_alarm=60000,max_temp_app_whitelist_duration=60000,mms_temp_app_whitelist_duration=30000,sms_temp_app_whitelist_duration=20000" \
    >/dev/null 2>&1 || true
}
apply_doze

apply_extra_settings() {
  has settings || return 0
  settings put global audio_safe_volume_state 0 >/dev/null 2>&1 || true
  settings delete global netstats_enabled >/dev/null 2>&1 || true
  settings delete global app_usage_enabled >/dev/null 2>&1 || true
  settings delete global package_usage_stats_enabled >/dev/null 2>&1 || true
  settings put global bluetooth_voip_support 1 >/dev/null 2>&1 || true
  settings put global dropbox_max_files 5 >/dev/null 2>&1 || true
  settings put global network_recommendations_enabled 0 >/dev/null 2>&1 || true
  # ASB:V15.6 — additional OxygenOS telemetry/analytics disable
  settings put global activity_starts_logging_enabled    0 >/dev/null 2>&1 || true
  settings put global settings_enable_monitor_phantom_procs false >/dev/null 2>&1 || true
  settings put global send_action_app_error              0 >/dev/null 2>&1 || true
  settings put global enhanced_connectivity_enabled      0 >/dev/null 2>&1 || true
  settings put global wifi_scan_always_enabled           0 >/dev/null 2>&1 || true
  settings put global wifi_wakeup_enabled                0 >/dev/null 2>&1 || true
}
apply_extra_settings

(
  sleep 30
  _fg="$(getprop persist.sys.power.fuel.gauge 2>/dev/null)"
  [ "$_fg" != "0" ] && setprop persist.sys.power.fuel.gauge 0 2>/dev/null
) >/dev/null 2>&1 &

(
  for _delay in 30 90 300; do
    sleep "$_delay"
    writef_retry /proc/sys/kernel/sched_util_clamp_min 0 3 0.25 || true
    sysctlw kernel.sched_schedstats 0
    sysctlw kernel.timer_migration 0
    [ -e /proc/sys/kernel/sched_nr_migrate ] && sysctlw kernel.sched_nr_migrate 4
    apply_uclamp
    [ $IS_WILD -eq 0 ] && apply_cpuset_groups
    apply_idle
    apply_wlan0_txqlen
    apply_wlan0_qdisc
    # ASB:V15.3 re-apply network_recommendations=0 (may be reset by GMS)
    has settings && settings put global network_recommendations_enabled 0 >/dev/null 2>&1 || true
    # ASB:V15.4 re-apply Wi-Fi PSM and Doze constants (can be reset by OEM services)
    apply_wifi_pm
    apply_doze
  done
) >/dev/null 2>&1 &

exit 0
