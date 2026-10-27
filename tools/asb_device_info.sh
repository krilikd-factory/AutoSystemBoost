#!/system/bin/sh
# ASB Device page: on-demand, read-only device / firmware / kernel evidence.
# No settings are sourced, no writers are called and no background job is left behind.
# Output: D<TAB>section<TAB>key<TAB>value (one record per line).

MODDIR="${ASB_DEVINFO_MODDIR:-/data/adb/modules/AutoSystemBoost}"
SYS="${ASB_DEVINFO_SYS:-/sys}"
PROC="${ASB_DEVINFO_PROC:-/proc}"
DATA="${ASB_DEVINFO_DATA:-/data/adb}"
PROP_FILE="${ASB_DEVINFO_PROP_FILE:-}"
SUSFS_BIN="${ASB_DEVINFO_SUSFS:-/data/adb/ksu/bin/susfs}"
STATE_FILE="${ASB_DEVINFO_STATE:-/dev/.asb/state}"

_clean() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-600
}
_emit() {
  [ -n "$1" ] && [ -n "$2" ] || return 0
  _v="$(_clean "$3")"
  [ -n "$_v" ] || _v='—'
  printf 'D\t%s\t%s\t%s\n' "$1" "$2" "$_v"
}
_read() { [ -r "$1" ] && cat "$1" 2>/dev/null; }
_read_first() {
  for _rf in "$@"; do
    _rv="$(_read "$_rf")"
    if [ -n "$_rv" ]; then printf '%s\n' "$_rv"; return 0; fi
  done
  return 0
}
_prop() {
  if [ -n "$PROP_FILE" ] && [ -r "$PROP_FILE" ]; then
    sed -n "s/^\[$1\]: \[\(.*\)\]$/\1/p" "$PROP_FILE" 2>/dev/null | head -n 1
  elif command -v getprop >/dev/null 2>&1; then
    getprop "$1" 2>/dev/null
  fi
}
_kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
_mem() { sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n 1; }

_emit meta schema 2
_emit meta generated_epoch "$(date +%s 2>/dev/null)"
_emit meta access read_only
_emit meta module_version "$(_kv "$MODDIR/module.prop" version)"
_emit meta module_version_code "$(_kv "$MODDIR/module.prop" versionCode)"

# Firmware and ROM identity. No serial number, IMEI, account or network identifier is read.
for _spec in \
  'brand:ro.product.brand' 'manufacturer:ro.product.manufacturer' \
  'model:ro.product.model' 'device:ro.product.device' 'product:ro.product.name' \
  'market_name:ro.product.market.name' 'board:ro.product.board' \
  'android:ro.build.version.release' 'sdk:ro.build.version.sdk' \
  'codename:ro.build.version.codename' 'security_patch:ro.build.version.security_patch' \
  'build_id:ro.build.id' 'build_display:ro.build.display.id' \
  'build_incremental:ro.build.version.incremental' 'build_type:ro.build.type' \
  'build_tags:ro.build.tags' 'build_date:ro.build.date.utc' \
  'base_os:ro.build.version.base_os' 'fingerprint:ro.build.fingerprint' \
  'oplus_rom:ro.build.version.oplusrom' 'oplus_ota:ro.build.version.ota' \
  'vendor_incremental:ro.vendor.build.version.incremental' \
  'baseband:gsm.version.baseband' 'bootloader:ro.bootloader'; do
  _k="${_spec%%:*}"; _p="${_spec#*:}"
  _v="$(_prop "$_p")"
  [ -n "$_v" ] && _emit firmware "$_k" "$_v"
done

for _spec in \
  'soc_model:ro.soc.model' 'soc_manufacturer:ro.soc.manufacturer' \
  'platform:ro.board.platform' 'chipname:ro.hardware.chipname' \
  'hardware:ro.hardware' 'boot_hardware:ro.boot.hardware' \
  'abi:ro.product.cpu.abi' 'abilist:ro.product.cpu.abilist' \
  'zygote:ro.zygote'; do
  _k="${_spec%%:*}"; _v="$(_prop "${_spec#*:}")"
  [ -n "$_v" ] && _emit soc "$_k" "$_v"
done
_emit soc cpu_online "$(_read "$SYS/devices/system/cpu/online")"
_emit soc cpu_present "$(_read "$SYS/devices/system/cpu/present")"
_emit soc cpu_possible "$(_read "$SYS/devices/system/cpu/possible")"
_emit soc hardware_cpuinfo "$(sed -n 's/^Hardware[[:space:]]*:[[:space:]]*//p' "$PROC/cpuinfo" 2>/dev/null | head -n 1)"

# Kernel build evidence, including the Brene-inspired uname consistency check.
_uname_r="$(uname -r 2>/dev/null)"
_uname_a="$(uname -srmo 2>/dev/null)"
_proc_version="$(_read "$PROC/version")"
_proc_release="$(printf '%s\n' "$_proc_version" | awk 'NR==1 {print $3}')"
_emit kernel release "$_uname_r"
_emit kernel proc_release "$_proc_release"
_emit kernel uname "$_uname_a"
_emit kernel build "$_proc_version"
if [ -n "$_uname_r" ] && [ -n "$_proc_release" ]; then
  if [ "$_uname_r" = "$_proc_release" ]; then _emit kernel uname_consistency match
  else _emit kernel uname_consistency mismatch; fi
fi
_emit kernel cmdline "$(_read "$PROC/cmdline")"

# Optional SuSFS interface: exactly the three read-only show commands used by Brene.
# Absence is normal and no conclusion about the kernel is drawn from it.
if [ -x "$SUSFS_BIN" ]; then
  _sv="$("$SUSFS_BIN" show version 2>/dev/null)"
  _st="$("$SUSFS_BIN" show variant 2>/dev/null)"
  _sf="$("$SUSFS_BIN" show enabled_features 2>/dev/null | tr '\n' ' ')"
  if [ -n "$_sv$_st$_sf" ]; then _susfs_state='available'; else _susfs_state='present_no_read_response'; fi
  _emit susfs interface "$_susfs_state"
  [ -n "$_sv" ] && _emit susfs version "$_sv"
  [ -n "$_st" ] && _emit susfs variant "$_st"
  [ -n "$_sf" ] && _emit susfs enabled_features "$_sf"
else
  _susfs_state='unavailable'
  _emit susfs interface unavailable
fi

# Reuse ASB's existing read-only external kernel/UV evidence helper when shipped.
if [ -r "$MODDIR/tools/asb_kernel_uv_coexist.sh" ]; then
  _uv="$(ASB_SYSROOT="$SYS" ASB_MODULES_ROOT="$DATA/modules" ${PROP_FILE:+ASB_PROP_FILE="$PROP_FILE"} sh "$MODDIR/tools/asb_kernel_uv_coexist.sh" 2>/dev/null)"
  for _k in status confidence reason evidence_count evidence asb_voltage_owner asb_action; do
    _v="$(printf '%s\n' "$_uv" | sed -n "s/^$_k=//p" | head -n 1)"
    [ -n "$_v" ] && _emit kernel_external "$_k" "$_v"
  done
fi

# A bounded whitelist of useful kernel configuration features, when the kernel exposes it.
_cfg=''
if [ -r "$PROC/config.gz" ]; then
  if command -v zcat >/dev/null 2>&1; then _cfg="$(zcat "$PROC/config.gz" 2>/dev/null)"
  elif command -v gzip >/dev/null 2>&1; then _cfg="$(gzip -dc "$PROC/config.gz" 2>/dev/null)"
  elif command -v toybox >/dev/null 2>&1; then _cfg="$(toybox zcat "$PROC/config.gz" 2>/dev/null)"; fi
fi
_cfg_val() {
  [ -n "$_cfg" ] || return 0
  _cv="$(printf '%s\n' "$_cfg" | sed -n "s/^$1=//p" | head -n 1)"
  if [ -z "$_cv" ] && printf '%s\n' "$_cfg" | grep -q "^# $1 is not set$"; then _cv='not set'; fi
  printf '%s\n' "$_cv"
}
_cfg_keys='CONFIG_LOCALVERSION CONFIG_PREEMPT CONFIG_PREEMPT_DYNAMIC CONFIG_HZ CONFIG_SCHED_WALT CONFIG_SCHEDUTIL CONFIG_CPU_FREQ_GOV_SCHEDUTIL CONFIG_CPU_FREQ_GOV_PERFORMANCE CONFIG_CPU_FREQ_GOV_POWERSAVE CONFIG_CPU_BOOST CONFIG_LRU_GEN CONFIG_LRU_GEN_ENABLED CONFIG_ZRAM CONFIG_ZSWAP CONFIG_ZSMALLOC CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND CONFIG_DEVFREQ_GOV_MSM_ADRENO_TZ CONFIG_KGSL CONFIG_TCP_CONG_BBR CONFIG_TCP_CONG_BBR2 CONFIG_TCP_CONG_BBRV2 CONFIG_TCP_CONG_WESTWOOD CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_NOMOUNT CONFIG_NTSYNC CONFIG_NAMESPACES CONFIG_SYSVIPC CONFIG_POSIX_MQUEUE CONFIG_IPC_NS CONFIG_PID_NS CONFIG_NET_NS CONFIG_UTS_NS CONFIG_USER_NS CONFIG_CGROUPS CONFIG_DEVTMPFS CONFIG_DROIDSPACES CONFIG_DROIDSPACE CONFIG_UNICODE CONFIG_UNICODE_BYPASS_FIX CONFIG_UNICODE_BYPASS CONFIG_TMPFS CONFIG_TMPFS_XATTR CONFIG_TMPFS_POSIX_ACL CONFIG_TMPFS_INODE64 CONFIG_LTO CONFIG_LTO_CLANG CONFIG_LTO_CLANG_THIN CONFIG_LTO_CLANG_FULL CONFIG_LTO_NONE CONFIG_BBG CONFIG_SECURITY_BASEBAND_GUARD CONFIG_BASEBAND_GUARD CONFIG_LSM'
if [ -n "$_cfg" ]; then
  _emit kernel_config available yes
  for _k in $_cfg_keys; do
    _v="$(_cfg_val "$_k")"
    [ -n "$_v" ] && _emit kernel_config "$_k" "$_v"
  done
else
  _emit kernel_config available unavailable
fi

# Normalised feature summary. "unknown" means that the running kernel exposes no
# reliable read-only evidence; it never means that the feature is absent.
_feature_state() {
  _fs_val="$(_cfg_val "$1")"
  case "$_fs_val" in
    y) printf 'built-in\n' ;;
    m) if [ -d "$2" ]; then printf 'module loaded\n'; else printf 'module not loaded\n'; fi ;;
    'not set') if [ -d "$2" ]; then printf 'driver present\n'; else printf 'disabled\n'; fi ;;
    *) if [ -d "$2" ]; then printf 'driver present\n'; else printf 'unknown\n'; fi ;;
  esac
}
_emit kernel_features nomount "$(_feature_state CONFIG_NOMOUNT "$SYS/module/nomount")"
_nm_ver="$(_read "$SYS/module/nomount/version")"
_emit kernel_features nomount_version "${_nm_ver:-not exposed}"
_emit kernel_features ntsync "$(_feature_state CONFIG_NTSYNC "$SYS/module/ntsync")"

# Droidspaces has no single standard runtime switch. Report only its core kernel
# configuration evidence, including exactly what is missing; do not claim a container works.
_ds_missing=''
for _k in NAMESPACES SYSVIPC POSIX_MQUEUE IPC_NS PID_NS NET_NS UTS_NS DEVTMPFS; do
  [ "$(_cfg_val "CONFIG_$_k")" = 'y' ] || _ds_missing="$_ds_missing $_k"
done
if [ -z "$_cfg" ]; then
  _emit kernel_features droidspaces unknown
elif [ -z "$_ds_missing" ]; then
  _emit kernel_features droidspaces 'core config present; runtime not verified'
else
  _emit kernel_features droidspaces "partial; missing:${_ds_missing}"
fi

_unicode_state="$(_feature_state CONFIG_UNICODE_BYPASS_FIX "$SYS/module/unicode_bypass_fix")"
case "$_unicode_state" in built-in|module*|driver*) ;; *)
  _unicode_state="$(_feature_state CONFIG_UNICODE_BYPASS "$SYS/module/unicode_bypass")" ;; esac
case "$_unicode_state" in
  built-in|module*|driver*) _emit kernel_features unicode_bypass_fix "$_unicode_state" ;;
  *)
    _emit kernel_features unicode_bypass_fix 'not runtime-discoverable'
    _emit kernel_features unicode_bypass_evidence 'no standard read-only indicator; CONFIG_UNICODE alone is not proof' ;;
esac

_tmp_x="$(_cfg_val CONFIG_TMPFS_XATTR)"
_tmp_a="$(_cfg_val CONFIG_TMPFS_POSIX_ACL)"
if [ -z "$_cfg" ]; then _tmp_state='unknown'
elif [ "$_tmp_x" = 'y' ] && [ "$_tmp_a" = 'y' ]; then _tmp_state='supported'
else _tmp_state="partial; XATTR=${_tmp_x:-unknown}; POSIX_ACL=${_tmp_a:-unknown}"; fi
_emit kernel_features tmpfs_xattr_posix_acl "$_tmp_state"

_lto='unknown'
for _spec in 'LTO_CLANG_THIN:ThinLTO (Clang)' 'LTO_CLANG_FULL:Full LTO (Clang)' 'LTO_CLANG:LTO (Clang)' 'LTO:LTO'; do
  [ "$(_cfg_val "CONFIG_${_spec%%:*}")" = 'y' ] || continue
  _lto="${_spec#*:}"; break
done
[ "$_lto" = 'unknown' ] && [ "$(_cfg_val CONFIG_LTO_NONE)" = 'y' ] && _lto='disabled'
_emit kernel_features lto "$_lto"

_tcp_avail=" $(_read "$PROC/sys/net/ipv4/tcp_available_congestion_control") "
_bbr1='unknown'; _bbr2='unknown'
case "$_tcp_avail" in *' bbr '*) _bbr1='available' ;; esac
case "$_tcp_avail" in *' bbr2 '*|*' bbrv2 '*) _bbr2='available' ;; esac
if [ "$_bbr1" = 'unknown' ]; then
  case "$(_cfg_val CONFIG_TCP_CONG_BBR)" in y|m) _bbr1='configured' ;; 'not set') _bbr1='disabled' ;; esac
fi
if [ "$_bbr2" = 'unknown' ]; then
  case "$(_cfg_val CONFIG_TCP_CONG_BBR2)$(_cfg_val CONFIG_TCP_CONG_BBRV2)" in *y*|*m*) _bbr2='configured' ;; *'not set'*) _bbr2='disabled' ;; esac
fi
_emit kernel_features bbr_v1 "$_bbr1"
_emit kernel_features bbr_v2 "$_bbr2"

_bbg='unknown'; _bbg_all_not_set=1
for _k in BBG SECURITY_BASEBAND_GUARD BASEBAND_GUARD; do
  _bv="$(_cfg_val "CONFIG_$_k")"
  case "$_bv" in
    y) _bbg='built-in'; break ;;
    m) _bbg="$(_feature_state "CONFIG_$_k" "$SYS/module/baseband_guard")"; break ;;
    'not set') ;;
    *) _bbg_all_not_set=0 ;;
  esac
done
# A runtime module directory must not mask a positive built-in config from another
# accepted BBG config name. Use it only when no explicit config evidence won above.
if [ "$_bbg" = 'unknown' ]; then
  if [ -d "$SYS/module/baseband_guard" ]; then _bbg='driver present'
  elif [ -n "$_cfg" ] && [ "$_bbg_all_not_set" = 1 ]; then _bbg='disabled'; fi
fi
_lsm="$(_cfg_val CONFIG_LSM)"
case "$_lsm" in *baseband_guard*) _bbg="active in LSM; $_bbg" ;; esac
_emit kernel_features bbg_baseband_guard "$_bbg"

if [ "${_susfs_state:-unavailable}" = 'available' ]; then
  _emit kernel_features susfs 'interface available'
else
  _emit kernel_features susfs "$(_feature_state CONFIG_KSU_SUSFS "$SYS/module/susfs")"
fi
_emit kernel_features susfs_version "${_sv:-not exposed}"

# Live kernel facilities (reads only).
for _spec in \
  'mglru_enabled:/sys/kernel/mm/lru_gen/enabled' \
  'mglru_min_ttl_ms:/sys/kernel/mm/lru_gen/min_ttl_ms' \
  'sched_clamp_min:/proc/sys/kernel/sched_util_clamp_min' \
  'sched_clamp_max:/proc/sys/kernel/sched_util_clamp_max' \
  'swappiness:/proc/sys/vm/swappiness' \
  'tcp_congestion:/proc/sys/net/ipv4/tcp_congestion_control' \
  'tcp_available_congestion:/proc/sys/net/ipv4/tcp_available_congestion_control' \
  'default_qdisc:/proc/sys/net/core/default_qdisc'; do
  _k="${_spec%%:*}"; _p="${_spec#*:}"; case "$_p" in /sys/*) _f="$SYS${_p#/sys}" ;; *) _f="$PROC${_p#/proc}" ;; esac
  _v="$(_read "$_f")"; [ -n "$_v" ] && _emit kernel_runtime "$_k" "$_v"
done

# Every exposed cpufreq policy, with hardware and current bounds kept distinct.
for _d in "$SYS"/devices/system/cpu/cpufreq/policy*; do
  [ -d "$_d" ] || continue
  _p="${_d##*/}"
  _v="cpus=$(_read "$_d/related_cpus"); governor=$(_read "$_d/scaling_governor"); current_khz=$(_read "$_d/scaling_cur_freq"); scaling_min_khz=$(_read "$_d/scaling_min_freq"); scaling_max_khz=$(_read "$_d/scaling_max_freq"); hardware_min_khz=$(_read "$_d/cpuinfo_min_freq"); hardware_max_khz=$(_read "$_d/cpuinfo_max_freq")"
  _emit cpu_policy "$_p" "$_v"
done

# Adreno and generic devfreq GPU backends; no assumptions about a particular SoC.
_gpu_dirs=''
for _d in "$SYS/class/kgsl/kgsl-3d0" "$SYS"/class/devfreq/*gpu*; do
  [ -d "$_d" ] || continue
  case " $_gpu_dirs " in *" $_d "*) continue ;; esac
  _gpu_dirs="$_gpu_dirs $_d"
  _name="${_d##*/}"
  _governor="$(_read_first "$_d/devfreq/governor" "$_d/governor")"
  _current="$(_read_first "$_d/devfreq/cur_freq" "$_d/cur_freq")"
  _min="$(_read_first "$_d/devfreq/min_freq" "$_d/min_freq")"
  _max="$(_read_first "$_d/devfreq/max_freq" "$_d/max_freq")"
  _busy="$(_read_first "$_d/gpubusy" "$_d/gpu_busy_percentage")"
  _v="governor=$_governor; current_hz=$_current; min_hz=$_min; max_hz=$_max; busy=$_busy"
  _emit gpu "$_name" "$_v"
done

for _k in MemTotal MemAvailable Buffers Cached SwapTotal SwapFree; do
  _v="$(_mem "$PROC/meminfo" "$_k")"; [ -n "$_v" ] && _emit memory "$_k" "$_v"
done
for _spec in \
  'capacity:capacity' 'status:status' 'technology:technology' 'health:health' \
  'temp_tenths_c:temp' 'current_ua:current_now' 'voltage_uv:voltage_now' \
  'charge_full_uah:charge_full' 'charge_full_design_uah:charge_full_design'; do
  _k="${_spec%%:*}"; _v="$(_read "$SYS/class/power_supply/battery/${_spec#*:}")"
  [ -n "$_v" ] && _emit battery "$_k" "$_v"
done
_emit system uptime "$(_read "$PROC/uptime")"
_emit system loadavg "$(_read "$PROC/loadavg")"

# ASB runtime facts: a whitelist, never an eval or arbitrary file import.
for _k in profile state state_warmup smart_mode thermal cap_owner device_bounds_applied device_bounds_status device_bounds_reason; do
  _v="$(_kv "$STATE_FILE" "$_k")"; [ -n "$_v" ] && _emit asb "$_k" "$_v"
done
_caps="$DATA/asb/device_caps.env"
for _k in android_api kernel soc model device topology policy_count; do
  _v="$(_kv "$_caps" "$_k")"; [ -n "$_v" ] && _emit asb_caps "$_k" "$_v"
done
exit 0
