#!/system/bin/sh
MODID="AutoSystemBoost"
MODDIR="${0%/*}"
[ -z "$MODDIR" ] || [ "$MODDIR" = "$0" ] && MODDIR="/data/adb/modules/$MODID"
# Stage the attacher daemon into our OWN data dir and make it executable there. Setting the
# exec bit inside the module dir does not stick: the root manager re-applies its permissions
# to module files after installation, so the binary stays 0644 and cannot be exec'd
# (observed on device: "can't execute: Permission denied", no daemon, no log).
# /data/adb/asb is ours, so the mode set here survives.
if [ -f "$MODDIR/bin/asb_dsp_attach" ]; then
  mkdir -p /data/adb/asb 2>/dev/null
  cp -f "$MODDIR/bin/asb_dsp_attach" /data/adb/asb/asb_dsp_attach 2>/dev/null
  chmod 0755 /data/adb/asb/asb_dsp_attach 2>/dev/null
fi

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
if asb_feature_enabled VENDOR_OVERLAY && { [ -d "$MODDIR/system/vendor/etc/perf" ] || [ -d "$MODDIR/system/vendor/odm/etc/camera" ] || [ -d "$MODDIR/system/odm/etc/camera" ] || [ -d "$MODDIR/system/vendor/etc/audio" ] || [ -f "$MODDIR/generated_overlay_manifest.txt" ]; }; then
  _mounts_log="/data/adb/asb/vendor_mounts.log"
  _bootflag="/data/adb/asb/vendor_overlay_active"
  _bootctr="/data/adb/asb/vendor_boot_counter"
  _cur_ctr=$(cat "$_bootctr" 2>/dev/null || echo 0)
  case "$_cur_ctr" in ''|*[!0-9]*) _cur_ctr=0 ;; esac
  if [ "$_cur_ctr" -ge 3 ]; then
    echo "ts=$(date +%s) action=skip reason=bootloop_protection counter=$_cur_ctr" > "$_mounts_log"
    rm -f "$_bootflag" 2>/dev/null
    rm -f "$MODDIR"/system/vendor/etc/perf/* 2>/dev/null
    # The unified device-native pipeline clones THIS device's own audio, camera,
    # media, GPS and perf into the module. If the device has failed to boot 3x,
    # tear the whole generated overlay back out so it returns fully stock for all
    # of these (everything re-clones on the next clean reinstall). Audio is
    # included because a malformed mixer/effects file is a plausible boot blocker.
    # We remove by category AND replay the manifest, so anything generated is
    # covered even if the category list ever drifts.
    rm -rf "$MODDIR/system/vendor/etc/audio" \
           "$MODDIR/system/vendor/odm/etc/audio" \
           "$MODDIR/system/odm/etc/audio" 2>/dev/null
    rm -rf "$MODDIR/system/vendor/odm/etc/camera" \
           "$MODDIR/system/odm/etc/camera" \
           "$MODDIR/system/vendor/etc/camera" 2>/dev/null
    rm -f  "$MODDIR/system/vendor/etc/media_profiles"*.xml \
           "$MODDIR/system/vendor/odm/etc/media_profiles"*.xml \
           "$MODDIR/system/odm/etc/media_profiles"*.xml 2>/dev/null
    rm -f  "$MODDIR/system/vendor/etc/gps.conf" "$MODDIR/system/odm/etc/gps.conf" \
           "$MODDIR/system/vendor/odm/etc/gps.conf" \
           "$MODDIR/system/vendor/etc/izat.conf" "$MODDIR/system/odm/etc/izat.conf" \
           "$MODDIR/system/vendor/odm/etc/izat.conf" 2>/dev/null
    # Manifest replay: delete every file the generator recorded (belt + braces).
    if [ -f "$MODDIR/generated_overlay_manifest.txt" ]; then
      while IFS= read -r _gf; do
        case "$_gf" in '#'*|'') continue ;; esac
        rm -f "$MODDIR/$_gf" 2>/dev/null
      done < "$MODDIR/generated_overlay_manifest.txt"
      mv -f "$MODDIR/generated_overlay_manifest.txt" \
            "$MODDIR/generated_overlay_manifest.reverted.txt" 2>/dev/null
    fi
    echo "ts=$(date +%s) action=revert_generated_overlay reason=bootloop_protection" >> "$_mounts_log"
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

# Make the staged DSP library match dsp_effect_abi, HERE, before the overlay mounts.
#
# post-fs-data runs before the root manager mounts the module, so a swap done at this
# point is live on THIS boot. Doing it later - from service.sh or the WebUI - only takes
# effect on the NEXT one, which fails the one rule that matters: install, reboot once,
# it works.
#
# It is also the only thing that actually enforces the setting. The WebUI hook backgrounds
# the switcher with "&" inside ksu.exec, and that child does not survive the exec call
# returning; media_loudness and disable_blur looked like they worked only because both
# have a boot-time self-heal of their own. dsp_effect_abi had none, so on a OnePlus 15 the
# config read "legacy" while /vendor/lib64/soundfx/libasbdsp.so was still the 378760-byte
# AIDL build, and nothing anywhere was going to change that.
# Force the read-only blur keys with resetprop.
#
# system.prop is enough on some devices and not on others: on a OnePlus 13 every ro.*
# key below took effect from system.prop alone, while on a OnePlus 15 the same file left
# them at their original values - supports_background_blur still 1, gaussianlevel still
# 3 - and only the persist.* one applied. Same module, same file, different result,
# which is why "blur does not turn off" was reported from one device and not the other.
#
# resetprop rewrites the property area directly and does not care that a key is ro.*,
# so it works in both cases. post-fs-data runs before the UI stack starts, which is
# early enough for these to be read.
# Forcing these is guarded by the same boot counter the vendor overlay uses.
#
# vendor.display.supports_background_blur is gone from the list entirely: it is a display
# HAL CAPABILITY flag, not a switch, and telling the composer that the hardware cannot
# blur is not the same as asking it not to. It sat harmlessly in system.prop for months
# because on this platform system.prop never actually overrode ro.* - adding resetprop
# made it take effect for the first time, and the display stack stopped coming up.
# Reported as: first boot fine, enable everything, reboot, bootloop.
#
# The rest still need resetprop to work at all, so they stay - but behind the counter, so
# a device that fails to boot with them stops trying rather than looping. Three strikes
# matches the vendor-overlay logic above.
# Scrub the bootlooping property out of system.prop, wherever it came from.
#
# Removing it from the code that writes it is not enough: system.prop is a file that
# lives on the device and survives an update, so a phone that took the bad line once
# keeps it forever. It is read at boot before anything here can react, so this has to
# happen in post-fs-data and before the module mounts - and it has to run unconditionally,
# not behind the blur setting, because the line is already there regardless of what the
# config now says.
#
# Also resetprop it back to 1: the property is set at this point in the boot from the
# system.prop of the PREVIOUS boot's mount, and removing the line only helps next time.
if [ -f "$MODDIR/system.prop" ] \
   && grep -q '^vendor\.display\.supports_background_blur=' "$MODDIR/system.prop" 2>/dev/null; then
  sed -i '/^vendor\.display\.supports_background_blur=/d' "$MODDIR/system.prop" 2>/dev/null
  command -v resetprop >/dev/null 2>&1 \
    && resetprop -n vendor.display.supports_background_blur 1 >/dev/null 2>&1
fi

# Staged fail-safe for everything this module puts in system.prop.
#
# The blur counter below only guards the resetprop calls. The same properties also live
# in system.prop, which is applied by the root manager before any of our code runs - so a
# property that stops the device booting is beyond the reach of a guard that executes
# after it. The only thing that can help is removing the block on the NEXT boot, which is
# what this does.
#
# Two failed boots, then the whole ASB block comes out of system.prop and a marker is
# left behind naming what was dropped. Two rather than three: a bootloop is expensive to
# sit through, and the properties in question are cosmetic.
_pb_ctr="/data/adb/asb/prop_boot_counter"
_pb_n="$(cat "$_pb_ctr" 2>/dev/null || echo 0)"
case "$_pb_n" in ''|*[!0-9]*) _pb_n=0 ;; esac
if [ "$_pb_n" -ge 2 ] 2>/dev/null && [ -f "$MODDIR/system.prop" ]; then
  sed -i -e '/^# ASB:BLUR:BEGIN$/,/^# ASB:BLUR:END$/d' \
         -e '/^# ASB:UIFX:BEGIN$/,/^# ASB:UIFX:END$/d' \
         "$MODDIR/system.prop" 2>/dev/null
  mkdir -p /data/adb/asb 2>/dev/null
  {
    echo "ts=$(date +%s 2>/dev/null)"
    echo "reason=two consecutive boots did not complete"
    echo "action=removed the ASB blur and animation blocks from system.prop"
    echo "note=re-enable them one at a time in the WebUI to find the culprit"
  } > /data/adb/asb/prop_blocks_disabled 2>/dev/null
  echo 0 > "$_pb_ctr" 2>/dev/null
else
  mkdir -p /data/adb/asb 2>/dev/null
  echo $(( _pb_n + 1 )) > "$_pb_ctr" 2>/dev/null
fi

_blur_ctr="/data/adb/asb/blur_boot_counter"
_blur_flag="/data/adb/asb/blur_prop_active"
_blur_strikes="$(cat "$_blur_ctr" 2>/dev/null || echo 0)"
case "$_blur_strikes" in ''|*[!0-9]*) _blur_strikes=0 ;; esac
if [ -f "$_blur_flag" ] && [ "$_blur_strikes" -ge 3 ] 2>/dev/null; then
  _blur_force=0
else
  _blur_force=1
fi
if [ "$_blur_force" = "1" ] && command -v resetprop >/dev/null 2>&1 && [ -f "$MODDIR/config/governor.conf" ]; then
  _blur_want="$(grep -E '^[[:space:]]*disable_blur=' "$MODDIR/config/governor.conf" 2>/dev/null \
                | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_blur_want" in
    1|on|true|off|light|partial)
      for _bp in "ro.surface_flinger.supports_background_blur 0" \
                 "ro.surface_flinger.media_panel_bg_blur 0" \
                 "ro.oplus.display.disable.volume_blur 1" \
                 "ro.oplus.gaussianlevel 0" \
                 "ro.launcher.blur.appLaunch 0" \
                 "persist.sys.sf.disable_blurs 1" \
                 "persist.sys.oplus.material_blur_switch false"; do
        resetprop -n ${_bp} >/dev/null 2>&1 || true
      done
      mkdir -p /data/adb/asb 2>/dev/null
      echo $(( _blur_strikes + 1 )) > "$_blur_ctr" 2>/dev/null
      : > "$_blur_flag" 2>/dev/null
      ;;
  esac
fi

_abi_conf="$MODDIR/config/governor.conf"
if [ -f "$_abi_conf" ] && [ -f "$MODDIR/runtime/asb_dsp_abi_apply.sh" ]; then
  _abi_want="$(grep -E '^[[:space:]]*dsp_effect_abi=' "$_abi_conf" 2>/dev/null \
               | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]')"
  # "auto" is not a no-op: it means "whatever the installer's probe chose", which is
  # recorded in dsp_abi_installed. Skipping it made the switch one-way - trying legacy
  # once and setting the card back to auto left the legacy library staged, so the config
  # said auto while /vendor/lib64/soundfx/libasbdsp.so was still the 9488-byte legacy
  # build. On an AIDL-only device that is a silently dead DSP in every mode.
  if [ "$_abi_want" = "auto" ] || [ -z "$_abi_want" ]; then
    _abi_want="$(cat "$MODDIR/dsp_abi_installed" 2>/dev/null)"
  fi
  case "$_abi_want" in
    legacy|aidl|aidl_v[0-9]*)
      _abi_src="$MODDIR/bin/libasbdsp.so"
      case "$_abi_want" in
        legacy)   _abi_src="$MODDIR/bin/libasbdsp_legacy.so" ;;
        aidl_v*)  _abi_src="$MODDIR/bin/libasbdsp_${_abi_want#aidl_}.so" ;;
      esac
      _abi_dst="$MODDIR/system/vendor/lib64/soundfx/libasbdsp.so"
      if [ -f "$_abi_src" ] && [ -f "$_abi_dst" ] && ! cmp -s "$_abi_src" "$_abi_dst"; then
        sh "$MODDIR/runtime/asb_dsp_abi_apply.sh" "$_abi_want" >/dev/null 2>&1
      fi
      ;;
  esac
fi

exit 0
