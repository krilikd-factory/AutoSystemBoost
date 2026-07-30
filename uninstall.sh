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

# Some root managers / mount helpers leave a per-module work artifact next to the module dir
# (e.g.
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

# Stop our own daemons FIRST.
#
# Uninstall removed every file and restored every setting, and then left the governor and the
# DSP attach daemon running - they were started at boot from directories this script is
# deleting, and a running process outlives the unlink of its binary.
for _p in asb_dsp_attach asb_governor; do
  pkill -f "$_p" >/dev/null 2>&1 || true
done
# The governor's own binary is plain "asb"; match the full path so this cannot hit an
# unrelated process that merely has those three letters in its command line.
pkill -f '/data/adb/modules/AutoSystemBoost/bin/asb' >/dev/null 2>&1 || true
pkill -f '/data/adb/asb/asb_dsp_attach' >/dev/null 2>&1 || true
rm -rf /dev/.asb /dev/.asb_profile_state 2>/dev/null
rm -f /data/adb/asb/auto_battery_origin 2>/dev/null
# Camera tuning baselines.
#
# These outlived the module, and that is what made the compounding bug unrecoverable without
# hand-editing: remove ASB, reinstall it, and the "pristine stock" it copied from was the
# previous install's graded output, still sitting in tweak_base.
# Clearing them on uninstall means the live partition is genuinely stock by the time anything
# reads it, so remove-then-install repairs a device instead of preserving the damage.
rm -rf /data/adb/asb/tweak_base 2>/dev/null

# Restore any runtime tracking settings we changed (settings DB), then remove the data dir.
# Both files use the same key|value format: tracking_restore.log for the analytics settings,
# oem_restore.log for OEM-owned toggles (RAM expansion and friends).
for _rf in /data/adb/asb/tracking_restore.log /data/adb/asb/oem_restore.log \
           /data/adb/asb/haptics_baseline.conf; do
  [ -f "$_rf" ] || continue
  while IFS='|' read -r _k _v; do
    [ -n "$_k" ] || continue
    if [ -z "$_v" ] || [ "$_v" = "null" ]; then
      settings delete global "$_k" >/dev/null 2>&1 || true
    else
      settings put global "$_k" "$_v" >/dev/null 2>&1 || true
    fi
  done < "$_rf"
done

# Put the route windows back before the state directory goes, and stop the link watcher.
# The originals were recorded the first time they were touched; without this the tuned
# initcwnd/initrwnd would survive the module that set them.
pkill -f "asb_net_routes.sh watch" >/dev/null 2>&1 || true
[ -f /data/adb/modules/AutoSystemBoost/runtime/asb_net_routes.sh ] && \
  sh /data/adb/modules/AutoSystemBoost/runtime/asb_net_routes.sh restore >/dev/null 2>&1 || true

# Put the lockscreen back before the state that records its previous value is deleted.
[ -f /data/adb/modules/AutoSystemBoost/runtime/asb_lockscreen_apply.sh ] && \
  sh -c 'sed -i "s|^lockscreen_skip_delayed=.*|lockscreen_skip_delayed=off|" \
    /data/adb/modules/AutoSystemBoost/config/governor.conf 2>/dev/null;
    sh /data/adb/modules/AutoSystemBoost/runtime/asb_lockscreen_apply.sh' >/dev/null 2>&1 || true

rm -rf /data/adb/asb 2>/dev/null

for _legacy in asb_active_profile asb_baseline.txt asb_profile_switches.log \
               asb_user_config asb_v45_cleanup_done asb_v46_athena_cleanup_done \
               asb_vendor_boot_counter asb_vendor_mounts.log \
               asb_vendor_overlay_active asb_recovery_disabled \
               asb_recovery_lock asb_debug; do
  rm -f "/data/adb/$_legacy" 2>/dev/null
done
