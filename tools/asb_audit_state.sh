#!/system/bin/sh
# AutoSystemBoost — system state audit
#
# Dumps current state of everything ASB might have modified, so you can:
# - Confirm settings were actually applied (cross-check with baseline)
# - See what's still set after uninstall
# - Compare two devices side-by-side
#
# Usage: sh tools/asb_audit_state.sh [> /sdcard/asb_audit_$(date +%s).txt]

echo "===== ASB STATE AUDIT — $(date) ====="
echo

echo "--- Module info ---"
MODID="AutoSystemBoost"
for _d in /data/adb/modules/$MODID /data/adb/modules_update/$MODID; do
  if [ -f "$_d/module.prop" ]; then
    grep -E "^(id|version|versionCode)=" "$_d/module.prop"
    break
  fi
done
echo

echo "--- Active profile ---"
cat /data/adb/asb_active_profile 2>/dev/null || echo "(none)"
echo

echo "--- features.conf ---"
[ -f /data/adb/modules/$MODID/features.conf ] && cat /data/adb/modules/$MODID/features.conf
echo

echo "--- Baseline tracker ($([ -f /data/adb/asb_baseline.txt ] && wc -l < /data/adb/asb_baseline.txt || echo 0) entries) ---"
head -50 /data/adb/asb_baseline.txt 2>/dev/null || echo "(no baseline file)"
echo

echo "--- Current settings (global) — keys ASB touches ---"
for k in wifi_scan_always_enabled wifi_wakeup_enabled wifi_scan_throttle_enabled \
         wifi_suspend_optimizations_enabled wifi_verbose_logging_enabled \
         nearby_scanning_enabled wifi_country_code wifi_country_code_priority \
         assisted_gps_enabled gps_xtra_server ntp_server \
         bluetooth_btsnoop_default_mode bluetooth_disable_absolute_volume \
         bluetooth_voip_support device_idle_constants audio_safe_volume_state \
         dropbox_max_files network_recommendations_enabled \
         activity_starts_logging_enabled send_action_app_error \
         enhanced_connectivity_enabled adaptive_connectivity_enabled \
         settings_enable_monitor_phantom_procs \
         animator_duration_scale window_animation_scale transition_animation_scale \
         adaptive_battery_management_enabled ram_expand_size sem_low_heat_mode \
         location_background_throttle_interval_ms; do
  _v="$(settings get global "$k" 2>/dev/null)"
  printf '  global.%-50s = %s\n' "$k" "$_v"
done
echo

echo "--- Current settings (secure) — keys ASB touches ---"
for k in long_press_timeout multi_press_timeout bluetooth_btsnoop_default_mode \
         bluetooth_disable_absolute_volume; do
  _v="$(settings get secure "$k" 2>/dev/null)"
  printf '  secure.%-50s = %s\n' "$k" "$_v"
done
echo

echo "--- Disabled packages (pm list packages -d) ---"
pm list packages -d 2>/dev/null | head -30
echo

echo "--- Persist props (ASB-related) ---"
getprop | grep -E "^\[persist\.(sys\.midasd|sys\.ostatsd|sys\.statsd|sys\.traced|vendor\.statsd|sys\.crash_dumps|sys\.assert|sys\.bigdata|sys\.hydra|sys\.logkit|sys\.spc|sys\.stability|sys\.test_mode|vendor\.thermal|vendor\.battery|vendor\.bcl|vendor\.extreme|vendor\.delta_time|vendor\.cnss_diag|vendor\.hydra|vendor\.dpm|vendor\.cp|vendor\.tasksnapshot|vendor\.adapt|vendor\.batteryantiaging|vendor\.audio|asb)\." | head -50
echo

echo "--- /dev/.asb state file ---"
ls -la /dev/.asb/state /dev/.asb/governor.log 2>/dev/null
echo

echo "--- Profile switch log (last 10) ---"
[ -f /data/adb/asb_profile_switches.log ] && tail -10 /data/adb/asb_profile_switches.log
echo

echo "--- Conflict markers ---"
ls -la /data/adb/asb_vendor_*.* 2>/dev/null

echo
echo "===== END AUDIT ====="
