#!/system/bin/sh
# asb_media_apply.sh - rebuild the overlay files that only the installer used to touch.
#
# media_loudness reshapes /vendor/etc/default_volume_tables.xml, which audiopolicy
# parses once at boot. That much was always true, and the WebUI correctly said
# "reboot to apply". What was NOT true is that a reboot would apply it: the reshape
# ran inside common/install.sh and nowhere else, so changing the setting after the
# module was installed wrote the config, promised a reboot, and then rebuilt nothing.
# The action screen reported "loudness max - volume table not reshaped" on a device
# that had been rebooted twice, which is exactly what the user was told to do.
#
# The overlay lives under /data, so the file CAN be rebuilt at runtime - it is only
# the parse that needs the reboot. This script does the rebuild; the reboot the WebUI
# asks for now genuinely finishes the job.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
[ -f "$CONF" ] || { echo "config not found: $CONF"; exit 1; }
[ -r "$MODDIR/runtime/asb_volume_curves.sh" ] || {
  echo "asb_volume_curves.sh missing - reinstall the module"; exit 1; }
. "$MODDIR/runtime/asb_volume_curves.sh"

_cfg() {
  grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r' | tr '[:upper:]' '[:lower:]'
}

_ml="$(_cfg media_loudness)"
case "$_ml" in mild|strong|max) : ;; *) _ml="stock" ;; esac
_pct="$(asb_volume_curves_pct "$_ml")"

if [ "$_pct" = "100" ]; then
  asb_volume_curves_build "$MODDIR" 100
  # /odm-side copies live in the runtime bind staging area, not the overlay.
  asb_volume_odm_bind_build 100 >/dev/null 2>&1
  echo "media_loudness=stock - volume table reverted to the device's own curves"
  echo "reboot to apply"
  exit 0
fi

asb_volume_odm_bind_build "$_pct" >/dev/null 2>&1
if asb_volume_curves_build "$MODDIR" "$_pct"; then
  echo "media_loudness=${_ml} - volume table rebuilt from the pristine stock copy"
  echo "reboot to apply"
  exit 0
fi

# Be specific about which half failed: a missing stash and a failed write need
# different answers, and "it didn't work" has cost enough field time already.
# Stashes are per-path now (one per volume table the device ships), so look for any.
if [ -z "$(ls -1 /data/adb/asb/stock/ 2>/dev/null | grep -c 'default_volume_tables')" ] \
   || [ "$(ls -1 /data/adb/asb/stock/ 2>/dev/null | grep -c 'default_volume_tables')" = "0" ]; then
  echo "no pristine stock volume table stashed - reinstall the module once so it can capture one"
else
  echo "could not write the overlay copy - check that $MODDIR is writable"
fi
exit 1
