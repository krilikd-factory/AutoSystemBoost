#!/system/bin/sh
# smart_dynamic_tune.sh — Smart Mode runtime tuner.
#
# Invoked by the C governor whenever Smart Mode's app_hint, thermal state, or
# screen state changes substantially. Pushes lightweight system tweaks
# (readahead, MGLRU, I/O depth, VM, GPU max) to match the current scenario
# without rotating profiles.
#
# Arguments: <hint> <thermal_bucket> <screen_on>
#   hint:            0=idle 1=light 2=medium 3=heavy 4=gaming
#   thermal_bucket:  0=cool 1=warm 2=hot
#   screen_on:       0|1
#
# All writes are best-effort; missing nodes are silently skipped.

set -u

HINT="${1:-2}"
THERM="${2:-0}"
SCREEN="${3:-1}"

writef() {
  [ -w "$1" ] || return 0
  echo "$2" > "$1" 2>/dev/null || true
}

# I/O tuning: read_ahead_kb + nr_requests per scenario.
# Gaming/heavy: deeper queue + larger readahead for asset streaming.
# Idle/light/screen-off: shallow queue + minimal readahead to save power.
case "$HINT" in
  4) ra=512; nrq=256 ;;   # gaming
  3) ra=384; nrq=192 ;;   # heavy
  2) ra=192; nrq=128 ;;   # medium
  1) ra=96;  nrq=64  ;;   # light
  *) ra=64;  nrq=64  ;;   # idle
esac
# Screen off drops readahead further regardless of hint.
[ "$SCREEN" = "0" ] && { ra=48; nrq=64; }

for b in /sys/block/sd* /sys/block/mmcblk* /sys/block/dm-*; do
  [ -d "$b/queue" ] || continue
  [ "$(cat "$b/queue/rotational" 2>/dev/null)" = "1" ] && continue
  writef "$b/queue/read_ahead_kb" "$ra"
  writef "$b/queue/nr_requests"   "$nrq"
done

# MGLRU enable + behaviour. 7 = full LRU gen tracking, used during heavy/gaming
# where reclaim accuracy matters. 5 = relaxed for idle/screen-off.
if [ -w /sys/kernel/mm/lru_gen/enabled ]; then
  case "$HINT" in
    3|4) writef /sys/kernel/mm/lru_gen/enabled 7 ;;
    *)   writef /sys/kernel/mm/lru_gen/enabled 5 ;;
  esac
fi

# VM dirty ratios — favour aggressive flushing on screen-off + cool device
# so writeback completes during idle and doesn't bite during the next session.
if [ "$SCREEN" = "0" ]; then
  writef /proc/sys/vm/dirty_ratio 40
  writef /proc/sys/vm/dirty_background_ratio 10
  writef /proc/sys/vm/laptop_mode 1
else
  writef /proc/sys/vm/laptop_mode 0
  case "$HINT" in
    4|3)
      writef /proc/sys/vm/dirty_ratio 5
      writef /proc/sys/vm/dirty_background_ratio 2 ;;
    *)
      writef /proc/sys/vm/dirty_ratio 20
      writef /proc/sys/vm/dirty_background_ratio 5 ;;
  esac
fi

# Swappiness — light apps tolerate compressed pages; gaming wants files in RAM.
# Capped at 90 (not 100): maxing swappiness made the UI stutter on zram even
# with free RAM (same jank fixed in the battery profile).
case "$HINT" in
  4) writef /proc/sys/vm/swappiness 60  ;;
  3) writef /proc/sys/vm/swappiness 80  ;;
  *) writef /proc/sys/vm/swappiness 90  ;;
esac

# Thermal back-off: when bucket=2 (hot), force shorter readahead and shallower
# I/O queue regardless of hint. This catches cap escalation before the FSM
# even hits the thermal_veto path.
if [ "$THERM" = "2" ]; then
  for b in /sys/block/sd* /sys/block/mmcblk*; do
    [ -d "$b/queue" ] || continue
    [ "$(cat "$b/queue/rotational" 2>/dev/null)" = "1" ] && continue
    writef "$b/queue/read_ahead_kb" 64
    writef "$b/queue/nr_requests"   64
  done
fi

exit 0
