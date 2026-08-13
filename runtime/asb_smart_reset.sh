#!/system/bin/sh
# asb_smart_reset.sh - start the learner over.
#
# There is already a repair path for a store that fails validation: fall back to the
# backup, and seed defaults if that is bad too. What it cannot cover is a store that
# validates but no longer describes this device - after a kernel swap, a ROM update, or a
# reinstall onto hardware whose behaviour has changed underneath the recorded numbers.
#
# A user hit exactly that: sessions were being recorded and the module reported none, and
# the only fix anyone found was deleting /data/adb/asb by hand and reinstalling. That works
# but it also throws away the config, the baselines and the uninstall records - everything
# the module needs to put the phone back the way it found it. This removes only what the
# learner owns.

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
D=/data/adb/asb

# Stop the governor first. It holds the store in memory and writes it out on a timer, so
# resetting underneath a running process just gets the old data written back.
_was_running=0
if pgrep -f '/bin/asb$' >/dev/null 2>&1; then
  _was_running=1
  pkill -f '/bin/asb$' 2>/dev/null
  # Give it a moment to flush and exit cleanly - it saves the store on SIGTERM.
  _i=0
  while [ $_i -lt 10 ] && pgrep -f '/bin/asb$' >/dev/null 2>&1; do
    sleep 0.3
    _i=$(( _i + 1 ))
  done
fi

# Only the learner's own files. Config, baseline.txt, the uninstall records and the
# per-device bounds all stay: none of them are learned, and losing them is what made the
# manual folder deletion a bad trade.
for _f in buckets.bin buckets.bin.bak smart_appheat.bin \
          smart_prev_profile night_window.conf; do
  rm -f "$D/$_f" 2>/dev/null
done
rm -f /dev/.asb/learner_state.json 2>/dev/null

echo "smart: learning reset - buckets, app heat history and the sleep window are cleared"
echo "       config, baselines and uninstall records were left alone"

# Bring it back. A fresh store is seeded on the next start, so nothing else is needed.
if [ "$_was_running" = "1" ] && [ -x "$MODDIR/bin/asb" ]; then
  "$MODDIR/bin/asb" >/dev/null 2>&1 &
  echo "       governor restarted; it will seed a new store"
fi
exit 0
