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
  # ASB:UCLAMP smart values: fg=8 (light tasks stay on LITTLE), top=12 (responsive without waste)
  # On Wild kernel these writes don't stick (WALT overrides), harmless no-op
  writef_retry /dev/cpuctl/top-app/uclamp.latency_sensitive 1 3 0.25 || true

  writef_retry /dev/cpuctl/background/cpu.uclamp.min 0 3 0.25 || true
  writef_retry /dev/cpuctl/system-background/cpu.uclamp.min 0 3 0.25 || true
  writef_retry /dev/cpuctl/foreground/cpu.uclamp.min 8 3 0.25 || true
  writef_retry /dev/cpuctl/top-app/cpu.uclamp.min 12 3 0.25 || true

  writef_retry /dev/cpuctl/background/uclamp.min 0 3 0.25 || true
  writef_retry /dev/cpuctl/system-background/uclamp.min 0 3 0.25 || true
  writef_retry /dev/cpuctl/foreground/uclamp.min 8 3 0.25 || true
  writef_retry /dev/cpuctl/top-app/uclamp.min 12 3 0.25 || true

  [ -w /proc/sys/kernel/sched_util_clamp_min ] && \
    writef_retry /proc/sys/kernel/sched_util_clamp_min 0 3 0.25 || true
}
wait_path /dev/cpuset/background/cpus 8 || true
wait_path /dev/cpuctl/top-app 8 || true

apply_uclamp

if [ $IS_WILD -eq 0 ]; then
  apply_cpuset_groups
fi
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

  sysctlw vm.dirty_expire_centisecs 3000
  sysctlw vm.dirty_writeback_centisecs 3000
  sysctlw vm.vfs_cache_pressure 70

  [ -e /proc/sys/vm/compaction_proactiveness ] && sysctlw vm.compaction_proactiveness 0
  [ -e /proc/sys/vm/stat_interval ] && sysctlw vm.stat_interval 15

  writef_retry /proc/sys/vm/page-cluster 0 1 0 || true
  sysctlw vm.watermark_scale_factor 60
  sysctlw vm.min_free_kbytes 32768
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
  sysctlw net.ipv4.tcp_no_metrics_save 1
  sysctlw net.ipv4.tcp_recovery 1
  sysctlw net.ipv4.tcp_max_orphans 8192
  sysctlw net.ipv4.tcp_fin_timeout 30

  # keepalive defaults preserved for standby battery

  sysctlw net.core.somaxconn 512
  sysctlw net.ipv4.tcp_max_syn_backlog 2048
  sysctlw net.core.netdev_max_backlog 2000
  sysctlw net.core.netdev_budget 180
  sysctlw net.core.netdev_budget_usecs 5000
  sysctlw net.core.dev_weight 64

  sysctlw net.core.bpf_jit_enable 1

  [ -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established ] && \
  sysctlw net.netfilter.nf_conntrack_tcp_timeout_established 600
  [ -e /proc/sys/net/netfilter/nf_conntrack_buckets ] && \
  sysctlw net.netfilter.nf_conntrack_buckets 16384
  [ -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait ] && \
  sysctlw net.netfilter.nf_conntrack_tcp_timeout_time_wait 30

  sysctlw net.ipv4.tcp_syncookies 1
  sysctlw net.ipv4.tcp_rfc1337 1

  # security-sensitive JIT/filters left to ROM/kernel policy
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
  settings put global wifi_scan_always_enabled 0 >/dev/null 2>&1 || true
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
  [ -w /sys/class/kgsl/kgsl-3d0/idle_timer ] && \
    echo 80 > /sys/class/kgsl/kgsl-3d0/idle_timer 2>/dev/null || true
  if has settings; then
    settings put global activity_starts_logging_enabled 0 >/dev/null 2>&1 || true
    settings put global settings_enable_monitor_phantom_procs false >/dev/null 2>&1 || true
  fi
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

if has settings; then
  settings put global dropbox_max_files 8 2>/dev/null || true
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

for s in qseelogd wlanramdumpcollector mqsasd mtdoopslog debuggerd minidump minidump32 minidump64 bootstat poweroff_charger_log ostatsd charge_logger iorapd cnss_diag diag_mdlog diag_mdlog_start mmi-diag qcom-diag tftp_server tcpdump modem_svc logcat-debug; do
  svc_stop_guarded "$s"
done

if has stop && has start; then
fi

apply_zram() {
  [ -e /sys/block/zram0 ] || return 0
  HALF_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/2}' /proc/meminfo 2>/dev/null)
  [ -z "$HALF_MB" ] && return 0
  CPU_CORES=$(nproc 2>/dev/null || echo 8)

  swapoff /dev/block/zram0 >/dev/null 2>&1 || true
  echo 1 > /sys/block/zram0/reset 2>/dev/null || return 0
  sleep 2

  echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || \
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  echo "$CPU_CORES" > /sys/block/zram0/max_comp_streams 2>/dev/null || true
  [ -f /sys/block/zram0/use_dedup ] && echo 1 > /sys/block/zram0/use_dedup 2>/dev/null || true
  echo "${HALF_MB}M" > /sys/block/zram0/disksize 2>/dev/null || return 0
  echo 0 > /sys/block/zram0/queue/iostats 2>/dev/null || true
  echo 0 > /sys/block/zram0/queue/add_random 2>/dev/null || true

  mkswap /dev/block/zram0 >/dev/null 2>&1 && \
    swapon /dev/block/zram0 >/dev/null 2>&1 || true
}
apply_zram

if has stop && has start; then
fi

apply_extra_settings() {
  has settings || return 0
  settings put global audio_safe_volume_state 0 >/dev/null 2>&1 || true
  settings delete global netstats_enabled >/dev/null 2>&1 || true
  settings delete global app_usage_enabled >/dev/null 2>&1 || true
  settings delete global package_usage_stats_enabled >/dev/null 2>&1 || true
  settings put global bluetooth_voip_support 1 >/dev/null 2>&1 || true
  settings put global dropbox_max_files 5 >/dev/null 2>&1 || true
  settings put global network_recommendations_enabled 0 >/dev/null 2>&1 || true
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
  done
) >/dev/null 2>&1 &

exit 0
