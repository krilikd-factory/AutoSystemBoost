#!/system/bin/sh
# asb_camera_repair.sh - undo a compounded camera grade WITHOUT losing anything else.
#
# WHY THIS EXISTS
#
# Builds before this one cloned the "stock" camera tuning from the live partition. After
# one install that partition IS this module's own overlay, so each reinstall graded the
# previous install's output again. Measured on a OnePlus 15 across four installs:
#
#     saturation   x1.28 -> x1.51 -> x1.93 -> x2.47
#     sharpening   x1.50 -> x2.07 -> x3.10 -> x4.66     (USM 2.0 -> 9.315)
#     AI blend     a third of the weights pinned at their 1.0 ceiling
#
# The installer refuses to make this worse now, but it cannot undo it: every copy it
# could recover from is already graded, and the partition only reads back as genuine
# stock once nothing of ours is mounted over it.
#
# The obvious fix - uninstall and reinstall - works, but uninstall.sh does
# `rm -rf /data/adb/asb`, and that takes the Smart Mode learning with it: the bucket
# model, the app-heat table, the learned sleep window, months of session history. On a
# device with 500+ sessions that is a genuinely bad trade for a camera setting.
#
# So this does the narrow thing instead. There are exactly three places a graded camera
# file can hide, and this clears all three and nothing else:
#
#   1. the module overlay      /data/adb/modules/AutoSystemBoost/system/**/camera/...
#   2. the bind-mount source   /data/adb/asb/odm_patched/odm/etc/camera/...
#      (plus its line in odm_bind_manifest.txt)
#   3. the tuning baseline     /data/adb/asb/tweak_base/*conf_tuning_params.json.asbbase
#
# Learning data is never touched: buckets.bin, smart_appheat.bin, night_window.conf,
# session_history.jsonl, user_config and the rest of /data/adb/asb stay exactly as they
# are. Run it, reboot, reinstall the module. The camera comes back stock and the learner
# does not notice anything happened.
#
# Usage:  su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_camera_repair.sh'
#         su -c 'sh .../asb_camera_repair.sh --check'    (report only, change nothing)

MOD="/data/adb/modules/AutoSystemBoost"
ASB="/data/adb/asb"
MAN="$ASB/odm_bind_manifest.txt"
CHECK=0
[ "$1" = "--check" ] || [ "$1" = "-n" ] && CHECK=1

echo "ASB camera repair"
echo "-----------------"

# Stock is the standard BT.601 chroma term, identical on every device. Grading multiplies
# it, so anything outside the -0.1687xxx band has been graded at least once. This is the
# same test the installer uses to decide whether a file can be trusted.
_is_stock() {
  [ -f "$1" ] || return 1
  grep -m1 -o '"Main1x_Rgb2YuvParams"[^]]*]' "$1" 2>/dev/null \
    | grep -q -- '-0\.1687[0-9]*'
}

_report() {
  if _is_stock "$1"; then echo "    stock    $1"
  else echo "    GRADED   $1"; fi
}

echo
echo "  what is on the device now:"
_live="/odm/etc/camera/conf_tuning_params.json"
[ -f "$_live" ] && _report "$_live"
for _f in "$MOD"/system/odm/etc/camera/conf_tuning_params.json \
          "$MOD"/system/vendor/odm/etc/camera/conf_tuning_params.json \
          "$ASB"/odm_patched/odm/etc/camera/conf_tuning_params.json \
          "$ASB"/tweak_base/*conf_tuning_params.json.asbbase; do
  [ -f "$_f" ] && _report "$_f"
done

if [ "$CHECK" = "1" ]; then
  echo
  echo "  --check: nothing was changed."
  exit 0
fi

echo
echo "  clearing the three places a graded copy can hide:"
_n=0

# 1. module overlay
for _f in "$MOD"/system/odm/etc/camera/conf_tuning_params.json \
          "$MOD"/system/vendor/odm/etc/camera/conf_tuning_params.json; do
  if [ -f "$_f" ]; then rm -f "$_f" 2>/dev/null && { echo "    removed overlay copy"; _n=$((_n+1)); }; fi
done

# 2. bind-mount source + its manifest line. The manifest also carries the DSP effect
#    config, which is unrelated and must survive - so drop only the camera line.
if [ -f "$ASB/odm_patched/odm/etc/camera/conf_tuning_params.json" ]; then
  rm -f "$ASB/odm_patched/odm/etc/camera/conf_tuning_params.json" 2>/dev/null \
    && { echo "    removed bind-mount source"; _n=$((_n+1)); }
fi
if [ -f "$MAN" ]; then
  if grep -q "camera/conf_tuning_params.json" "$MAN" 2>/dev/null; then
    # grep -v exits 1 on empty output, i.e. when the camera line was the only one -
    # gating the mv on it would leave that line in place precisely when the manifest
    # consists of nothing else. Test for the file, not the exit status.
    grep -v "camera/conf_tuning_params.json" "$MAN" > "$MAN.tmp" 2>/dev/null
    if [ -f "$MAN.tmp" ]; then
      mv -f "$MAN.tmp" "$MAN" 2>/dev/null && echo "    dropped camera line from bind manifest"
      rm -f "$MAN.tmp" 2>/dev/null
    fi
  fi
fi

# 3. baselines
for _f in "$ASB"/tweak_base/*conf_tuning_params.json.asbbase; do
  [ -f "$_f" ] || continue
  rm -f "$_f" 2>/dev/null && { echo "    removed graded baseline"; _n=$((_n+1)); }
done

echo
if [ "$_n" = "0" ]; then
  echo "  nothing needed clearing."
else
  echo "  cleared $_n item(s)."
fi

echo
echo "  learning data left untouched:"
for _f in buckets.bin smart_appheat.bin night_window.conf session_history.jsonl user_config; do
  [ -f "$ASB/$_f" ] && printf "    kept  %-24s %s bytes\n" "$_f" "$(wc -c < "$ASB/$_f" 2>/dev/null)"
done

echo
echo "  NEXT: reboot, then check the camera is stock again:"
echo "    su -c 'grep -m1 SatuColorScale /odm/etc/camera/conf_tuning_params.json'"
echo "    expected 1.30 - if you see a larger number, something is still mounted."
echo "  Then reinstall the module. The grade will be applied once, from stock."
exit 0
