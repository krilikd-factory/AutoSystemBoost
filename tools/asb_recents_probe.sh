#!/system/bin/sh
# asb_recents_probe.sh - why is the Cards/Simple selector missing from Recent Tasks Manager?
#
# The selector disappears when the system decides card previews are impossible. Two things
# make that decision, and both are PERSISTENT properties - they live in the device's own
# property store, so removing a line from system.prop stops the module setting them but
# cannot undo a value already written by an earlier build.
#
# This prints what each of them is right now, whether ASB is responsible, and what to do.
#
# Usage: su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_recents_probe.sh'

MODDIR="/data/adb/modules/AutoSystemBoost"
echo "=== ASB Recents probe ==="
echo "device:  $(getprop ro.product.model 2>/dev/null) / $(getprop ro.board.platform 2>/dev/null)"
echo "module:  $(grep -E '^version=' "$MODDIR/module.prop" 2>/dev/null | sed 's/.*=//')"
echo ""

_fault=0

# 1. Task snapshots - the thumbnails the Cards style draws.
echo "--- task snapshots (the thumbnails Cards draws) ---"
for _p in persist.enable_task_snapshots \
          persist.vendor.enable_task_snapshots \
          persist.tasksnapshot.starting_window_enable \
          persist.vendor.tasksnapshot.starting_window_enable; do
  _v="$(getprop "$_p" 2>/dev/null)"
  case "$_v" in
    false|0) echo "  $_p = $_v   <-- BLOCKS Cards"; _fault=1 ;;
    '')      echo "  $_p = <unset>  (fine - the ROM decides)" ;;
    *)       echo "  $_p = $_v" ;;
  esac
done
echo ""

# 2. OxygenOS visual effects level - 0 flattens Recents outright.
echo "--- visual effects level ---"
_al="$(getprop persist.sys.oplus.anim_level 2>/dev/null)"
case "$_al" in
  0)  echo "  persist.sys.oplus.anim_level = 0   <-- BLOCKS Cards"; _fault=1 ;;
  '') echo "  persist.sys.oplus.anim_level = <unset>  (fine)" ;;
  *)  echo "  persist.sys.oplus.anim_level = $_al" ;;
esac
echo "  ui_effects_level setting = $(grep -E '^[[:space:]]*ui_effects_level=' "$MODDIR/config/governor.conf" 2>/dev/null | sed 's/.*=//')"
echo ""

# 3. Is the module still SETTING any of them? Distinguishes "ASB did this" from "ASB did
#    this once and the value is stuck" - which need different answers.
echo "--- is the installed module still setting them? ---"
_setting=0
for _n in enable_task_snapshots tasksnapshot.starting_window_enable oplus.anim_level; do
  # Match assignments only. system.prop carries a comment naming these properties to stop
  # anyone re-adding them, and a plain grep counted that comment as proof they were still
  # being set - reporting "install the newer build" to someone already running it.
  if grep -qE "^[[:space:]]*[a-z0-9_.]*${_n}[[:space:]]*=" "$MODDIR/system.prop" 2>/dev/null; then
    echo "  system.prop still contains: $_n"; _setting=1
  fi
done
[ "$_setting" = "0" ] && echo "  no - system.prop sets none of them (this build is clean)"
echo ""

echo "--- cleanup markers ---"
for _m in tasksnap_restored animlevel_restored; do
  [ -f "/data/adb/asb/$_m" ] && echo "  $_m: present (cleanup already ran)" \
                             || echo "  $_m: absent (cleanup will run next boot)"
done
echo ""

if [ "$_fault" = "1" ]; then
  echo ">>> Something is still blocking Cards."
  if [ "$_setting" = "1" ]; then
    echo ">>> This module build is writing it. Install the newer build."
  else
    echo ">>> This build does not write it, so the value is left over in the property"
    echo ">>> store from an earlier one. Clear it and reboot:"
    echo ">>>   su -c 'resetprop --delete persist.sys.oplus.anim_level'"
    echo ">>>   su -c 'resetprop --delete persist.enable_task_snapshots'"
    echo ">>>   su -c 'resetprop --delete persist.vendor.enable_task_snapshots'"
    echo ">>> then reboot twice."
  fi
else
  echo ">>> Nothing here is blocking Cards."
  echo ">>> If the selector is still missing, the cause is outside these two mechanisms -"
  echo ">>> send this output along with:  su -c 'getprop | grep -iE \"recent|snapshot|anim_level\"'"
fi
exit 0
