#!/system/bin/sh
# apply_profile.sh — live profile switcher for ASB WebUI
MODDIR="${0%/*}"
[ -z "$MODDIR" ] || [ "$MODDIR" = "$0" ] && MODDIR="/data/adb/modules/AutoSystemBoost"
PROFILE="${1:-balanced}"

has() { command -v "$1" >/dev/null 2>&1; }
writef() { [ -w "$1" ] && echo "$2" > "$1" 2>/dev/null; }
asb_update_desc() {
  case "$1" in
    performance) _s="description=status: performance 🔥 | active ✅ | gaming tuned" ;;
    battery) _s="description=status: battery 🔋 | active ✅ | standby focused" ;;
    *) _s="description=status: balanced ⚖️ | active ✅ | default profile" ;;
  esac
  sed "s/^description=.*/$_s/g" "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null || true
  grep -q "^description=" "$MODDIR/module.prop.tmp" 2>/dev/null && cat "$MODDIR/module.prop.tmp" > "$MODDIR/module.prop"
  rm -f "$MODDIR/module.prop.tmp"
}

case "$PROFILE" in
  performance)
    R=2 IE=22 IEC="22 22" CU=28 CUC="28 28" CO=24
    PU=4 PN=4 PS=2 CL=1363200 CB=1478400
    SW=40 DE=900 DW=700 GT=70 BH=10000000
    EB=24 TW=125 MTB=24 SB=1 UBG=8 UFG=24 UTOP=72 ;;
  battery)
    R=6 IE=80 IEC="80 80" CU=80 CUC="80 80" CO=72
    PU=52 PN=52 PS=44 CL=384000 CB=768000
    SW=60 DE=24000 DW=20000 GT=650 BH=0
    EB=0 TW=86 MTB=96 SB=0 UBG=0 UFG=6 UTOP=24 ;;
  *)
    PROFILE=balanced
    R=3 IE=45 IEC="45 45" CU=45 CUC="45 45" CO=40
    PU=20 PN=20 PS=0 CL=384000 CB=768000
    SW=20 DE=6000 DW=5000 GT=250 BH=0
    EB=10 TW=105 MTB=51 SB=0 UBG=0 UFG=15 UTOP=45 ;;
esac

echo "$PROFILE" > "$MODDIR/current_profile"
asb_update_desc "$PROFILE"

# WALT scheduler
[ -e /proc/sys/walt/sched_ravg_window_nr_ticks ] && echo "$R" > /proc/sys/walt/sched_ravg_window_nr_ticks
[ -e /proc/sys/walt/sched_idle_enough ] && echo "$IE" > /proc/sys/walt/sched_idle_enough
[ -e /proc/sys/walt/sched_idle_enough_clust ] && echo "$IEC" > /proc/sys/walt/sched_idle_enough_clust
[ -e /proc/sys/walt/sched_cluster_util_thres_pct ] && echo "$CU" > /proc/sys/walt/sched_cluster_util_thres_pct
[ -e /proc/sys/walt/sched_cluster_util_thres_pct_clust ] && echo "$CUC" > /proc/sys/walt/sched_cluster_util_thres_pct_clust
[ -e /proc/sys/walt/sched_min_task_util_for_colocation ] && echo "$CO" > /proc/sys/walt/sched_min_task_util_for_colocation
[ -e /proc/sys/walt/sched_busy_hyst_ns ] && echo "$BH" > /proc/sys/walt/sched_busy_hyst_ns
[ -e /proc/sys/walt/sched_boost ] && echo "$SB" > /proc/sys/walt/sched_boost
[ -e /proc/sys/walt/sched_pipeline_util_thres ] && echo "$PU" > /proc/sys/walt/sched_pipeline_util_thres
[ -e /proc/sys/walt/sched_pipeline_non_special_task_util_thres ] && echo "$PN" > /proc/sys/walt/sched_pipeline_non_special_task_util_thres
[ -e /proc/sys/walt/sched_pipeline_special_task_util_thres ] && echo "$PS" > /proc/sys/walt/sched_pipeline_special_task_util_thres
[ -e /proc/sys/walt/sched_ed_boost ] && echo "$EB" > /proc/sys/walt/sched_ed_boost
[ -e /proc/sys/walt/sched_topapp_weight_pct ] && echo "$TW" > /proc/sys/walt/sched_topapp_weight_pct
[ -e /proc/sys/walt/sched_min_task_util_for_boost ] && echo "$MTB" > /proc/sys/walt/sched_min_task_util_for_boost

# CPU freq floors
[ -w /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq ] && echo "$CL" > /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq
[ -w /sys/devices/system/cpu/cpufreq/policy6/scaling_min_freq ] && echo "$CB" > /sys/devices/system/cpu/cpufreq/policy6/scaling_min_freq
[ -w /dev/cpuctl/background/cpu.uclamp.min ] && echo "$UBG" > /dev/cpuctl/background/cpu.uclamp.min 2>/dev/null
[ -w /dev/cpuctl/system-background/cpu.uclamp.min ] && echo "$UBG" > /dev/cpuctl/system-background/cpu.uclamp.min 2>/dev/null
[ -w /dev/cpuctl/foreground/cpu.uclamp.min ] && echo "$UFG" > /dev/cpuctl/foreground/cpu.uclamp.min 2>/dev/null
[ -w /dev/cpuctl/top-app/cpu.uclamp.min ] && echo "$UTOP" > /dev/cpuctl/top-app/cpu.uclamp.min 2>/dev/null
[ -w /dev/cpuctl/background/uclamp.min ] && echo "$UBG" > /dev/cpuctl/background/uclamp.min 2>/dev/null
[ -w /dev/cpuctl/system-background/uclamp.min ] && echo "$UBG" > /dev/cpuctl/system-background/uclamp.min 2>/dev/null
[ -w /dev/cpuctl/foreground/uclamp.min ] && echo "$UFG" > /dev/cpuctl/foreground/uclamp.min 2>/dev/null
[ -w /dev/cpuctl/top-app/uclamp.min ] && echo "$UTOP" > /dev/cpuctl/top-app/uclamp.min 2>/dev/null

# VM
has sysctl && {
  sysctl -w vm.swappiness="$SW" 2>/dev/null
  sysctl -w vm.dirty_expire_centisecs="$DE" 2>/dev/null
  sysctl -w vm.dirty_writeback_centisecs="$DW" 2>/dev/null
}

# GPU
[ -w /sys/class/kgsl/kgsl-3d0/idle_timer ] && echo "$GT" > /sys/class/kgsl/kgsl-3d0/idle_timer

echo "Profile applied: $PROFILE"
exit 0
