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
# stock | light | off
#   off    - no blur anywhere. Cheapest, and the reason someone turns this on.
#   light  - keep the WindowManager blur, drop the compositor one.
#   stock  - untouched.
#
# "light" exists because "off" removes the blur behind notification popups too, and a
# heads-up SMS then sits directly on top of whatever the launcher is showing: white text
# on wallpaper, effectively unreadable. That was reported with a screenshot, and it is
# not a corner case - it is what every notification looks like.
#
# The split is possible because the two owners are independent. WindowManager draws the
# shade, the volume panel and notification backgrounds, and it is the cheap one: those
# surfaces are small and already composited. SurfaceFlinger's background blur is the
# expensive one - full-screen, every frame of a transition - and that is where the GPU
# saving actually comes from. Keeping the first while dropping the second gives readable
# notifications at most of the saving.
case "$_db" in
  1|on|true|off)  _db=1 ;;   # 1/on/true kept for configs written by older versions
  light|partial)  _db=2 ;;
  *)              _db=0 ;;
esac

# ui_effects_level is SEPARATE from blur, and it has to be.
#
# persist.sys.oplus.anim_level is not a blur property at all: it is OxygenOS's overall
# visual-effects level, and dropping it to 0 switches Recents from card previews to a
# flat list, among other things. It was bundled into disable_blur, so a user who wanted
# a sharp notification shade lost their Recents cards and had no way to get them back
# short of turning blur on again. Reported exactly that way, and the setting's own
# description never mentioned it.
#
# Blur off with effects untouched is a perfectly reasonable combination, and now it is
# expressible. stock = do not touch it at all, which is also the default: a setting that
# reshapes the launcher should be something you asked for.
_ue="$(grep -E '^[[:space:]]*ui_effects_level=' "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
case "$_ue" in flat|0) _ue="flat" ;; *) _ue="stock" ;; esac

# --- live half: WindowManager, takes effect immediately -----------------------
if [ "$_db" = "1" ]; then
  settings put global disable_window_blurs 1 2>/dev/null
  wm disable-blur true >/dev/null 2>&1 || true
else
  # light and stock both keep window blur on - that is the whole point of light.
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
    -e '/^ASB:UIFX:BEGIN$/,/^ASB:UIFX:END$/d' \
    -e '/^persist\.sys\.oplus\.anim_level=/d' \
    -e '/^persist\.sys\.oplus\.material_blur_switch=/d' \
    -e '/^persist\.sys\.sf\.disable_blurs=/d' \
    "$PROP" > "$_pt" 2>/dev/null || cp -f "$PROP" "$_pt"
{
  echo "# ASB:BLUR:BEGIN"
  # The compositor half goes for BOTH off and light - it is the expensive one, and light
  # is defined as "keep the readable blur, drop the costly one".
  if [ "$_db" = "1" ] || [ "$_db" = "2" ]; then
    echo "persist.sys.sf.disable_blurs=1"
    echo "ro.surface_flinger.supports_background_blur=0"
    echo "ro.surface_flinger.media_panel_bg_blur=0"
    echo "ro.oplus.display.disable.volume_blur=1"
    echo "ro.oplus.gaussianlevel=0"
    echo "ro.launcher.blur.appLaunch=0"
    # material_blur_switch stays with blur: it IS a blur switch, whatever the value
    # spelling suggests.
    echo "persist.sys.oplus.material_blur_switch=false"
  fi
  echo "# ASB:BLUR:END"
  echo "# ASB:UIFX:BEGIN"
  if [ "$_ue" = "flat" ]; then
    echo "persist.sys.oplus.anim_level=0"
  fi
  echo "# ASB:UIFX:END"
} >> "$_pt"
mv -f "$_pt" "$PROP" 2>/dev/null || { cat "$_pt" > "$PROP"; rm -f "$_pt"; }

case "$_db" in
  1) echo "blur off - window blur is off now, compositor blur after a reboot" ;;
  2) echo "blur light - notification/shade blur kept, compositor blur off after a reboot" ;;
  *) echo "blur stock - window blur is back now, compositor blur after a reboot" ;;
esac
[ "$_ue" = "flat" ] && echo "ui effects: flat (Recents becomes a plain list) - after a reboot"
exit 0
