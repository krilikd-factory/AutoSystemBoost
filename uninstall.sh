#!/system/bin/sh

MODDIR=${0%/*}

_BL=/data/adb/asb/baseline.txt
_BL_TMP=/data/adb/.asb_uninstall_baseline
_CC_FORCED=0
[ -f /data/adb/asb/wifi_cc_forced ] && _CC_FORCED=1

if [ -f "$_BL" ]; then
  cp -f "$_BL" "$_BL_TMP" 2>/dev/null
  while IFS='|' read -r _type _a1 _a2 _a3; do
    [ "$_type" = "prop" ] || continue
    if [ -z "$_a2" ]; then
      resetprop -p --delete "$_a1" >/dev/null 2>&1 || resetprop --delete "$_a1" >/dev/null 2>&1 || true
    else
      setprop "$_a1" "$_a2" 2>/dev/null || resetprop "$_a1" "$_a2" >/dev/null 2>&1 || true
    fi
  done < "$_BL"
fi

if [ -f "$_BL_TMP" ] || [ "$_CC_FORCED" = "1" ]; then
  (
    _t=0
    while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$_t" -lt 240 ]; do
      sleep 5
      _t=$((_t + 5))
    done
    sleep 5
    if [ -f "$_BL_TMP" ]; then
      while IFS='|' read -r _type _a1 _a2 _a3; do
        case "$_type" in
          settings)
            if [ -z "$_a3" ]; then
              settings delete "$_a1" "$_a2" >/dev/null 2>&1 || true
            else
              settings put "$_a1" "$_a2" "$_a3" >/dev/null 2>&1 || true
            fi
            ;;
          pm)
            [ "$_a2" = "enabled" ] && pm enable --user 0 "$_a1" >/dev/null 2>&1 || true
            ;;
        esac
      done < "$_BL_TMP"
      rm -f "$_BL_TMP" 2>/dev/null
    fi
    if [ "$_CC_FORCED" = "1" ]; then
      cmd -w wifi force-country-code disabled >/dev/null 2>&1 || true
    fi
    if command -v cmd >/dev/null 2>&1; then
      for _dc_pair in \
        "gms|AdvertisingId__enable_ad_id_reconciliation" \
        "gms|AdsIdentity__enable_status_service" \
        "gms|AdsIdentity__enable_mendel_property_update" \
        "measurement|measurement.service.disable" \
        "measurement|measurement.collection.enabled"; do
        cmd device_config delete "${_dc_pair%%|*}" "${_dc_pair#*|}" >/dev/null 2>&1 || true
      done
    fi
  ) &
fi

_cam_orig="$MODDIR/config/camera_orig.conf"
if [ -f "$_cam_orig" ]; then
  while IFS= read -r _line; do
    case "$_line" in "#"*|"") continue ;; esac
    _prop="${_line%%=*}"
    _val="${_line#*=}"
    if [ -n "$_prop" ]; then
      resetprop "$_prop" "$_val" >/dev/null 2>&1 || true
    fi
  done < "$_cam_orig"
fi

for _stale_prop in \
    persist.sys.oplus.athena.reclaim_enable \
    persist.sys.oplus.athena.force_kill \
    persist.sys.oplus.athena.limit_count \
    persist.sys.oplus.deepthinker.reclaim_hint \
    ro.audio.audiozoom \
    persist.bluetooth.spatial_audio_support; do
  resetprop --delete "$_stale_prop" >/dev/null 2>&1 || true
done

rm -rf /dev/.asb 2>/dev/null
rm -rf /dev/.asb_profile_state 2>/dev/null

# Some root managers / mount helpers leave a per-module work artifact next to the
# module dir (e.g. a hidden ".AutoSystemBoost-files" marker and a "CLEAR" dir)
# that they do NOT remove when the module is deleted. They are harmless but look
# like litter, so clean them from every modules root we know about.
for _mroot in /data/adb/modules /data/adb/modules_update \
              /data/adb/ksu/modules /data/adb/ksu/modules_update \
              /data/adb/ap/modules /data/adb/ap/modules_update; do
  rm -f  "$_mroot/.AutoSystemBoost-files" 2>/dev/null
  rm -rf "$_mroot/AutoSystemBoost/CLEAR" 2>/dev/null
done
# the snapshot of WebUI settings is intentionally kept across a plain reinstall,
# but on a real uninstall it should go too (it lives under /data/adb/asb which is
# removed below, so this is just belt-and-braces if that dir moved).
rm -f /data/adb/asb/governor.conf.snapshot 2>/dev/null

# Restore any runtime tracking settings we changed (settings DB), then remove
# the data dir. Reading the log before deleting it is intentional.
if [ -f /data/adb/asb/tracking_restore.log ]; then
  while IFS='|' read -r _k _v; do
    [ -n "$_k" ] || continue
    if [ -z "$_v" ] || [ "$_v" = "null" ]; then
      settings delete global "$_k" >/dev/null 2>&1 || true
    else
      settings put global "$_k" "$_v" >/dev/null 2>&1 || true
    fi
  done < /data/adb/asb/tracking_restore.log
fi

rm -rf /data/adb/asb 2>/dev/null

for _legacy in asb_active_profile asb_baseline.txt asb_profile_switches.log \
               asb_user_config asb_v45_cleanup_done asb_v46_athena_cleanup_done \
               asb_vendor_boot_counter asb_vendor_mounts.log \
               asb_vendor_overlay_active asb_recovery_disabled \
               asb_recovery_lock asb_debug; do
  rm -f "/data/adb/$_legacy" 2>/dev/null
done
