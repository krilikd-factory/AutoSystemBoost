#!/system/bin/sh
# ASB Vendor Thermal Probe — Phase 1 Discovery
#
# READ-ONLY tool. Does NOT modify any system property, file, or driver state.
# Collects information about OEM thermal driver to help design future mitigations.
#
# Usage: as root:  sh /data/adb/modules/AutoSystemBoost/tools/asb_vendor_thermal_probe.sh
# Output: /sdcard/asb_vendor_probe_<timestamp>.txt

OUT="/sdcard/asb_vendor_probe_$(date +%Y%m%d_%H%M%S).txt"

{
  echo "===================="
  echo "ASB Vendor Thermal Probe — READ-ONLY"
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "===================="
  echo ""

  echo "===== DEVICE ====="
  getprop ro.product.model
  getprop ro.product.device
  getprop ro.product.name
  getprop ro.build.version.release
  getprop ro.build.display.id
  getprop ro.oxygen.version 2>/dev/null
  echo ""

  echo "===== ALL THERMAL-RELATED PROPS ====="
  getprop | grep -iE "thermal|powerhal|perf.+hint|cooling|throttle" 2>/dev/null
  echo ""

  echo "===== ALL OEM PROPS (vendor.*, sys.*, persist.*) ====="
  echo ""
  echo "--- vendor.* thermal/perf ---"
  getprop | grep -E "^\[vendor\." | grep -iE "thermal|perf|cpu|gpu|cooling"
  echo ""
  echo "--- sys.* thermal/perf ---"
  getprop | grep -E "^\[sys\." | grep -iE "thermal|perf|cpu|gpu|cooling"
  echo ""
  echo "--- persist.* thermal/perf (these survive reboot!) ---"
  getprop | grep -E "^\[persist\." | grep -iE "thermal|perf|cpu|gpu|cooling"
  echo ""
  echo "--- init.svc.* (active services) ---"
  getprop | grep -E "thermal|powerhal" | grep -i "init.svc"
  echo ""

  echo "===== THERMAL-ENGINE / POWERHAL SERVICES ====="
  ps -A 2>/dev/null | grep -iE "thermal|powerhal|hwpolicy" | grep -v grep
  echo ""
  echo "--- Service definitions ---"
  for f in /vendor/etc/init/thermal-engine.rc /vendor/etc/init/thermal-hal.rc /system_ext/etc/init/thermal.rc /odm/etc/init/thermal.rc; do
    [ -f "$f" ] && echo "FOUND: $f"
  done
  ls -la /vendor/bin/thermal-engine 2>/dev/null
  ls -la /vendor/bin/hw/android.hardware.thermal* 2>/dev/null
  ls -la /vendor/bin/hw/android.hardware.power* 2>/dev/null
  ls -la /system_ext/bin/thermal* 2>/dev/null
  echo ""

  echo "===== VENDOR THERMAL CONFIG FILES ====="
  for f in /vendor/etc/thermal-engine.conf /vendor/etc/thermal-engine-9450.conf /odm/etc/thermal-engine.conf; do
    [ -f "$f" ] && echo "FOUND: $f ($(wc -c < "$f") bytes)"
  done
  ls -la /vendor/etc/thermal* 2>/dev/null
  ls -la /odm/etc/thermal* 2>/dev/null
  echo ""

  echo "===== /proc/thermal_message (Qualcomm specific) ====="
  for f in /proc/thermal_message /sys/class/thermal/thermal_message; do
    [ -e "$f" ] && { echo "EXISTS: $f"; ls -la "$f" 2>/dev/null; }
  done
  echo ""

  echo "===== KERNEL THERMAL ZONES ====="
  for tz in /sys/class/thermal/thermal_zone*; do
    [ -d "$tz" ] || continue
    n=$(basename "$tz")
    type=$(cat "$tz/type" 2>/dev/null)
    temp=$(cat "$tz/temp" 2>/dev/null)
    mode=$(cat "$tz/mode" 2>/dev/null)
    policy=$(cat "$tz/policy" 2>/dev/null)
    echo "$n: type=$type temp=$temp mode=$mode policy=$policy"
  done
  echo ""

  echo "===== KERNEL COOLING DEVICES ====="
  for cd in /sys/class/thermal/cooling_device*; do
    [ -d "$cd" ] || continue
    n=$(basename "$cd")
    type=$(cat "$cd/type" 2>/dev/null)
    cur=$(cat "$cd/cur_state" 2>/dev/null)
    max=$(cat "$cd/max_state" 2>/dev/null)
    echo "$n: type=$type cur_state=$cur/$max"
  done
  echo ""

  echo "===== /proc/sys/kernel/ thermal-related ====="
  ls -la /proc/sys/kernel/ 2>/dev/null | grep -iE "thermal|power" | head -10
  echo ""

  echo "===== CURRENT SCALING_MAX_FREQ (vendor may clamp these) ====="
  for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy" ] || continue
    n=$(basename "$policy")
    max=$(cat "$policy/scaling_max_freq" 2>/dev/null)
    hw_max=$(cat "$policy/cpuinfo_max_freq" 2>/dev/null)
    cur=$(cat "$policy/scaling_cur_freq" 2>/dev/null)
    echo "$n: scaling_max=$max  hw_max=$hw_max  scaling_cur=$cur"
  done
  echo ""

  echo "===== GPU THERMAL PWRLEVEL ====="
  for f in /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel /sys/class/kgsl/kgsl-3d0/num_pwrlevels /sys/class/kgsl/kgsl-3d0/devfreq/min_freq /sys/class/kgsl/kgsl-3d0/devfreq/max_freq; do
    [ -e "$f" ] && echo "$f = $(cat $f 2>/dev/null)"
  done
  echo ""

  echo "===== SYS PROPS that MAY control thermal ====="
  echo "These are commonly used on Snapdragon devices:"
  echo ""
  for prop in \
    vendor.thermal.config \
    persist.vendor.thermal.config \
    persist.sys.thermal_throttle \
    persist.vendor.cooler.enable \
    vendor.thermal-engine.enabled \
    persist.thermal.engine.enabled \
    init.svc.thermal-engine \
    init.svc.thermal-hal \
    init.svc.vendor.thermal-engine \
    init.svc.thermal-engine-mtk \
    persist.vendor.qti.thermal.config \
    persist.sys.dynamic_resolution_enable \
    debug.sf.disable_backpressure \
    debug.thermal.mode; do
    v=$(getprop "$prop" 2>/dev/null)
    [ -n "$v" ] && echo "$prop = $v"
  done
  echo ""

  echo "===== SELINUX STATUS ====="
  getenforce 2>/dev/null
  echo ""

  echo "===== TOP CPU CONSUMERS (snapshot, may catch thermal-engine) ====="
  top -bn1 -m 15 2>/dev/null | head -25
  echo ""

  echo "===== ASB STATE SNAPSHOT ====="
  cat /dev/.asb/state 2>/dev/null | head -1
  echo ""
  cat /dev/.asb/conflicts.json 2>/dev/null
  echo ""

  echo "===== DONE ====="
} > "$OUT" 2>&1

chmod 0644 "$OUT" 2>/dev/null
echo "Probe complete: $OUT"
echo ""
echo "Send this file back for Phase 2 analysis."
echo "DOES NOT contain personal data — only system thermal driver state."
