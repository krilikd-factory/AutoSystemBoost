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
KSUD_BIN="${ASB_DEVINFO_KSUD:-}"
STATE_FILE="${ASB_DEVINFO_STATE:-/dev/.asb/state}"
DEV="${ASB_DEVINFO_DEV:-/dev}"

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

# Shared, read-only collectors. Both run only for this explicit snapshot and leave no worker.
[ -r "$MODDIR/runtime/asb_pressure.sh" ] && . "$MODDIR/runtime/asb_pressure.sh"
[ -r "$MODDIR/runtime/asb_zygisk_info.sh" ] && . "$MODDIR/runtime/asb_zygisk_info.sh"
[ -r "$MODDIR/runtime/asb_lsposed_info.sh" ] && . "$MODDIR/runtime/asb_lsposed_info.sh"
if [ "${1:-}" = --lsposed ]; then
  _emit meta schema 5
  command -v _asb_lsposed_info >/dev/null 2>&1 && _asb_lsposed_info
  exit 0
fi

_emit meta schema 5
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
_cfg_keys='CONFIG_LOCALVERSION CONFIG_PREEMPT CONFIG_PREEMPT_DYNAMIC CONFIG_HZ CONFIG_SCHED_WALT CONFIG_SCHEDUTIL CONFIG_CPU_FREQ_GOV_SCHEDUTIL CONFIG_CPU_FREQ_GOV_PERFORMANCE CONFIG_CPU_FREQ_GOV_POWERSAVE CONFIG_CPU_BOOST CONFIG_LRU_GEN CONFIG_LRU_GEN_ENABLED CONFIG_ZRAM CONFIG_ZSWAP CONFIG_ZSMALLOC CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND CONFIG_DEVFREQ_GOV_MSM_ADRENO_TZ CONFIG_KGSL CONFIG_TCP_CONG_BBR CONFIG_TCP_CONG_BBR2 CONFIG_TCP_CONG_BBRV2 CONFIG_TCP_CONG_WESTWOOD CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_NOMOUNT CONFIG_NTSYNC CONFIG_NAMESPACES CONFIG_SYSVIPC CONFIG_POSIX_MQUEUE CONFIG_IPC_NS CONFIG_PID_NS CONFIG_NET_NS CONFIG_UTS_NS CONFIG_USER_NS CONFIG_CGROUPS CONFIG_DEVTMPFS CONFIG_DROIDSPACES CONFIG_DROIDSPACE CONFIG_UNICODE CONFIG_UNICODE_BYPASS_FIX CONFIG_UNICODE_BYPASS CONFIG_TMPFS CONFIG_TMPFS_XATTR CONFIG_TMPFS_POSIX_ACL CONFIG_TMPFS_INODE64 CONFIG_LTO CONFIG_LTO_CLANG CONFIG_LTO_CLANG_THIN CONFIG_LTO_CLANG_FULL CONFIG_LTO_NONE CONFIG_BBG CONFIG_SECURITY_BASEBAND_GUARD CONFIG_BASEBAND_GUARD CONFIG_LSM CONFIG_DEBUG_INFO_BTF CONFIG_DEBUG_INFO_BTF_MODULES CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_BPF_JIT_ALWAYS_ON CONFIG_BPF_JIT_DEFAULT_ON CONFIG_BPF_LSM CONFIG_CGROUP_BPF CONFIG_NET_CLS_BPF CONFIG_NET_ACT_BPF CONFIG_FUSE_FS CONFIG_FUSE_BPF CONFIG_FUSE_PASSTHROUGH'
if [ -n "$_cfg" ]; then
  _emit kernel_config available yes
  for _k in $_cfg_keys; do
    _v="$(_cfg_val "$_k")"
    [ -n "$_v" ] && _emit kernel_config "$_k" "$_v"
  done
else
  _emit kernel_config available unavailable
fi

# Kernel provenance is evidence, not a verdict from the word "custom" in a release
# string. A locked green boot chain is only stock-like; a patch/config marker is only
# custom-like. Neither identifies who built the boot image, and missing evidence is unknown.
_origin_custom=''
_origin_lower="$(printf '%s %s %s' "$_uname_r" "$_proc_version" "$(_cfg_val CONFIG_LOCALVERSION)" | tr 'A-Z' 'a-z')"
case "$_origin_lower" in
  *custom*|*kernelsu*|*sukisu*|*apatch*|*susfs*|*nomount*) _origin_custom='build/localversion marker' ;;
esac
for _k in KSU KSU_SUSFS NOMOUNT UNICODE_BYPASS_FIX UNICODE_BYPASS BBG SECURITY_BASEBAND_GUARD BASEBAND_GUARD; do
  case "$(_cfg_val "CONFIG_$_k")" in y|m) _origin_custom="${_origin_custom:+$_origin_custom; }CONFIG_$_k" ;; esac
done
_origin_stock=''
[ "$(_prop ro.boot.verifiedbootstate)" = 'green' ] && _origin_stock='verifiedbootstate=green'
[ "$(_prop ro.boot.flash.locked)" = '1' ] && _origin_stock="${_origin_stock:+$_origin_stock; }flash.locked=1"
[ "$(_prop ro.boot.vbmeta.device_state)" = 'locked' ] && _origin_stock="${_origin_stock:+$_origin_stock; }vbmeta=locked"
[ "$(_prop ro.build.type)" = 'user' ] && _origin_stock="${_origin_stock:+$_origin_stock; }build.type=user"
if [ -n "$_origin_custom" ]; then
  _origin_class='custom-like'
  _origin_basis='positive build/config patch indicators; provenance not proven'
elif [ -n "$_origin_stock" ]; then
  _origin_class='stock-like'
  _origin_basis='boot/build indicators only; provenance not proven'
else
  _origin_class='unknown'
  _origin_basis='not exposed'
fi
_emit kernel_origin assessment "$_origin_class"
_emit kernel_origin confidence 'indicative; not a provenance proof'
_emit kernel_origin custom_evidence "${_origin_custom:-none exposed}"
_emit kernel_origin stock_evidence "${_origin_stock:-none exposed}"
_emit kernel_origin basis "$_origin_basis"
_emit kernel_origin capability_policy 'use only exposed per-node capabilities; no feature request from this collector'

# BTF, eBPF and FUSE-BPF are separate facts. Config describes the build, a sysfs
# node describes runtime exposure, and neither alone proves that a program is active.
_btf_cfg="$(_cfg_val CONFIG_DEBUG_INFO_BTF)"
_btf_mod_cfg="$(_cfg_val CONFIG_DEBUG_INFO_BTF_MODULES)"
_btf_vmlinux="$SYS/kernel/btf/vmlinux"
if [ -r "$_btf_vmlinux" ] && [ -s "$_btf_vmlinux" ]; then
  _btf_runtime='vmlinux readable and non-empty'
elif [ -e "$_btf_vmlinux" ]; then
  _btf_runtime='vmlinux present; not readable/non-empty'
else
  _btf_runtime='not exposed at standard path'
fi
_btf_entries=0
if [ -d "$SYS/kernel/btf" ]; then
  for _p in "$SYS/kernel/btf"/*; do
    [ -e "$_p" ] || continue
    [ "$_p" = "$_btf_vmlinux" ] && continue
    _btf_entries=$((_btf_entries + 1))
  done
  _btf_module_state="$_btf_entries entries exposed"
else
  _btf_module_state='not exposed at standard path'
fi
case "$_btf_cfg:$_btf_runtime" in
  y:'vmlinux readable and non-empty') _btf_summary='built-in config; vmlinux exposed' ;;
  y:*) _btf_summary='built-in config; vmlinux not readable/exposed' ;;
  *:'vmlinux readable and non-empty') _btf_summary='vmlinux exposed; config not confirmed' ;;
  *) [ -n "$_cfg" ] && _btf_summary='config/runtime evidence limited' || _btf_summary='unknown; not runtime-discoverable' ;;
esac
_emit kernel_btf summary "$_btf_summary"
_emit kernel_btf config "${_btf_cfg:-unknown}"
_emit kernel_btf modules_config "${_btf_mod_cfg:-unknown}"
_emit kernel_btf vmlinux "$_btf_runtime"
_emit kernel_btf module_entries "$_btf_module_state"
_emit kernel_btf runtime_verification 'read-only exposure only; BTF contents not executed'

_bpf_cfg="$(_cfg_val CONFIG_BPF)"
_bpf_syscall_cfg="$(_cfg_val CONFIG_BPF_SYSCALL)"
_bpf_bpfs='not exposed at standard path'
_bpf_pinned='not runtime-discoverable'
if [ -d "$SYS/fs/bpf" ]; then
  _bpf_bpfs='directory exposed'
  _bpf_n=0
  for _p in "$SYS/fs/bpf"/*; do [ -e "$_p" ] || continue; _bpf_n=$((_bpf_n + 1)); done
  _bpf_pinned="$_bpf_n top-level entries exposed"
fi
_bpf_runtime=0
[ -d "$SYS/fs/bpf" ] && _bpf_runtime=1
for _spec in jit_enable:bpf_jit_enable jit_harden:bpf_jit_harden jit_kallsyms:bpf_jit_kallsyms; do
  _k="${_spec%%:*}"; _v="$(_read "$PROC/sys/net/core/${_spec#*:}")"
  if [ -n "$_v" ]; then _emit kernel_ebpf "$_k" "$_v"; _bpf_runtime=1
  else _emit kernel_ebpf "$_k" 'not exposed'; fi
done
case "$_bpf_cfg:$_bpf_syscall_cfg" in *y*|*m*) _bpf_positive=1 ;; *) _bpf_positive=0 ;; esac
if [ "$_bpf_positive" = 1 ]; then
  if [ "$_bpf_runtime" = 1 ]; then _bpf_summary='configured; runtime interfaces exposed'
  else _bpf_summary='configured; runtime not verified'; fi
elif [ "$_bpf_runtime" = 1 ]; then
  _bpf_summary='runtime interfaces exposed; config not confirmed'
elif [ -n "$_bpf_cfg$_bpf_syscall_cfg" ]; then
  _bpf_summary='not enabled in exposed config; runtime not verified'
else
  _bpf_summary='unknown; not runtime-discoverable'
fi
_emit kernel_ebpf summary "$_bpf_summary"
_emit kernel_ebpf config "${_bpf_cfg:-unknown}"
_emit kernel_ebpf syscall_config "${_bpf_syscall_cfg:-unknown}"
_emit kernel_ebpf bpfs "$_bpf_bpfs"
_emit kernel_ebpf pinned_objects "$_bpf_pinned"
_emit kernel_ebpf runtime_verification 'no BPF program loaded; config/exposure is not proof of active eBPF'

_fuse_cfg="$(_cfg_val CONFIG_FUSE_FS)"
_fuse_bpf_cfg="$(_cfg_val CONFIG_FUSE_BPF)"
_fuse_runtime='not exposed at standard path'
[ -c "$DEV/fuse" ] && _fuse_runtime='character device exposed'
_fuse_type="$(_read "$SYS/fs/fuse/bpf_prog_type_fuse")"
case "$_fuse_type" in ''|*[!0-9]*) _fuse_type_state='not exposed at standard path' ;; *) _fuse_type_state="exposed; type=$_fuse_type" ;; esac
if [ -d "$SYS/fs/fuse/connections" ]; then
  _fuse_n=0
  for _p in "$SYS/fs/fuse/connections"/*; do [ -e "$_p" ] || continue; _fuse_n=$((_fuse_n + 1)); done
  _fuse_conn="$_fuse_n connections exposed"
else
  _fuse_conn='not exposed at standard path'
fi
case "$_fuse_type" in
  ''|*[!0-9]*)
    if [ -n "$_fuse_bpf_cfg" ]; then _fuse_bpf_summary="config=${_fuse_bpf_cfg}; runtime interface not exposed"
    else _fuse_bpf_summary='unknown; not runtime-discoverable'; fi ;;
  *)
    if [ -n "$_fuse_bpf_cfg" ]; then _fuse_bpf_summary="config=${_fuse_bpf_cfg}; runtime interface exposed"
    else _fuse_bpf_summary='runtime interface exposed; config not confirmed'; fi ;;
esac
_emit kernel_fuse_bpf summary "$_fuse_bpf_summary"
_emit kernel_fuse_bpf fuse_config "${_fuse_cfg:-unknown}"
_emit kernel_fuse_bpf fuse_bpf_config "${_fuse_bpf_cfg:-unknown}"
_emit kernel_fuse_bpf fuse_device "$_fuse_runtime"
_emit kernel_fuse_bpf prog_type_interface "$_fuse_type_state"
_emit kernel_fuse_bpf connections "$_fuse_conn"
_emit kernel_fuse_bpf evidence_note 'ordinary FUSE or eBPF alone does not prove FUSE-BPF; active mounts/programs not inferred'

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
_nm_state="$(_feature_state CONFIG_NOMOUNT "$SYS/module/nomount")"
_nm_ver="$(_read "$SYS/module/nomount/version")"
_emit kernel_features nomount "$_nm_state"
_emit kernel_features nomount_version "${_nm_ver:-not exposed}"

# Metamodule metadata is read from the standard module.prop only. NoMount evidence is
# intentionally independent: config/sysfs can prove driver state, not which module owns it.
_mm_prop="$DATA/metamodule/module.prop"
if [ -r "$_mm_prop" ]; then
  _emit metamodule status 'detected at standard path'
  _mm_id="$(_kv "$_mm_prop" id)"
  _mm_name="$(_kv "$_mm_prop" name)"
  _mm_version="$(_kv "$_mm_prop" version)"
  _mm_version_code="$(_kv "$_mm_prop" versionCode)"
  _emit metamodule id "${_mm_id:-not exposed}"
  _emit metamodule name "${_mm_name:-not exposed}"
  _emit metamodule version "${_mm_version:-not exposed}"
  _emit metamodule version_code "${_mm_version_code:-not exposed}"
elif [ -d "$DATA/metamodule" ]; then
  _emit metamodule status 'standard path present; module.prop not readable'
  _emit metamodule version 'not exposed'
  _emit metamodule version_code 'not exposed'
else
  _emit metamodule status 'not detected at standard path'
fi
_emit metamodule nomount_driver "$_nm_state"
_emit metamodule nomount_driver_version "${_nm_ver:-not exposed}"
_emit metamodule nomount_evidence 'kernel config/sysfs; driver ownership not inferred'
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
  [ -n "$_current" ] || _current="$(_read "$_d/gpuclk")"
  [ -n "$_max" ] || _max="$(_read "$_d/max_gpuclk")"
  [ -n "$_min" ] || _min="$(_read "$_d/min_gpuclk")"
  _avail="$(_read_first "$_d/gpu_available_frequencies" "$_d/devfreq/available_frequencies" "$_d/available_frequencies")"
  if [ -n "$_avail" ]; then
    _lo="$(printf '%s\n' $_avail | grep -E '^[0-9]+$' | sort -n | head -n 1)"
    _hi="$(printf '%s\n' $_avail | grep -E '^[0-9]+$' | sort -n | tail -n 1)"
    [ -n "$_min" ] || _min="$_lo"
    [ -n "$_max" ] || _max="$_hi"
  fi
  [ -n "$_governor" ] || { [ -e "$_d/max_pwrlevel" ] && _governor="pwrlevel"; }
  _levels="$(_read "$_d/num_pwrlevels")"
  _model="$(_read "$_d/gpu_model")"
  _v="governor=$_governor; current_hz=$_current; min_hz=$_min; max_hz=$_max; busy=$_busy; levels=$_levels; model=$_model"
  _emit gpu "$_name" "$_v"
done

for _k in MemTotal MemAvailable Buffers Cached SwapTotal SwapFree; do
  _v="$(_mem "$PROC/meminfo" "$_k")"; [ -n "$_v" ] && _emit memory "$_k" "$_v"
done
for _spec in \
  'capacity:capacity' 'status:status' 'technology:technology' 'health:health' \
  'temp_tenths_c:temp' 'current_ua:current_now' 'voltage_uv:voltage_now' \
  'charge_full_uah:charge_full' 'charge_full_design_uah:charge_full_design' \
  'cycle_count:cycle_count'; do
  _k="${_spec%%:*}"; _v="$(_read "$SYS/class/power_supply/battery/${_spec#*:}")"
  [ -n "$_v" ] && _emit battery "$_k" "$_v"
done
_emit system uptime "$(_read "$PROC/uptime")"
_emit system loadavg "$(_read "$PROC/loadavg")"

# ASB runtime facts: a whitelist, never an eval or arbitrary file import.
for _k in profile state state_warmup smart_mode thermal cap_owner device_bounds_applied device_bounds_status device_bounds_reason \
  smooth_log_status smooth_log_accepted smooth_log_rejected smooth_log_suppressed smooth_log_last_epoch smooth_log_last_jank_x1000 smooth_log_capture smooth_log_seq; do
  _v="$(_kv "$STATE_FILE" "$_k")"; [ -n "$_v" ] && _emit asb "$_k" "$_v"
done
_caps="$DATA/asb/device_caps.env"
_rcaps="$DATA/asb/capabilities.env"
_probe="$DATA/asb/install_probe.txt"
_pc="$(_kv "$_caps" cpu_policy_count)"
[ -n "$_pc" ] || _pc="$(_kv "$_rcaps" cpu_policy_count)"
[ -n "$_pc" ] && _emit asb_caps cpu_policy_count "$_pc"
for _pid in $(_kv "$_caps" cpu_policy_list); do
  case "$_pid" in ''|*[!0-9]*) continue ;; esac
  _emit asb_caps "policy$_pid" "hwmin=$(_kv "$_caps" "cpu_policy${_pid}_hwmin"); hwmax=$(_kv "$_caps" "cpu_policy${_pid}_hwmax"); lowest=$(_kv "$_caps" "cpu_policy${_pid}_lowest_opp"); steps=$(_kv "$_caps" "cpu_policy${_pid}_nfreq"); min_writable=$(_kv "$_caps" "cpu_policy${_pid}_min_writable")"
done
_gb="$(_kv "$_caps" gpu_backend)"
case "$_gb" in
  pwrlevel) _emit asb_caps gpu "backend=pwrlevel; levels=$(_kv "$_caps" gpu_num_pwrlevels)" ;;
  devfreq) _emit asb_caps gpu "backend=devfreq; min=$(_kv "$_caps" gpu_devfreq_min); max=$(_kv "$_caps" gpu_devfreq_max)" ;;
  none) _emit asb_caps gpu "backend=none" ;;
esac
_tz="$(_kv "$_caps" thermal_zone_count)"
[ -n "$_tz" ] && _emit asb_caps thermal_zones "$_tz"
for _k in uclamp battery_current cgroup_v2 memcg msm_performance camera_cpuset dsp_soundfx cpu_opp_complete; do
  _v="$(_kv "$_rcaps" "$_k")"; [ -n "$_v" ] && _emit asb_caps "$_k" "$_v"
done
_v="$(_kv "$_rcaps" thermal_headroom_source)"; [ -n "$_v" ] && _emit asb_caps thermal_headroom_source "$_v"
_root_mgr="$(_kv "$_caps" root_manager)"
if [ -n "$_root_mgr" ]; then
  _emit asb_caps root_manager "$_root_mgr"
  _emit root manager "$_root_mgr"
fi
# root_manager=ksu identifies the compatible interface family, not the implementation.
# A bounded, sanitized version response may positively identify KernelSU Next or another
# fork. No response means "not exposed", never "the original KernelSU" or "unsupported".
if [ "$_root_mgr" = 'ksu' ]; then
  _ksud=''
  if [ -n "$KSUD_BIN" ] && [ -x "$KSUD_BIN" ]; then
    _ksud="$KSUD_BIN"
  else
    for _candidate in "$DATA/ksud" "$DATA/ksu/bin/ksud"; do
      if [ -x "$_candidate" ]; then _ksud="$_candidate"; break; fi
    done
  fi
  _root_line=''
  [ -n "$_ksud" ] && _root_line="$("$_ksud" --version 2>/dev/null | head -n 1)"
  _root_line="$(_clean "$_root_line" | cut -c1-160)"
  if [ -n "$_root_line" ]; then
    _root_lower="$(printf '%s' "$_root_line" | tr 'A-Z' 'a-z')"
    case "$_root_lower" in
      *'kernelsu next'*) _root_variant='KernelSU Next' ;;
      *'sukisu ultra'*) _root_variant='SukiSU Ultra' ;;
      *'sukisu'*) _root_variant='SukiSU' ;;
      *'kernelsu'*) _root_variant='KernelSU' ;;
      *) _root_variant='not exposed' ;;
    esac
    _root_ver="$(printf '%s\n' "$_root_line" | sed -n 's/^[^0-9]*\([0-9][0-9A-Za-z.+_-]*\).*/\1/p' | head -n 1)"
    _emit root variant "$_root_variant"
    _emit root version "${_root_ver:-not exposed}"
    _emit root variant_evidence 'ksud --version'
    _emit root version_evidence "$_root_line"
  else
    _emit root variant 'not exposed'
    _emit root version 'not exposed'
    _emit root variant_evidence 'not exposed'
  fi
fi
_cam="$(_kv "$_caps" has_odm_camera_dir)"; _aud="$(_kv "$_caps" has_vendor_audio_dir)"
[ -n "$_cam$_aud" ] && _emit asb_caps overlay "camera=${_cam:-?}; audio=${_aud:-?}"
_v="$(_kv "$_caps" has_wlan_txqlen)"; [ -n "$_v" ] && _emit asb_caps wlan_txqlen "$_v"
if [ -r "$_probe" ]; then
  _tl=''
  for _spec in camera:camera_tunable audio:audio_tunable wifi:wifi_tunable media:media_codecs_tunable perf:perf_tunable gps:gps_tunable; do
    _tv="$(sed -n "s/^[[:space:]]*${_spec#*:}=//p" "$_probe" 2>/dev/null | head -n 1 | tr -dc '0-9')"
    [ -n "$_tv" ] && [ "$_tv" != 0 ] && _tl="$_tl ${_spec%%:*}"
  done
  _emit asb_caps tunable "${_tl# }"
fi

# Pressure and observer metrics stay separate: neither is a health score or a policy input.
command -v _asb_pressure_collect >/dev/null 2>&1 && _asb_pressure_collect
command -v _asb_zygisk_info >/dev/null 2>&1 && _asb_zygisk_info
if [ "${ASB_DEVINFO_LSPOSED:-1}" = 0 ]; then
  command -v _asb_lsposed_quick >/dev/null 2>&1 && _asb_lsposed_quick
else
  command -v _asb_lsposed_info >/dev/null 2>&1 && _asb_lsposed_info
fi
exit 0
