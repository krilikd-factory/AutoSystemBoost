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
TC_BIN="${ASB_DEVINFO_TC:-}"
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
_cfg_keys='CONFIG_LOCALVERSION CONFIG_PREEMPT CONFIG_PREEMPT_DYNAMIC CONFIG_HZ CONFIG_SCHEDSTATS CONFIG_SCHED_WALT CONFIG_SCHEDUTIL CONFIG_CPU_FREQ_GOV_SCHEDUTIL CONFIG_CPU_FREQ_GOV_PERFORMANCE CONFIG_CPU_FREQ_GOV_POWERSAVE CONFIG_CPU_BOOST CONFIG_LRU_GEN CONFIG_LRU_GEN_ENABLED CONFIG_ZRAM CONFIG_ZSWAP CONFIG_ZSMALLOC CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND CONFIG_DEVFREQ_GOV_MSM_ADRENO_TZ CONFIG_KGSL CONFIG_TCP_CONG_BBR CONFIG_TCP_CONG_BBR2 CONFIG_TCP_CONG_BBRV2 CONFIG_TCP_CONG_WESTWOOD CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_NOMOUNT CONFIG_NTSYNC CONFIG_NAMESPACES CONFIG_SYSVIPC CONFIG_POSIX_MQUEUE CONFIG_IPC_NS CONFIG_PID_NS CONFIG_NET_NS CONFIG_UTS_NS CONFIG_USER_NS CONFIG_CGROUPS CONFIG_DEVTMPFS CONFIG_DROIDSPACES CONFIG_DROIDSPACE CONFIG_UNICODE CONFIG_UNICODE_BYPASS_FIX CONFIG_UNICODE_BYPASS CONFIG_TMPFS CONFIG_TMPFS_XATTR CONFIG_TMPFS_POSIX_ACL CONFIG_TMPFS_INODE64 CONFIG_LTO CONFIG_LTO_CLANG CONFIG_LTO_CLANG_THIN CONFIG_LTO_CLANG_FULL CONFIG_LTO_NONE CONFIG_BBG CONFIG_SECURITY_BASEBAND_GUARD CONFIG_BASEBAND_GUARD CONFIG_LSM CONFIG_DEBUG_INFO_BTF CONFIG_DEBUG_INFO_BTF_MODULES CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_BPF_JIT_ALWAYS_ON CONFIG_BPF_JIT_DEFAULT_ON CONFIG_BPF_LSM CONFIG_CGROUP_BPF CONFIG_NET_CLS_BPF CONFIG_NET_ACT_BPF CONFIG_FUSE_FS CONFIG_FUSE_BPF CONFIG_FUSE_PASSTHROUGH CONFIG_VPNHIDE CONFIG_VPNHIDE_FS_HIDING CONFIG_USB_CONFIGFS CONFIG_USB_CONFIGFS_MASS_STORAGE CONFIG_USB_CONFIGFS_F_HID CONFIG_USB_CONFIGFS_NCM CONFIG_IP_NF_NAT CONFIG_IP_NF_TARGET_MASQUERADE CONFIG_TCP_CONG_BBR3 CONFIG_WIREGUARD CONFIG_NET_SCH_CAKE CONFIG_NET_SCH_FQ CONFIG_IP_SET CONFIG_REKERNEL CONFIG_REKERNEL_NETWORK CONFIG_REKERNEL_LEGACY_NETLINK CONFIG_ASB_WAKEUP_BLOCKER CONFIG_OVERLAY_FS CONFIG_CIFS CONFIG_BINFMT_MISC CONFIG_MACVLAN CONFIG_KPROBES CONFIG_UPROBES CONFIG_OPLUS_SDP_900MA CONFIG_DEBUG_FS CONFIG_SCHED_DEBUG CONFIG_SCHED_AUTOGROUP'
_cfg=''
_cfg_lines=0
_cfg_decoder=''
_cfg_re="^(# )?($(echo $_cfg_keys | tr ' ' '|'))[= ]"
if [ -r "$PROC/config.gz" ]; then
  for _dec in zcat 'gzip -dc' 'toybox zcat' 'busybox zcat'; do
    command -v "${_dec%% *}" >/dev/null 2>&1 || continue
    _n="$($_dec "$PROC/config.gz" 2>/dev/null | grep -c '^CONFIG_')"
    case "$_n" in ''|*[!0-9]*) continue ;; esac
    [ "$_n" -gt 0 ] || continue
    _cfg="$($_dec "$PROC/config.gz" 2>/dev/null | grep -E "$_cfg_re")"
    _cfg_lines="$_n"; _cfg_decoder="${_dec%% *}"
    break
  done
fi
_cfg_val() {
  [ -n "$_cfg" ] || return 0
  _cv="$(printf '%s\n' "$_cfg" | sed -n "s/^$1=//p" | head -n 1)"
  if [ -z "$_cv" ] && printf '%s\n' "$_cfg" | grep -q "^# $1 is not set$"; then _cv='not set'; fi
  printf '%s\n' "$_cv"
}
if [ "$_cfg_lines" -gt 0 ]; then
  _emit kernel_config available yes
  _emit kernel_config entries "$_cfg_lines"
  _emit kernel_config decoder "$_cfg_decoder"
  for _k in $_cfg_keys; do
    _v="$(_cfg_val "$_k")"
    [ -n "$_v" ] && _emit kernel_config "$_k" "$_v"
  done
elif [ -r "$PROC/config.gz" ]; then
  _emit kernel_config available 'present; not decodable here'
else
  _emit kernel_config available unavailable
fi
_emit kernel_config evidence_scope 'exposed config only; may be a compatibility/spoofed payload and is not proof of the running custom final config'

# One bounded kallsyms pass supplies named evidence to several built-in features.
# Built-in drivers normally have no /sys/module directory, so config-only/module-only
# detection produces false "unknown" verdicts. Symbols prove code presence, not that
# a userspace client, qdisc, LSM policy or hiding rule was exercised successfully.
_ks_read='not readable'; _ks_rows=0; _ks_hits=''
if [ -r "$PROC/kallsyms" ]; then
  if _ks_scan="$(awk '
    NF >= 3 {
      rows++
      n=$3; token=""
      if (n ~ /^cake_(qdisc_ops|init|enqueue|dequeue)(\.|$)/) token="cake"
      else if (n ~ /^(start_rekernel|rekernel_netlink_start|rekernel_genl_family|rekernel_genl_get_version)(\.|$)/) token="rekernel"
      else if (n ~ /^ntsync_(init|open|release|fops|misc_device)(\.|$)/) token="ntsync"
      else if (n ~ /^vpnhide_(init|should_hide_dev|setsockopt_bind)(\.|$)/) token="vpnhide"
      else if (n ~ /^bbg_init(\.|$)/) token="bbg"
      if (token != "" && !seen[token]++) hits=hits token " "
    }
    END { printf "rows=%d;hits=%s", rows+0, hits }
  ' "$PROC/kallsyms" 2>/dev/null)"; then
    case "$_ks_scan" in
      rows=*\;hits=*)
        _ks_rows="${_ks_scan%%;*}"; _ks_rows="${_ks_rows#rows=}"
        _ks_hits="${_ks_scan#*;hits=}"
        if [ "$_ks_rows" -gt 0 ] 2>/dev/null; then _ks_read='readable'; else _ks_read='no usable symbol rows'; fi ;;
      *) _ks_read='unreadable or malformed' ;;
    esac
  else
    _ks_read='unreadable or malformed'
  fi
fi
_ks_has() { case " $_ks_hits " in *" $1 "*) return 0 ;; esac; return 1; }
_runtime_lsm="$(_read "$SYS/kernel/security/lsm")"
_runtime_lsm_words=" $(printf '%s' "$_runtime_lsm" | tr ',' ' ') "

# Kernel provenance is evidence, not a verdict from boot lock/build type. Positive
# custom build/runtime indicators win over stock-like boot indicators; neither side
# identifies who built the boot image, and missing evidence remains unknown.
_origin_custom=''
_origin_add() { case "; $_origin_custom;" in *"; $1;"*) ;; *) _origin_custom="${_origin_custom:+$_origin_custom; }$1" ;; esac; }
_origin_lower="$(printf '%s %s %s' "$_uname_r" "$_proc_version" "$(_cfg_val CONFIG_LOCALVERSION)" | tr 'A-Z' 'a-z')"
case "$_origin_lower" in
  *custom*|*kernelsu*|*sukisu*|*apatch*|*susfs*|*nomount*|*krilikd*) _origin_add 'build/localversion marker' ;;
esac
for _k in KSU KSU_SUSFS NOMOUNT UNICODE_BYPASS_FIX UNICODE_BYPASS BBG SECURITY_BASEBAND_GUARD BASEBAND_GUARD; do
  case "$(_cfg_val "CONFIG_$_k")" in y|m) _origin_add "CONFIG_$_k" ;; esac
done
[ "${_susfs_state:-unavailable}" = 'available' ] && _origin_add 'SuSFS interface'
[ -d "$SYS/module/nomount" ] && _origin_add 'NoMount driver'
[ -d "$SYS/kernel/asb_wakeup" ] && _origin_add 'ASB wakeup blocker'
[ -d "$PROC/rekernel" ] && _origin_add 'Re-Kernel proc interface'
_ks_has rekernel && _origin_add 'Re-Kernel kernel symbols'
[ -e "$PROC/vpnhide_ctl" ] && _origin_add 'VPN Hide control interface'
_ks_has vpnhide && _origin_add 'VPN Hide kernel symbols'
_ks_has bbg && _origin_add 'Baseband Guard kernel symbols'
case "$_runtime_lsm_words" in *' baseband_guard '*) _origin_add 'Baseband Guard in runtime LSM list' ;; esac
case " $(_read "$PROC/sys/net/ipv4/tcp_available_congestion_control") " in *' bbr3 '*) _origin_add 'BBRv3 runtime algorithm' ;; esac
_origin_stock=''
[ "$(_prop ro.boot.verifiedbootstate)" = 'green' ] && _origin_stock='verifiedbootstate=green'
[ "$(_prop ro.boot.flash.locked)" = '1' ] && _origin_stock="${_origin_stock:+$_origin_stock; }flash.locked=1"
[ "$(_prop ro.boot.vbmeta.device_state)" = 'locked' ] && _origin_stock="${_origin_stock:+$_origin_stock; }vbmeta=locked"
[ "$(_prop ro.build.type)" = 'user' ] && _origin_stock="${_origin_stock:+$_origin_stock; }build.type=user"
if [ -n "$_origin_custom" ]; then
  _origin_class='custom-like'
  _origin_basis='positive build/config/runtime patch indicators; boot lock/build type do not override them; provenance not proven'
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
    y) if [ -d "$2" ]; then printf 'driver present; exposed config says built-in\n'; else printf 'built-in config; runtime not independently confirmed\n'; fi ;;
    m) if [ -d "$2" ]; then printf 'module loaded\n'; else printf 'module configured; not observed loaded\n'; fi ;;
    'not set') if [ -d "$2" ]; then printf 'driver present; exposed config disagrees\n'; else printf 'not observed; exposed config says not set\n'; fi ;;
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
_ntsync="$(_feature_state CONFIG_NTSYNC "$SYS/module/ntsync")"
if [ -c "$DEV/ntsync" ]; then
  _ntsync='available; /dev/ntsync character device exposed'
elif _ks_has ntsync; then
  _ntsync='driver code present; NTSync kernel symbols found; device not observed'
fi
_emit kernel_features ntsync "$_ntsync"

# Droidspaces has no single standard runtime switch. Existing namespace/IPC nodes are
# stronger evidence than a compatibility config, but still do not prove a container works.
_ds_rt_seen=0; _ds_rt_missing=''
for _spec in NAMESPACES:. IPC_NS:ipc PID_NS:pid NET_NS:net UTS_NS:uts; do
  _k="${_spec%%:*}"; _n="${_spec#*:}"
  if [ -n "$_n" ]; then _p="$PROC/self/ns/$_n"; else _p="$PROC/self/ns"; fi
  if [ -e "$_p" ]; then _ds_rt_seen=$((_ds_rt_seen + 1)); else _ds_rt_missing="$_ds_rt_missing $_k"; fi
done
if [ -d "$PROC/sysvipc" ]; then _ds_rt_seen=$((_ds_rt_seen + 1)); else _ds_rt_missing="$_ds_rt_missing SYSVIPC"; fi
if [ -d "$PROC/sys/fs/mqueue" ]; then _ds_rt_seen=$((_ds_rt_seen + 1)); else _ds_rt_missing="$_ds_rt_missing POSIX_MQUEUE"; fi
if [ -r "$PROC/mounts" ] && awk '$1 == "devtmpfs" && $2 == "/dev" { found=1; exit } END { exit !found }' "$PROC/mounts" 2>/dev/null; then
  _ds_rt_seen=$((_ds_rt_seen + 1))
else
  _ds_rt_missing="$_ds_rt_missing DEVTMPFS"
fi
_ds_missing=''
for _k in NAMESPACES SYSVIPC POSIX_MQUEUE IPC_NS PID_NS NET_NS UTS_NS DEVTMPFS; do
  [ "$(_cfg_val "CONFIG_$_k")" = 'y' ] || _ds_missing="$_ds_missing $_k"
done
if [ "$_ds_rt_seen" -eq 8 ] && [ -z "$_ds_rt_missing" ]; then
  _emit kernel_features droidspaces 'core runtime interfaces exposed; container operation not tested'
elif [ "$_ds_rt_seen" -gt 0 ]; then
  _emit kernel_features droidspaces "partial runtime exposure; not exposed:${_ds_rt_missing}; container operation not tested"
elif [ -z "$_cfg" ]; then
  _emit kernel_features droidspaces unknown
elif [ -z "$_ds_missing" ]; then
  _emit kernel_features droidspaces 'core config present; runtime not verified'
else
  _emit kernel_features droidspaces "exposed config incomplete; runtime not verified; missing there:${_ds_missing}"
fi

_unicode_state="$(_feature_state CONFIG_UNICODE_BYPASS_FIX "$SYS/module/unicode_bypass_fix")"
case "$_unicode_state" in built-in*|module*|driver*) ;; *)
  _unicode_state="$(_feature_state CONFIG_UNICODE_BYPASS "$SYS/module/unicode_bypass")" ;; esac
case "$_unicode_state" in
  built-in*|module*|driver*) _emit kernel_features unicode_bypass_fix "$_unicode_state" ;;
  *)
    _emit kernel_features unicode_bypass_fix 'not runtime-discoverable'
    _emit kernel_features unicode_bypass_evidence 'no standard read-only indicator; CONFIG_UNICODE alone is not proof' ;;
esac

_tmp_x="$(_cfg_val CONFIG_TMPFS_XATTR)"
_tmp_a="$(_cfg_val CONFIG_TMPFS_POSIX_ACL)"
if [ -z "$_cfg" ]; then _tmp_state='unknown'
elif [ "$_tmp_x" = 'y' ] && [ "$_tmp_a" = 'y' ]; then _tmp_state='options present in exposed config; runtime not independently verified'
else _tmp_state="exposed config partial; XATTR=${_tmp_x:-unknown}; POSIX_ACL=${_tmp_a:-unknown}"; fi
_emit kernel_features tmpfs_xattr_posix_acl "$_tmp_state"

_lto='unknown'
for _spec in 'LTO_CLANG_THIN:ThinLTO (Clang)' 'LTO_CLANG_FULL:Full LTO (Clang)' 'LTO_CLANG:LTO (Clang)' 'LTO:LTO'; do
  [ "$(_cfg_val "CONFIG_${_spec%%:*}")" = 'y' ] || continue
  _lto="${_spec#*:}; exposed config only"; break
done
[ "$_lto" = 'unknown' ] && [ "$(_cfg_val CONFIG_LTO_NONE)" = 'y' ] && _lto='exposed config selects LTO_NONE; running build not independently confirmed'
# Android compiler banners may retain the +lto build marker even when the exposed
# compatibility config says LTO_NONE. It proves neither Thin nor Full mode by itself.
case "$(printf '%s' "$_proc_version" | tr 'A-Z' 'a-z')" in
  *'+lto'*)
    case "$_lto" in
      unknown) _lto='compiler build marker +lto; exact LTO mode not exposed' ;;
      'exposed config selects LTO_NONE;'*) _lto='compiler build marker +lto; exposed config says LTO_NONE; exact mode not independently confirmed' ;;
      *) _lto="$_lto; compiler build marker +lto" ;;
    esac ;;
esac
_emit kernel_features lto "$_lto"

_tcp_avail=" $(_read "$PROC/sys/net/ipv4/tcp_available_congestion_control") "
_bbr1='unknown'; _bbr2='unknown'
case "$_tcp_avail" in *' bbr '*) _bbr1='available' ;; esac
case "$_tcp_avail" in *' bbr2 '*|*' bbrv2 '*) _bbr2='available' ;; esac
if [ "$_bbr1" = 'unknown' ]; then
  if [ -n "$(printf '%s' "$_tcp_avail" | tr -d ' ')" ]; then _bbr1='not exposed in runtime algorithm list'
  else case "$(_cfg_val CONFIG_TCP_CONG_BBR)" in y|m) _bbr1='configured' ;; 'not set') _bbr1='not observed; exposed config says not set' ;; esac; fi
fi
if [ "$_bbr2" = 'unknown' ]; then
  if [ -n "$(printf '%s' "$_tcp_avail" | tr -d ' ')" ]; then _bbr2='not exposed in runtime algorithm list'
  else case "$(_cfg_val CONFIG_TCP_CONG_BBR2)$(_cfg_val CONFIG_TCP_CONG_BBRV2)" in *y*|*m*) _bbr2='configured' ;; *'not set'*) _bbr2='not observed; exposed config says not set' ;; esac; fi
fi
_emit kernel_features bbr_v1 "$_bbr1"
_emit kernel_features bbr_v2 "$_bbr2"

_bbr3='unknown'
case "$_tcp_avail" in *' bbr3 '*) _bbr3='available' ;; esac
if [ "$_bbr3" = 'unknown' ]; then
  if [ -n "$(printf '%s' "$_tcp_avail" | tr -d ' ')" ]; then _bbr3='not exposed in runtime algorithm list'
  else case "$(_cfg_val CONFIG_TCP_CONG_BBR3)" in y|m) _bbr3='configured' ;; 'not set') _bbr3='not observed; exposed config says not set' ;; esac; fi
fi
_emit kernel_features bbr_v3 "$_bbr3"

_cfg_state() {
  _cs_val="$(_cfg_val "$1")"
  # A running driver is positive evidence even when a compatibility/spoofed config
  # disagrees. Conversely, "not set" in that file is not proof about the running kernel.
  if [ -n "$2" ] && [ -d "$2" ]; then
    case "$_cs_val" in
      m) printf 'module loaded\n' ;;
      y) printf 'driver present; exposed config says built-in\n' ;;
      'not set') printf 'driver present; exposed config disagrees\n' ;;
      *) printf 'driver present\n' ;;
    esac
    return 0
  fi
  case "$_cs_val" in
    y) printf 'built-in config; runtime not independently confirmed\n' ;;
    m) printf 'module configured; not observed loaded\n' ;;
    'not set') printf 'not observed; exposed config says not set\n' ;;
    *)
      if [ "$_cfg_lines" -gt 0 ]; then printf 'not exposed in config; runtime not confirmed\n'
      else printf 'unknown\n'; fi ;;
  esac
}
_vh="$(_cfg_state CONFIG_VPNHIDE "$SYS/module/vpnhide")"
_vh_cfg_note=''
[ "$(_cfg_val CONFIG_VPNHIDE)" = 'not set' ] && _vh_cfg_note='; exposed config disagrees'
if [ -e "$PROC/vpnhide_ctl" ]; then
  _vh="available; /proc/vpnhide_ctl exposed${_vh_cfg_note}; hiding not tested"
elif _ks_has vpnhide; then
  _vh="driver code present; VPN Hide kernel symbols found${_vh_cfg_note}; control interface not observed"
else
  case "$_vh" in
    built-in\ config*)
      case "$(_cfg_val CONFIG_VPNHIDE_FS_HIDING)" in
        y) _vh='built-in config; network and filesystem options; runtime not independently confirmed' ;;
        *) _vh='built-in config; network option only; runtime not independently confirmed' ;;
      esac ;;
  esac
fi
_emit kernel_features vpn_hide "$_vh"

_ua=''; _ua_miss=''
for _spec in USB_CONFIGFS_MASS_STORAGE:mass-storage USB_CONFIGFS_F_HID:hid USB_CONFIGFS_NCM:ncm IP_NF_TARGET_MASQUERADE:nat; do
  case "$(_cfg_val "CONFIG_${_spec%%:*}")" in
    y|m) _ua="${_ua:+$_ua, }${_spec#*:}" ;;
    *) _ua_miss="${_ua_miss:+$_ua_miss, }${_spec#*:}" ;;
  esac
done
if [ "$_cfg_lines" -eq 0 ]; then _emit kernel_features usb_arsenal unknown
elif [ -z "$_ua_miss" ]; then _emit kernel_features usb_arsenal "gadget options in exposed config: $_ua; runtime not verified"
elif [ -n "$_ua" ]; then _emit kernel_features usb_arsenal "exposed config partial: $_ua; not set there: $_ua_miss"
else _emit kernel_features usb_arsenal 'not observed; exposed config lacks the requested gadget options'; fi

_fs_list=" $(_read "$PROC/filesystems" | tr '\t\n' '  ') "
_wg="$(_cfg_state CONFIG_WIREGUARD "$SYS/module/wireguard")"
_emit kernel_features wireguard "$_wg"

# CAKE needs runtime-aware evidence: this project's stock /proc/config.gz compatibility
# payload can disagree with the custom kernel actually running. Only read existing state;
# never load sch_cake, create a qdisc or change an interface for this snapshot.
_cake_cfg="$(_cfg_val CONFIG_NET_SCH_CAKE)"
_cake_mod='not observed'
if [ -d "$SYS/module/sch_cake" ]; then
  _cake_mod='sysfs module directory present'
elif [ -r "$PROC/modules" ]; then
  if awk '$1 == "sch_cake" { found=1 } END { exit !found }' "$PROC/modules" 2>/dev/null; then
    _cake_mod='listed in /proc/modules'
  else
    _cake_mod='not listed in readable /proc/modules'
  fi
else
  _cake_mod='not runtime-discoverable'
fi
if _ks_has cake; then
  _cake_sym='CAKE symbol present in readable /proc/kallsyms'
else
  case "$_ks_read" in
    readable) _cake_sym='readable; no CAKE symbol observed' ;;
    'no usable symbol rows') _cake_sym='readable; no usable symbol rows' ;;
    'unreadable or malformed') _cake_sym='unreadable or malformed' ;;
    *) _cake_sym='not readable' ;;
  esac
fi
_cake_tc_bin="$TC_BIN"
if [ -z "$_cake_tc_bin" ] && command -v tc >/dev/null 2>&1; then _cake_tc_bin="$(command -v tc)"; fi
_cake_qdisc='tc unavailable'
if [ -n "$_cake_tc_bin" ] && [ -x "$_cake_tc_bin" ]; then
  _cake_tc_out="$("$_cake_tc_bin" qdisc show 2>/dev/null)"
  if [ "$?" -eq 0 ]; then
    if printf '%s\n' "$_cake_tc_out" | grep -Eq '(^|[[:space:]])qdisc[[:space:]]+cake([[:space:]]|$)'; then
      _cake_qdisc='active CAKE qdisc observed'
    else
      _cake_qdisc='tc read succeeded; no CAKE qdisc observed'
    fi
  else
    _cake_qdisc='tc qdisc show failed'
  fi
fi
if [ "$_cake_qdisc" = 'active CAKE qdisc observed' ]; then
  _cake_state='available; active qdisc observed'
elif [ "$_cake_mod" = 'sysfs module directory present' ] || [ "$_cake_mod" = 'listed in /proc/modules' ]; then
  _cake_state='available; module loaded'
elif [ "$_cake_sym" = 'CAKE symbol present in readable /proc/kallsyms' ]; then
  _cake_state='available; kernel symbols present'
else
  case "$_cake_cfg" in
    y) _cake_state='built-in config; runtime not independently confirmed' ;;
    m) _cake_state='module configured; runtime not independently confirmed' ;;
    'not set') _cake_state='not runtime-confirmed; exposed config says not set' ;;
    *) _cake_state='unknown; not runtime-discoverable' ;;
  esac
fi
_emit kernel_features net_sch_cake "$_cake_state"
_emit kernel_features net_sch_cake_config "${_cake_cfg:-not exposed}"
_emit kernel_features net_sch_cake_module "$_cake_mod"
_emit kernel_features net_sch_cake_symbols "$_cake_sym"
_emit kernel_features net_sch_cake_qdisc "$_cake_qdisc"
_emit kernel_features net_sch_cake_evidence 'read-only existing state; positive runtime evidence overrides config; no qdisc/module change'
_ov="$(_cfg_state CONFIG_OVERLAY_FS "$SYS/module/overlay")"
case "$_fs_list" in *' overlay '*) [ "$_ov" = 'built-in' ] || _ov='filesystem registered' ;; esac
_emit kernel_features overlayfs "$_ov"
_cifs="$(_cfg_state CONFIG_CIFS "$SYS/module/cifs")"
case "$_fs_list" in *' cifs '*) [ "$_cifs" = 'built-in' ] || _cifs='filesystem registered' ;; esac
_emit kernel_features cifs "$_cifs"
_emit kernel_features ip_set "$(_cfg_state CONFIG_IP_SET "$SYS/module/ip_set")"
_rk="$(_cfg_state CONFIG_REKERNEL)"
if [ -d "$PROC/rekernel" ]; then
  _rk='available; legacy /proc/rekernel interface exposed; userspace transport not tested'
elif _ks_has rekernel; then
  _rk='available; Re-Kernel kernel symbols present; transport/userspace not tested'
else
  case "$_rk" in
    built-in\ config*)
      case "$(_cfg_val CONFIG_REKERNEL_NETWORK)" in
        y) _rk='built-in config; binder/signal/network and generic netlink options; runtime not independently confirmed' ;;
        *) _rk='built-in config; binder/signal and generic netlink options; runtime not independently confirmed' ;;
      esac ;;
  esac
fi
_emit kernel_features rekernel "$_rk"
_emit kernel_features wakeup_blocker "$(_cfg_state CONFIG_ASB_WAKEUP_BLOCKER "$SYS/kernel/asb_wakeup")"
if [ -r "$SYS/kernel/asb_wakeup/blocklist" ]; then
  _wb_rules="$(cat "$SYS/kernel/asb_wakeup/blocklist" 2>/dev/null)"
  _emit kernel_features wakeup_blocker_rules "${_wb_rules:-empty}"
fi
if [ -r "$SYS/kernel/asb_wakeup/blocked_events" ]; then
  _emit kernel_features wakeup_blocker_blocked_events "$(_read "$SYS/kernel/asb_wakeup/blocked_events")"
fi
# The reviewed KRILIKD/WildKernels driver exposes a read-only early-boot DT result.
# It is evidence about the configured SDP budget, never a live charge-current measurement
# and never a runtime writer. Do not collapse a present but NOT APPLIED report into success.
_sdp_node="$PROC/sdp900ma"
_sdp_cfg="$(_cfg_val CONFIG_OPLUS_SDP_900MA)"
_sdp_report=''
if [ -f "$_sdp_node" ] && [ -r "$_sdp_node" ]; then
  _sdp_report="$(_read "$_sdp_node" | tr '\t\r\n' '   ' | head -c 1200)"
  case "$_sdp_report" in
    *'enabled=0'*) _sdp_state='interface present; disabled by boot parameter; no runtime writer' ;;
    *'NOT APPLIED'*) _sdp_state='interface present; 900 mA not confirmed by its own readback' ;;
    *'[OK]'*'enabled=1'*) _sdp_state='configured SDP limit reported applied; actual USB input current not measured' ;;
    *) _sdp_state='interface present; configured result needs review; actual USB input current not measured' ;;
  esac
elif [ -e "$_sdp_node" ]; then
  _sdp_state='node present but unreadable'
else
  case "$_sdp_cfg" in
    y) _sdp_state='built-in config; /proc/sdp900ma not observed' ;;
    'not set') _sdp_state='not observed; exposed config says not set' ;;
    *) _sdp_state='not exposed; runtime support unknown' ;;
  esac
fi
_emit kernel_features oplus_sdp_900ma "$_sdp_state"
_emit kernel_features oplus_sdp_900ma_node "$_sdp_node"
_emit kernel_features oplus_sdp_900ma_config "${_sdp_cfg:-not exposed}"
[ -n "$_sdp_report" ] && _emit kernel_features oplus_sdp_900ma_report "$_sdp_report"
_emit kernel_features oplus_sdp_900ma_control 'none; early boot only; disable with oplus_sdp_900ma=0; ASB has no current/voltage writer'

_nm_node="$SYS/kernel/debug/sched/nr_migrate"
_nm_debug_cfg="$(_cfg_val CONFIG_DEBUG_FS)"
_nm_sched_cfg="$(_cfg_val CONFIG_SCHED_DEBUG)"
if [ -e "$_nm_node" ]; then
  if [ -r "$_nm_node" ] && [ -w "$_nm_node" ]; then _nm_state="writable; live=$(_read "$_nm_node")"
  elif [ -r "$_nm_node" ]; then _nm_state="read-only; live=$(_read "$_nm_node")"
  else _nm_state='present; not readable'; fi
else
  _nm_state='not exposed at the registered debugfs path; mount/SELinux/config not inferred'
fi
_emit kernel_features sched_nr_migrate "$_nm_state"
_emit kernel_features sched_nr_migrate_node "$_nm_node"
_emit kernel_features sched_nr_migrate_debug_config "${_nm_debug_cfg:-not exposed}"
_emit kernel_features sched_nr_migrate_sched_config "${_nm_sched_cfg:-not exposed}"

_ss_node="$PROC/sys/kernel/sched_schedstats"
_ss_cfg="$(_cfg_val CONFIG_SCHEDSTATS)"
if [ -e "$_ss_node" ]; then
  if [ -r "$_ss_node" ] && [ -w "$_ss_node" ]; then _ss="writable; live=$(_read "$_ss_node")"
  elif [ -r "$_ss_node" ]; then _ss="read-only; live=$(_read "$_ss_node")"
  else _ss=not_readable; fi
elif [ "$_ss_cfg" = 'not set' ]; then _ss='not observed; exposed config says not set'
else _ss=not_exposed; fi
_emit kernel_features sched_stats "$_ss"
_emit kernel_features sched_stats_config "${_ss_cfg:-not exposed}"
_emit kernel_features sched_stats_node "$_ss_node"
# Settings → Kernel needs only the small read-only capability set above. Do not run the
# full device collector (package, display and thermal probes) just to paint that page.
[ "${1:-}" = '--kernel' ] && exit 0

_bbg='unknown'; _bbg_all_not_set=1
for _k in BBG SECURITY_BASEBAND_GUARD BASEBAND_GUARD; do
  _bv="$(_cfg_val "CONFIG_$_k")"
  case "$_bv" in
    y) _bbg='built-in config; runtime not independently confirmed'; break ;;
    m) _bbg="$(_feature_state "CONFIG_$_k" "$SYS/module/baseband_guard")"; break ;;
    'not set') ;;
    *) _bbg_all_not_set=0 ;;
  esac
done
# A runtime module directory must not mask a positive built-in config from another
# accepted BBG config name. Use it only when no explicit config evidence won above.
if [ "$_bbg" = 'unknown' ]; then
  if [ -d "$SYS/module/baseband_guard" ]; then _bbg='driver present'
  elif [ -n "$_cfg" ] && [ "$_bbg_all_not_set" = 1 ]; then _bbg='not observed; exposed config says not set'; fi
fi
_lsm="$(_cfg_val CONFIG_LSM)"
case "$_lsm" in *baseband_guard*) _bbg="LSM list in exposed config includes baseband_guard; $_bbg" ;; esac
case "$_runtime_lsm_words" in
  *' baseband_guard '*) _bbg='active in runtime LSM list; enforcement policy not tested' ;;
  *) if _ks_has bbg && [ "$_bbg" = 'unknown' ]; then _bbg='driver code present; BBG kernel symbols found; runtime LSM activation not confirmed'; fi ;;
esac
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
  'hrtimer_migration:/proc/sys/kernel/hrtimer_migration' \
  'lpm_prediction:/sys/module/lpm_levels/parameters/lpm_prediction' \
  'usb_autosuspend:/sys/module/usbcore/parameters/autosuspend' \
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
