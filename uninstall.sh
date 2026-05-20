#!/system/bin/sh
MODDIR=${0%/*}

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

rm -rf /dev/.asb 2>/dev/null
rm -rf /dev/.asb_profile_state 2>/dev/null
rm -f /data/adb/asb_vendor_mounts.log 2>/dev/null
rm -f /data/adb/asb_vendor_overlay_active 2>/dev/null
rm -f /data/adb/asb_vendor_boot_counter 2>/dev/null
