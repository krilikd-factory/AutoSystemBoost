#!/system/bin/sh
MODID="AutoSystemBoost"
MODDIR="${0%/*}"
[ -z "$MODDIR" ] || [ "$MODDIR" = "$0" ] && MODDIR="/data/adb/modules/$MODID"

chmod 0755 "$MODDIR/system/bin/asb" 2>/dev/null

mkdir -p /data/adb/asb 2>/dev/null

# Camera/media overlay is shipped to system/vendor/odm ONLY (see install.sh),

# Clean up a phantom /data/adb/magisk/busybox symlink that earlier builds
if [ ! -x /data/adb/magisk/magisk ] && [ ! -x /data/adb/magisk/magisk64 ]; then
  if [ -L /data/adb/magisk/busybox ] && [ ! -e /data/adb/magisk/busybox ]; then
    rm -f /data/adb/magisk/busybox 2>/dev/null
    rmdir /data/adb/magisk 2>/dev/null
  fi
fi
for _legacy_pair in \
    "asb_vendor_boot_counter:vendor_boot_counter" \
    "asb_vendor_mounts.log:vendor_mounts.log" \
    "asb_vendor_overlay_active:vendor_overlay_active"; do
  _old="${_legacy_pair%:*}"
  _new="${_legacy_pair#*:}"
  if [ -e "/data/adb/$_old" ] && [ ! -e "/data/adb/asb/$_new" ]; then
    mv "/data/adb/$_old" "/data/adb/asb/$_new" 2>/dev/null || true
  elif [ -e "/data/adb/$_old" ]; then
    rm -f "/data/adb/$_old" 2>/dev/null || true
  fi
done

[ -r "$MODDIR/runtime/asb_baseline.sh" ] && . "$MODDIR/runtime/asb_baseline.sh"
command -v asb_persist_safe >/dev/null 2>&1 || asb_persist_safe() { setprop "$1" "$2" 2>/dev/null || true; }

# Apply / revert the opt-in aggressive audio + camera layers from their saved
if [ -r "$MODDIR/runtime/asb_tweaks.sh" ]; then
  . "$MODDIR/runtime/asb_tweaks.sh"
  asb_apply_dynamic_tweaks "$MODDIR"
fi

asb_feature_enabled() {
  _key="$1"
  [ -r "$MODDIR/features.conf" ] || return 0
  _line="$(grep -E "^${_key}=" "$MODDIR/features.conf" 2>/dev/null | tail -n 1)"
  [ -z "$_line" ] && return 0
  [ "${_line#*=}" = "1" ]
}
# ASB:LOG:BEGIN
if asb_feature_enabled LOG; then
asb_persist_safe persist.vendor.radio.adb_log_on 0
asb_persist_safe persist.vendor.radio.log_loc 0
asb_persist_safe persist.radio.low_priority_static_log 0
asb_persist_safe persist.vendor.ims.disableADBLogs 1
asb_persist_safe persist.vendor.ims.disableDebugDataPathLogs 1
asb_persist_safe persist.vendor.ims.disableDebugLogs 1
asb_persist_safe persist.vendor.ims.disableIMSLogs 1
asb_persist_safe persist.vendor.ims.disableQXDMLogs 1
asb_persist_safe persist.vendor.ims.dumpWiFiLogs 0
asb_persist_safe persist.vendor.ims.vt.enableadb 0
asb_persist_safe persist.vendor.logkit.ctrl 0
asb_persist_safe persist.vendor.logkit.logcat 0
asb_persist_safe persist.vendor.qcomlog.enable 0
asb_persist_safe persist.vendor.sys.log.collector 0
asb_persist_safe persist.sys.perfetto.disable 1
asb_persist_safe persist.vendor.perfetto.disable 1
asb_persist_safe persist.vendor.qti.telemetry.disable 1
fi
# ASB:LOG:END
if command -v resetprop >/dev/null 2>&1; then
  # ASB:LOG:BEGIN
  if asb_feature_enabled LOG; then
  resetprop -n tombstoned.max_tombstone_count 0 >/dev/null 2>&1 || true
  resetprop -n ro.lmk.log_stats false >/dev/null 2>&1 || true
  resetprop -n ro.lmk.debug false >/dev/null 2>&1 || true
  fi
  # ASB:LOG:END
  # ASB:BT:BEGIN
  if asb_feature_enabled BT; then
  resetprop --delete media.resolution.limit.16bit >/dev/null 2>&1 || true
  resetprop --delete media.resolution.limit.24bit >/dev/null 2>&1 || true
  resetprop --delete media.resolution.limit.32bit >/dev/null 2>&1 || true
  resetprop --delete media.resolution.limit.64bit >/dev/null 2>&1 || true
  resetprop --delete persist.bluetooth.a2dp_offload.disabled >/dev/null 2>&1 || true
  fi
  # ASB:BT:END
  # ASB:NET:BEGIN
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
  # ASB:NET:END
  # ASB:KERNEL:BEGIN
  if asb_feature_enabled KERNEL; then
  resetprop --delete persist.sys.power.fuel.gauge >/dev/null 2>&1 || true
  fi
  # ASB:KERNEL:END
fi
# ASB:WIFI:BEGIN
asb_feature_enabled WIFI && asb_persist_safe persist.vendor.wlan.scan_throttle 1
# ASB:WIFI:END
# ASB:BT:BEGIN
asb_feature_enabled BT && asb_persist_safe persist.vendor.bluetooth.btsnoopenable false
# ASB:BT:END
# ASB:VENDOR_OVERLAY:BEGIN
if asb_feature_enabled VENDOR_OVERLAY && [ -d "$MODDIR/system/vendor/etc/perf" ]; then
  _mounts_log="/data/adb/asb/vendor_mounts.log"
  _bootflag="/data/adb/asb/vendor_overlay_active"
  _bootctr="/data/adb/asb/vendor_boot_counter"
  _cur_ctr=$(cat "$_bootctr" 2>/dev/null || echo 0)
  case "$_cur_ctr" in ''|*[!0-9]*) _cur_ctr=0 ;; esac
  if [ "$_cur_ctr" -ge 3 ]; then
    echo "ts=$(date +%s) action=skip reason=bootloop_protection counter=$_cur_ctr" > "$_mounts_log"
    rm -f "$_bootflag" 2>/dev/null
    rm -f "$MODDIR"/system/vendor/etc/perf/* 2>/dev/null
  else
    _next_ctr=$((_cur_ctr + 1))
    echo "$_next_ctr" > "$_bootctr"
    echo "ts=$(date +%s) action=boot counter=$_next_ctr" > "$_mounts_log"
    echo 1 > "$_bootflag"
    if command -v resetprop >/dev/null 2>&1; then
      resetprop -n ro.vendor.perf.qape.boost_duration 3 >/dev/null 2>&1 || true
      resetprop -n ro.vendor.perf.qape.max_boost_count 1 >/dev/null 2>&1 || true
    fi
  fi
fi
# ASB:VENDOR_OVERLAY:END

exit 0
