#!/system/bin/sh
MODID="AutoSystemBoost"
MODDIR="${0%/*}"
[ -z "$MODDIR" ] || [ "$MODDIR" = "$0" ] && MODDIR="/data/adb/modules/$MODID"
asb_feature_enabled() {
  _key="$1"
  [ -r "$MODDIR/features.conf" ] || return 0
  _line="$(grep -E "^${_key}=" "$MODDIR/features.conf" 2>/dev/null | tail -n 1)"
  [ -z "$_line" ] && return 0
  [ "${_line#*=}" = "1" ]
}
if asb_feature_enabled LOG; then
setprop persist.vendor.radio.adb_log_on 0 2>/dev/null
setprop persist.vendor.radio.log_loc 0 2>/dev/null
setprop persist.radio.low_priority_static_log 0 2>/dev/null
setprop persist.vendor.ims.disableADBLogs 1 2>/dev/null
setprop persist.vendor.ims.disableDebugDataPathLogs 1 2>/dev/null
setprop persist.vendor.ims.disableDebugLogs 1 2>/dev/null
setprop persist.vendor.ims.disableIMSLogs 1 2>/dev/null
setprop persist.vendor.ims.disableQXDMLogs 1 2>/dev/null
setprop persist.vendor.ims.dumpWiFiLogs 0 2>/dev/null
setprop persist.vendor.ims.vt.enableadb 0 2>/dev/null
setprop persist.vendor.logkit.ctrl 0 2>/dev/null
setprop persist.vendor.logkit.logcat 0 2>/dev/null
setprop persist.vendor.qcomlog.enable 0 2>/dev/null
setprop persist.vendor.sys.log.collector 0 2>/dev/null
setprop persist.sys.perfetto.disable 1 2>/dev/null
setprop persist.vendor.perfetto.disable 1 2>/dev/null
setprop persist.vendor.qti.telemetry.disable 1 2>/dev/null
fi
if command -v resetprop >/dev/null 2>&1; then
  if asb_feature_enabled LOG; then
  resetprop -n tombstoned.max_tombstone_count 0 >/dev/null 2>&1 || true
  resetprop -n ro.lmk.log_stats false >/dev/null 2>&1 || true
  resetprop -n ro.lmk.debug false >/dev/null 2>&1 || true
  fi
  if asb_feature_enabled BT; then
  resetprop --delete media.resolution.limit.16bit >/dev/null 2>&1 || true
  resetprop --delete media.resolution.limit.24bit >/dev/null 2>&1 || true
  resetprop --delete media.resolution.limit.32bit >/dev/null 2>&1 || true
  resetprop --delete media.resolution.limit.64bit >/dev/null 2>&1 || true
  resetprop --delete persist.bluetooth.a2dp_offload.disabled >/dev/null 2>&1 || true
  fi
  if asb_feature_enabled NET; then
  resetprop --delete ro.ril.gprs.mtu >/dev/null 2>&1 || true
  resetprop --delete persist.data.mtu.pref >/dev/null 2>&1 || true
  resetprop --delete persist.data.wda.mtu >/dev/null 2>&1 || true
  resetprop --delete persist.vendor.data.mtu >/dev/null 2>&1 || true
  resetprop --delete persist.data.mtu.pref6 >/dev/null 2>&1 || true
  resetprop --delete persist.vendor.data.mtu6 >/dev/null 2>&1 || true
  resetprop --delete persist.data.profile_mtu6 >/dev/null 2>&1 || true
  resetprop --delete persist.data_netmgrd_mtu >/dev/null 2>&1 || true
  fi
  if asb_feature_enabled KERNEL; then
  resetprop --delete persist.sys.power.fuel.gauge >/dev/null 2>&1 || true
  fi
fi
asb_feature_enabled WIFI && setprop persist.vendor.wlan.scan_throttle 1 2>/dev/null
asb_feature_enabled BT && setprop persist.vendor.bluetooth.btsnoopenable false 2>/dev/null
exit 0
