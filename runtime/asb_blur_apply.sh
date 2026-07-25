#!/system/bin/sh
# asb_blur_apply.sh - apply the disable_blur toggle without a reinstall.
#
# Blur has two owners and ASB was only ever addressing one of them, at the wrong time:
#
#   WindowManager  owns the shade, launcher, recents and lock screen blur. It watches
#                  Settings.Global.disable_window_blurs LIVE - no reboot needed. ASB
#                  never wrote it at all, which is the single biggest reason the toggle
#                  looked dead next to modules that do.
#   SurfaceFlinger owns the compositor-level background blur and reads its properties
#                  once at process start, so that half genuinely needs a reboot.
#
# On top of that, the system.prop block was only ever built by common/install.sh. The
# WebUI toggle writes governor.conf at runtime, so flipping it and rebooting rebuilt
# nothing - the same class of bug that made media_loudness unapplyable. The module
# directory is on /data and writable, so the block can be rebuilt here; the root manager
# reads system.prop when it mounts the module, i.e. the next boot picks it up.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
PROP="$MODDIR/system.prop"
[ -f "$CONF" ] || { echo "config not found: $CONF"; exit 1; }

_db="$(grep -E '^[[:space:]]*disable_blur=' "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
case "$_db" in 1|on|true) _db=1 ;; *) _db=0 ;; esac

# --- live half: WindowManager, takes effect immediately -----------------------
if [ "$_db" = "1" ]; then
  settings put global disable_window_blurs 1 2>/dev/null
  wm disable-blur true >/dev/null 2>&1 || true
else
  settings put global disable_window_blurs 0 2>/dev/null
  wm disable-blur false >/dev/null 2>&1 || true
fi

# --- boot half: SurfaceFlinger, needs the reboot ------------------------------
[ -f "$PROP" ] || : > "$PROP"
_pt="${PROP}.asbblur$$"
sed -e '/^# ASB:BLUR:BEGIN$/,/^# ASB:BLUR:END$/d' \
    -e '/^ro\.surface_flinger\.supports_background_blur=/d' \
    -e '/^ro\.surface_flinger\.media_panel_bg_blur=/d' \
    -e '/^ro\.oplus\.display\.disable\.volume_blur=/d' \
    -e '/^ro\.oplus\.gaussianlevel=/d' \
    -e '/^ro\.launcher\.blur\.appLaunch=/d' \
    -e '/^persist\.sys\.oplus\.anim_level=/d' \
    -e '/^persist\.sys\.oplus\.material_blur_switch=/d' \
    -e '/^persist\.sys\.sf\.disable_blurs=/d' \
    "$PROP" > "$_pt" 2>/dev/null || cp -f "$PROP" "$_pt"
{
  echo "# ASB:BLUR:BEGIN"
  if [ "$_db" = "1" ]; then
    echo "persist.sys.sf.disable_blurs=1"
    echo "ro.surface_flinger.supports_background_blur=0"
    echo "ro.surface_flinger.media_panel_bg_blur=0"
    echo "ro.oplus.display.disable.volume_blur=1"
    echo "ro.oplus.gaussianlevel=0"
    echo "ro.launcher.blur.appLaunch=0"
    echo "persist.sys.oplus.anim_level=0"
    echo "persist.sys.oplus.material_blur_switch=false"
  fi
  echo "# ASB:BLUR:END"
} >> "$_pt"
mv -f "$_pt" "$PROP" 2>/dev/null || { cat "$_pt" > "$PROP"; rm -f "$_pt"; }

if [ "$_db" = "1" ]; then
  echo "blur disabled - window blur is off now, compositor blur after a reboot"
else
  echo "blur restored to stock - window blur is back now, compositor blur after a reboot"
fi
exit 0
