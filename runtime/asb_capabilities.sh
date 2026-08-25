#!/system/bin/sh
# asb_capabilities.sh — on-demand, read-only hardware capability manifest.
#
# Do not assume a node is usable simply because it exists. This probe records
# the nodes ASB can see; policy writers and diagnostics can use it to explain
# why a device-specific feature is unavailable. It runs once on demand/boot,
# not in the governor tick.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
STATE="${ASB_CAP_STATE:-/data/adb/asb}"
OUT="${ASB_CAP_MANIFEST:-$STATE/capabilities.env}"

_die() { echo "asb_capabilities: $*" >&2; exit 1; }
_num_or_zero() { case "$1" in ''|*[!0-9-]*) echo 0 ;; *) echo "$1" ;; esac; }

_probe() {
  mkdir -p "$STATE" 2>/dev/null || _die "cannot create state directory"
  _tmp="$OUT.tmp.$$"
  _now="$(date +%s 2>/dev/null || echo 0)"
  _policies=0; _opp_complete=1; _cpu_nodes=0
  _min_freq=0; _max_freq=0
  for _p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_p" ] || continue
    _policies=$((_policies + 1))
    [ -r "$_p/scaling_max_freq" ] && _cpu_nodes=$((_cpu_nodes + 1))
    _avail="$(tr ' ' '\n' < "$_p/scaling_available_frequencies" 2>/dev/null | awk 'NF && $1 ~ /^[0-9]+$/ {print}' | sort -n)"
    [ -n "$_avail" ] || _opp_complete=0
    _lo="$(printf '%s\n' "$_avail" | head -1)"; _hi="$(printf '%s\n' "$_avail" | tail -1)"
    case "$_lo" in ''|*[!0-9]*) ;; *) [ "$_min_freq" -eq 0 ] || [ "$_lo" -lt "$_min_freq" ] && _min_freq="$_lo" ;; esac
    case "$_hi" in ''|*[!0-9]*) ;; *) [ "$_hi" -gt "$_max_freq" ] && _max_freq="$_hi" ;; esac
  done

  _cg_v1=0; [ -d /dev/cpuctl ] || [ -d /dev/cpuset ] && _cg_v1=1
  _cg_v2=0; [ -r /sys/fs/cgroup/cgroup.controllers ] && _cg_v2=1
  _uclamp=0; [ -e /dev/cpuctl/top-app/cpu.uclamp.max ] || [ -e /sys/fs/cgroup/top-app/cpu.uclamp.max ] && _uclamp=1
  _thermal=0; [ -d /sys/class/thermal ] && _thermal=1
  _thermal_headroom=0
  for _h in /sys/class/thermal/thermal_zone*/temp /sys/devices/virtual/thermal/thermal_zone*/temp; do [ -r "$_h" ] && { _thermal_headroom=1; break; }; done
  _battery_current=0
  for _b in /sys/class/power_supply/battery/current_now /sys/class/power_supply/battery/current_avg /sys/class/power_supply/battery/constant_charge_current; do [ -r "$_b" ] && { _battery_current=1; break; }; done
  _gpu=0
  # Probe only graphics-named devfreq directories. Generic devfreq also exposes memory/ISP/NPU
  # nodes, which must never be treated as a GPU capability merely because they have max_freq.
  for _g in /sys/class/kgsl/kgsl-3d0/devfreq/max_freq \
            /sys/class/devfreq/*gpu*/max_freq /sys/class/devfreq/*mali*/max_freq \
            /sys/class/devfreq/*powervr*/max_freq /sys/class/devfreq/*xclipse*/max_freq \
            /sys/class/devfreq/*adreno*/max_freq /sys/class/devfreq/*kgsl*/max_freq; do
    [ -e "$_g" ] && { _gpu=1; break; }
  done
  _camera=0; [ -d /dev/cpuset/foreground ] || [ -d /sys/fs/cgroup/foreground ] && _camera=1

  {
    echo "schema=1"
    echo "generated_at=$_now"
    echo "cpu_policy_count=$_policies"
    echo "cpu_scaling_nodes=$_cpu_nodes"
    echo "cpu_opp_complete=$_opp_complete"
    echo "cpu_min_freq=$_min_freq"
    echo "cpu_max_freq=$_max_freq"
    echo "cgroup_v1=$_cg_v1"
    echo "cgroup_v2=$_cg_v2"
    echo "uclamp=$_uclamp"
    echo "thermal_sensors=$_thermal"
    echo "thermal_headroom_source=$_thermal_headroom"
    echo "battery_current=$_battery_current"
    echo "gpu_devfreq=$_gpu"
    echo "camera_cpuset=$_camera"
  } > "$_tmp" || { rm -f "$_tmp"; _die "cannot write manifest"; }
  chmod 0644 "$_tmp" 2>/dev/null || true
  mv -f "$_tmp" "$OUT" || _die "cannot replace manifest"
  cat "$OUT"
}

case "${1:-probe}" in
  probe) _probe ;;
  show) [ -r "$OUT" ] || _die "manifest unavailable; run probe"; cat "$OUT" ;;
  *) _die "usage: $0 [probe|show]" ;;
esac
