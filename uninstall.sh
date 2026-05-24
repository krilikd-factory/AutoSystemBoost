#!/system/bin/sh
# AutoSystemBoost uninstall — V46
# 1. Replay baseline (restores all settings/persist props/pm states that ASB changed)
# 2. Restore camera vendor props from camera_orig.conf
# 3. V46: force-delete Athena/COSA persist props that V44/V45 may have set on
#    OnePlus Ace 5-class devices (caused system_server deadlock); safe no-op
#    on devices that never had these set
# 4. Clean ASB scratch dirs and state files

MODDIR=${0%/*}

# Replay baseline written by service.sh helpers (asb_settings_put / asb_persist_safe / asb_pm_disable)
[ -r "$MODDIR/runtime/asb_baseline.sh" ] && . "$MODDIR/runtime/asb_baseline.sh"
command -v asb_baseline_replay >/dev/null 2>&1 && asb_baseline_replay

# Restore camera HAL props from snapshot
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

# V46 cleanup: remove Athena/COSA persist props that V44/V45 may have written.
# These caused system_server deadlock on OnePlus Ace 5 (SM8635 + OxygenOS 16).
# `resetprop --delete` removes the persist file from /data/property, breaking
# the lockup-on-reboot cycle for users upgrading from a buggy version. On
# devices that never had these set, resetprop --delete is a no-op.
for _athena_prop in \
    persist.sys.oplus.athena.reclaim_enable \
    persist.sys.oplus.athena.force_kill \
    persist.sys.oplus.athena.limit_count \
    persist.sys.oplus.deepthinker.reclaim_hint; do
  resetprop --delete "$_athena_prop" >/dev/null 2>&1 || true
done

# Clean baseline file itself
rm -f /data/adb/asb_baseline.txt 2>/dev/null

# Clean ASB scratch dirs and persistent state markers
rm -rf /dev/.asb 2>/dev/null
rm -rf /dev/.asb_profile_state 2>/dev/null
rm -f /data/adb/asb_vendor_mounts.log 2>/dev/null
rm -f /data/adb/asb_vendor_overlay_active 2>/dev/null
rm -f /data/adb/asb_vendor_boot_counter 2>/dev/null
rm -f /data/adb/asb_active_profile 2>/dev/null
rm -f /data/adb/asb_user_config 2>/dev/null
rm -f /data/adb/asb_debug 2>/dev/null
rm -f /data/adb/asb_v46_athena_cleanup_done 2>/dev/null
