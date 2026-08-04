#!/system/bin/sh
# asb_blur_apply.sh - apply the disable_blur toggle without a reinstall.
#
# Blur has two owners and ASB was only ever addressing one of them, at the wrong time:
#
# WindowManager owns the shade, launcher, recents and lock screen blur.
# ASB never wrote it at all, which is the single biggest reason the toggle looked dead next to
# modules that do.
#
# On top of that, the system.prop block was only ever built by common/install.sh.
# The WebUI toggle writes governor.conf at runtime, so flipping it and rebooting rebuilt
# nothing - the same class of bug that made media_loudness unapplyable.

# Settings wrapper: falls back to the content provider where the `settings` command
# cannot reach the service. On a OnePlus 15R every call returned "Failure calling
# service settings" while exiting 0, so writes looked successful and reads returned the
# error text as a value - this makes those calls work without changing any of them.
[ -f "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh" ] && \
  . "${MODDIR:-/data/adb/modules/AutoSystemBoost}/runtime/asb_settings.sh"

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
PROP="$MODDIR/system.prop"
[ -f "$CONF" ] || { echo "config not found: $CONF"; exit 1; }

_db="$(grep -E '^[[:space:]]*disable_blur=' "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
# stock | light | off off - no blur anywhere.
#
# "light" exists because "off" removes the blur behind notification popups too, and a heads-up
# SMS then sits directly on top of whatever the launcher is showing: white text on wallpaper,
# effectively unreadable.
# That was reported with a screenshot, and it is not a corner case - it is what every
# notification looks like.
#
# The split is possible because the two owners are independent.
#
# Exactly two controls on this platform actually do anything: settings global
# disable_window_blurs - WindowManager, live persist.sys.sf.disable_blurs - SurfaceFlinger,
# read at service start Both are GLOBAL.
#
# The ro.oplus.* and ro.launcher.* keys look per-surface and are not usable: they are read-only
# properties consumed by processes that start before the module mounts, so a module-supplied
# value arrives too late.
# A "light" mode built from those alone was indistinguishable from stock - reported as "включил
# режим лайт, всё как в стоке" - and before that, a version that also set the global ones was
# indistinguishable from off.
case "$_db" in
  1|on|true|off|light|partial) _db=1 ;;   # light folded into off; old configs keep working
  *)                           _db=0 ;;
esac

# ui_effects_level is SEPARATE from blur, and it has to be.
#
# persist.sys.oplus.anim_level is not a blur property at all: it is OxygenOS's overall
# visual-effects level, and dropping it to 0 switches Recents from card previews to a flat
# list, among other things.
# Reported exactly that way, and the setting's own description never mentioned it.
#
# Blur off with effects untouched is a perfectly reasonable combination, and now it is
# expressible. stock = do not touch it at all, which is also the default: a setting that
# reshapes the launcher should be something you asked for.
_ue="$(grep -E '^[[:space:]]*ui_effects_level=' "$CONF" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
case "$_ue" in
  flat|0)  _ue="flat" ;;
  stock|1) _ue="stock" ;;
  # Unset, or anything unrecognised: FOLLOW BLUR.
  #
  # anim_level used to be part of disable_blur, and it is the half people actually see - flat
  # Recents, simpler transitions.
  # Splitting it out was correct (blur off with cards intact is a reasonable thing to want) but
  # defaulting the new key to "stock" silently took that half away from everyone who already
  # had blur off: same switch, visibly less effect, reported as "отключение блюра не работает".
  #
  # So an absent key means "whatever blur is doing", which reproduces the old behaviour
  # exactly.
    # Unset or unrecognised: DO NOTHING. Never follow blur.
    #
    # This used to resolve to "flat" whenever blur was off, on the reasoning that the two were
    # once one setting.
    # The consequence was a side effect nobody asked for: switching blur off wrote
    # persist.sys.oplus.anim_level=0, which flattens Recents AND removes the Cards/Simple
    # selector from Recent Tasks Manager entirely - reported by a OnePlus 13 user who never
    # touched a Recents setting and got the option back only by uninstalling the module.
    *)       _ue="stock" ;;
esac

# --- live half: WindowManager, takes effect immediately -----------------------
# Write only when the live value actually differs.
#
# WindowManager watches this key and rebuilds its blur state on any change to it,
# including a write of the value it already holds - the observer fires on the write,
# not on the difference. Doing that during boot is why the launcher background showed
# unblurred for about a second the first time the app drawer opened and then corrected
# itself. The boot re-assert in service.sh was guarded for exactly this; this copy,
# which runs on the same boot, was not.
_blur_want=0
[ "$_db" = "1" ] && _blur_want=1
_blur_live="$(settings get global disable_window_blurs 2>/dev/null)"
case "$_blur_live" in ''|null) _blur_live=0 ;; esac
if [ "$_blur_live" != "$_blur_want" ]; then
  settings put global disable_window_blurs "$_blur_want" 2>/dev/null
fi
# wm is idempotent for the compositor side and does not invalidate the observer, so it
# stays unconditional - it is what makes the setting take on a cold boot.
if [ "$_blur_want" = "1" ]; then
  wm disable-blur true >/dev/null 2>&1 || true
else
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
    -e '/^# ASB:UIFX:BEGIN$/,/^# ASB:UIFX:END$/d' \
    -e '/^persist\.sys\.oplus\.anim_level=/d' \
    -e '/^persist\.sys\.oplus\.material_blur_switch=/d' \
    -e '/^persist\.sys\.sf\.disable_blurs=/d' \
    -e '/^vendor\.display\.supports_background_blur=/d' \
    "$PROP" > "$_pt" 2>/dev/null || cp -f "$PROP" "$_pt"
{
  echo "# ASB:BLUR:BEGIN"
  # OFF only. These are global kill switches, not per-surface ones.
  #
  # supports_background_blur=0 and disable_blurs=1 tell SurfaceFlinger that background blur
  # does not exist at all - and every blurred surface goes through SurfaceFlinger, including
  # the backdrop behind a notification and the volume panel.
  # Setting them for "light" made light and off identical, which is exactly what was reported:
  # "кажется режим light и выкл делают одно и то же".
  if [ "$_db" = "1" ]; then
    echo "persist.sys.sf.disable_blurs=1"
    echo "ro.surface_flinger.supports_background_blur=0"
    echo "ro.surface_flinger.media_panel_bg_blur=0"
    echo "persist.sys.oplus.material_blur_switch=false"
    # The VENDOR display stack has its own capability flag, and it is the one that was still
    # on.
    # On a OnePlus 13 every key above applied cleanly and SurfaceFlinger reported
    # backgroundBlurRadius=0 on every layer - blur was off at the AOSP layer and the user still
    # saw it, because OPLUS composes its own blur through the display HAL and
    # vendor.display.supports_background_blur=1 kept that path alive.
    echo "vendor.display.supports_background_blur=0"
  fi
  # LIGHT and OFF share only the targeted ones: the volume panel's own blur, the launcher's
  # app-launch blur, and the OEM gaussian level.
  if [ "$_db" = "1" ]; then
    # Kept as belt-and-braces for ColorOS builds that read them late enough to matter.
    # They are not load-bearing: the two globals above are what actually turns blur off.
    echo "ro.oplus.display.disable.volume_blur=1"
    echo "ro.oplus.gaussianlevel=0"
    echo "ro.launcher.blur.appLaunch=0"
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
  *) echo "blur stock - window blur is back now, compositor blur after a reboot" ;;
esac
# Clear the persisted property when the user is no longer asking for flat.
#
# Removing the line from system.prop stops us setting it on the NEXT boot, but the value is
# already in the device's property store and stays there. Without this, switching back to
# normal left Recents flat - and the Cards/Simple selector missing - forever.
if [ "$_ue" != "flat" ] && command -v resetprop >/dev/null 2>&1; then
  if [ "$(getprop persist.sys.oplus.anim_level 2>/dev/null)" = "0" ]; then
    resetprop --delete persist.sys.oplus.anim_level >/dev/null 2>&1
    echo "ui effects: cleared the stored flat-Recents flag - reboot to get the Cards/Simple selector back"
  fi
fi

[ "$_ue" = "flat" ] && echo "ui effects: flat (Recents becomes a plain list, and OxygenOS hides the Cards/Simple selector) - after a reboot"
exit 0
