#!/system/bin/sh

# Settings wrapper: falls back to the content provider where the `settings` command
# cannot reach the service. On a OnePlus 15R every call returned "Failure calling
# service settings" while exiting 0, so writes looked successful and reads returned the
# error text as a value - this makes those calls work without changing any of them.
[ -f /data/adb/modules/AutoSystemBoost/runtime/asb_settings.sh ] && \
  . /data/adb/modules/AutoSystemBoost/runtime/asb_settings.sh

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
# Doze back to Android's own timings before the module goes.
# Put Athena's component back if we were the ones who disabled it.
if [ -f /data/adb/asb/athena_prev ]; then
  pm enable com.oplus.athena/com.oplus.athena.client.AthenaService >/dev/null 2>&1 || true
  rm -f /data/adb/asb/athena_prev 2>/dev/null
fi

settings delete global device_idle_constants >/dev/null 2>&1 || true

# Hand back location to every app the GNSS tweak restricted.
#
# asb_gnss_trim.sh records each package it touched and knows how to release them, but
# nothing called it on removal - so uninstalling the module would have left those apps
# without coarse location permanently, with no trace of who took it away. Read the record
# directly rather than running the script: by this point the module tree may already be
# gone, and the file lives outside it.
if [ -f /data/adb/asb/gnss_restricted ] && command -v appops >/dev/null 2>&1; then
  while IFS= read -r _gp; do
    case "$_gp" in ''|*[!A-Za-z0-9_.]*) continue ;; esac
    appops set "$_gp" COARSE_LOCATION allow >/dev/null 2>&1
  done < /data/adb/asb/gnss_restricted
  rm -f /data/adb/asb/gnss_restricted 2>/dev/null
fi

rm -f /data/adb/asb/auto_battery_origin /data/adb/asb/lockscreen_prev /data/adb/asb/lockscreen_result 2>/dev/null
# Camera tuning baselines.
#
# These outlived the module, and that is what made the compounding bug unrecoverable without
# hand-editing: remove ASB, reinstall it, and the "pristine stock" it copied from was the
# previous install's graded output, still sitting in tweak_base.
# Clearing them on uninstall means the live partition is genuinely stock by the time anything
# reads it, so remove-then-install repairs a device instead of preserving the damage.
rm -rf /data/adb/asb/tweak_base 2>/dev/null
# AOD is borrowed for the night window, not turned off - restore it before the baseline
# that records it disappears with the rest of the module state.
if [ -f /data/adb/asb/aod_baseline ]; then
  settings put secure doze_always_on "$(cat /data/adb/asb/aod_baseline 2>/dev/null || echo 1)" 2>/dev/null
  rm -f /data/adb/asb/aod_baseline 2>/dev/null
fi

# Restore any runtime tracking settings we changed (settings DB), then remove the data dir.
# Both files use the same key|value format: tracking_restore.log for the analytics settings,
# oem_restore.log for OEM-owned toggles (RAM expansion and friends).
for _rf in /data/adb/asb/tracking_restore.log /data/adb/asb/oem_restore.log \
           /data/adb/asb/haptics_baseline.conf; do
  [ -f "$_rf" ] || continue
  # tracking_restore.log and oem_restore.log are legacy global-key ledgers. Haptics has always
  # stored system-namespace keys in the same two-column shape; restoring those as global made a
  # remove/reinstall leave the physical feedback state behind. Keep both legacy formats explicit.
  case "$_rf" in */haptics_baseline.conf) _restore_ns=system ;; *) _restore_ns=global ;; esac
  while IFS='|' read -r _k _v; do
    [ -n "$_k" ] || continue
    if [ -z "$_v" ] || [ "$_v" = "null" ]; then
      settings delete "$_restore_ns" "$_k" >/dev/null 2>&1 || true
    else
      settings put "$_restore_ns" "$_k" "$_v" >/dev/null 2>&1 || true
    fi
  done < "$_rf"
done

# Put the route windows back before the state directory goes, and stop the link watcher.
# The originals were recorded the first time they were touched; without this the tuned
# initcwnd/initrwnd would survive the module that set them.
pkill -f "asb_net_routes.sh watch" >/dev/null 2>&1 || true
[ -f /data/adb/modules/AutoSystemBoost/runtime/asb_net_routes.sh ] && \
  sh /data/adb/modules/AutoSystemBoost/runtime/asb_net_routes.sh restore >/dev/null 2>&1 || true

# Give location back to apps ASB limited.
#
# Recorded per package: an app the user restricted themselves in Android settings stays
# restricted, because undoing their choice would be the same overreach in reverse.
if [ -f /data/adb/asb/gnss_restricted ] && command -v appops >/dev/null 2>&1; then
  while IFS= read -r _gp; do
    [ -n "$_gp" ] && appops set "$_gp" COARSE_LOCATION allow >/dev/null 2>&1
  done < /data/adb/asb/gnss_restricted
  rm -f /data/adb/asb/gnss_restricted 2>/dev/null
fi

# Let restricted apps out of the bucket we put them in.
#
# Only ones ASB moved, recorded as it went: a package the user restricted themselves stays
# restricted, because undoing their choice would be the same overreach in reverse.
if [ -f /data/adb/asb/wakelock_restricted ] && command -v am >/dev/null 2>&1; then
  while IFS= read -r _wp; do
    [ -n "$_wp" ] && am set-standby-bucket "$_wp" active >/dev/null 2>&1
  done < /data/adb/asb/wakelock_restricted
  rm -f /data/adb/asb/wakelock_restricted 2>/dev/null
fi

# Un-freeze GMS components.
#
# Recorded per component with the state it was found in: something the user had already
# disabled stays disabled, because re-enabling it would be inventing a state that never
# existed on this phone.
if [ -f /data/adb/asb/gms_components_frozen ] && command -v pm >/dev/null 2>&1; then
  while IFS='|' read -r _c _was; do
    [ -n "$_c" ] || continue
    [ "$_was" = "pkg-disabled" ] && continue
    pm enable "$_c" >/dev/null 2>&1
  done < /data/adb/asb/gms_components_frozen
  rm -f /data/adb/asb/gms_components_frozen 2>/dev/null
fi

# Undo the network offload changes.
#
# asb_net_offload.sh already has a _restore that replays net_offload_prev, and it runs when
# the tweak is set back to stock - but nothing called it on uninstall, so RPS masks and
# queue lengths kept ASB's values until the next reboot. Invoking the script's own restore
# is better than reimplementing it here: one copy of the logic, and it already knows the
# file format.
if [ -x "$MODDIR/runtime/asb_net_offload.sh" ] || [ -f "$MODDIR/runtime/asb_net_offload.sh" ]; then
  ASB_FORCE_RESTORE=1 sh "$MODDIR/runtime/asb_net_offload.sh" restore >/dev/null 2>&1
fi
rm -f /data/adb/asb/net_offload_prev 2>/dev/null

# Put the modem low-power settings back.
#
# asb_lpm.sh changes mobile_data_always_on and tcp_keepalive_time to let the modem idle
# between packets, and records what they were in lpm_baseline.conf - but nothing read that
# file back on removal. Both survive an uninstall: keepalive is a kernel sysctl that
# persists until reboot, and mobile_data_always_on is a settings row that persists
# indefinitely. So a user who removed ASB kept its network behaviour, which is the exact
# thing an uninstall is supposed to undo.
#
# Values come from the file, not from a guess: mobile_data_always_on differs between
# carriers and ROMs, and writing a fixed default would be inventing a state.
if [ -f /data/adb/asb/lpm_baseline.conf ]; then
  # Only KEY=value lines, and only the two keys we know - the file is ours, but sourcing
  # it blindly would run whatever ended up in there.
  _lpm_mdao="$(grep -E '^BASE_MDAO=' /data/adb/asb/lpm_baseline.conf 2>/dev/null | head -1 | sed 's/.*=//')"
  _lpm_ka="$(grep -E '^BASE_KEEPIDLE=' /data/adb/asb/lpm_baseline.conf 2>/dev/null | head -1 | sed 's/.*=//')"
  case "$_lpm_mdao" in
    ''|null|*[!0-9]*) : ;;
    *) command -v settings >/dev/null 2>&1 \
         && settings put global mobile_data_always_on "$_lpm_mdao" >/dev/null 2>&1 ;;
  esac
  case "$_lpm_ka" in
    ''|*[!0-9]*) : ;;
    *) [ -w /proc/sys/net/ipv4/tcp_keepalive_time ] \
         && echo "$_lpm_ka" > /proc/sys/net/ipv4/tcp_keepalive_time 2>/dev/null ;;
  esac
fi

# Restore the headphone volume limiter.
#
# ASB only ever removes this when explicitly asked, but "explicitly asked" does not survive
# uninstalling the module - leaving a hearing-safety cap off after the software that
# removed it is gone is not a state anyone chose. Every other setting here is restored;
# this one was missed, and it is the one with a consequence that is not about battery.
#
# 3 is Android's default (SAFE_MEDIA_VOLUME_ENABLED). Written unconditionally: the value
# is the same on every device, so there is no baseline to consult.
if command -v settings >/dev/null 2>&1; then
  settings put global audio_safe_volume_state 3 >/dev/null 2>&1
fi

# Put the global uclamp floor back.
#
# 1024 is the stock value on every device this runs on - it is the kernel default and
# what OxygenOS ships - so restoring it flat is safe and does not need a recorded
# baseline. It also resets itself on the next boot; this is for the user who removes
# the module and does not reboot before judging the result.
[ -w /proc/sys/kernel/sched_util_clamp_min ] \
  && echo 1024 > /proc/sys/kernel/sched_util_clamp_min 2>/dev/null

# Restore Doze exemptions we removed.
#
# Recorded per package rather than replayed wholesale: an exemption the user granted
# deliberately must come back, and one they never had must not appear.
if [ -f /data/adb/asb/doze_whitelist_removed ] && command -v dumpsys >/dev/null 2>&1; then
  while IFS= read -r _p; do
    [ -n "$_p" ] && dumpsys deviceidle whitelist "+$_p" >/dev/null 2>&1
  done < /data/adb/asb/doze_whitelist_removed
  rm -f /data/adb/asb/doze_whitelist_removed 2>/dev/null
fi

# Give Google Play services its permissions back.
#
# The appops are recorded in baseline.txt and replayed by the loop above, but the doze
# whitelist and the standby bucket are not settings - they need naming explicitly, and a
# user who removes ASB and then misses a notification will not connect the two.
if command -v cmd >/dev/null 2>&1; then
  cmd appops set com.google.android.gms RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1
  cmd appops set com.google.android.gms PSEUDO_LOCATION_REPORTING allow >/dev/null 2>&1
  cmd appops set com.google.android.googlequicksearchbox RUN_IN_BACKGROUND allow >/dev/null 2>&1
  am set-standby-bucket com.google.android.gms active >/dev/null 2>&1
  am set-standby-bucket com.google.android.googlequicksearchbox active >/dev/null 2>&1
  dumpsys deviceidle whitelist +com.google.android.gms >/dev/null 2>&1
fi

# Put the network sysctls back before the file that remembers them is deleted.
#
# These are not settings or properties, so they never entered baseline.txt - the generic
# restore loop above cannot see them. They do reset themselves on the next boot, but
# "uninstall the module and it is gone" should not require a reboot to be true, and a
# user removing ASB because something felt wrong is exactly the person who will not
# reboot before judging the result.
if [ -f /data/adb/asb/net_stock.env ]; then
  _ns_cc="$(grep -E '^STOCK_TCP_CC=' /data/adb/asb/net_stock.env 2>/dev/null | head -1 | sed 's/.*=//')"
  _ns_qd="$(grep -E '^STOCK_QDISC='  /data/adb/asb/net_stock.env 2>/dev/null | head -1 | sed 's/.*=//')"
  [ -n "$_ns_cc" ] && sysctl -w "net.ipv4.tcp_congestion_control=$_ns_cc" >/dev/null 2>&1
  [ -n "$_ns_cc" ] && [ -e /proc/sys/net/ipv6/tcp_congestion_control ] \
    && sysctl -w "net.ipv6.tcp_congestion_control=$_ns_cc" >/dev/null 2>&1
  [ -n "$_ns_qd" ] && sysctl -w "net.core.default_qdisc=$_ns_qd" >/dev/null 2>&1
fi

# If the active fallback had temporarily released Wi-Fi, restore it before its state is
# removed; the helper targets only its exact watcher argv and never touches other network tasks.
[ -f "$MODDIR/runtime/asb_wifi_fallback.sh" ] && MODDIR="$MODDIR" sh "$MODDIR/runtime/asb_wifi_fallback.sh" stop >/dev/null 2>&1 || true
rm -rf /data/adb/asb 2>/dev/null

for _legacy in asb_active_profile asb_baseline.txt asb_profile_switches.log \
               asb_user_config asb_v45_cleanup_done asb_v46_athena_cleanup_done \
               asb_vendor_boot_counter asb_vendor_mounts.log \
               asb_vendor_overlay_active asb_recovery_disabled \
               asb_recovery_lock asb_debug; do
  rm -f "/data/adb/$_legacy" 2>/dev/null
done
