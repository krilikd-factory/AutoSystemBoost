#!/system/bin/sh


# ASB:SANITY_PASS: de-duplicated setprop entries already defined in system.prop
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


if command -v resetprop >/dev/null 2>&1; then
  resetprop -n tombstoned.max_tombstone_count 4 >/dev/null 2>&1 || true
  resetprop -n ro.lmk.log_stats false >/dev/null 2>&1 || true
  resetprop -n ro.lmk.debug false >/dev/null 2>&1 || true
fi

setprop persist.vendor.wlan.scan_throttle 1 2>/dev/null
setprop persist.vendor.bluetooth.btsnoopenable false 2>/dev/null

exit 0
