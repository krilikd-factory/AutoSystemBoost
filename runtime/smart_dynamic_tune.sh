#!/system/bin/sh
# smart_dynamic_tune.sh — Smart Mode runtime tuner.

set -u

HINT="${1:-2}"
THERM="${2:-0}"
SCREEN="${3:-1}"

writef() {
  [ -w "$1" ] || return 0
  echo "$2" > "$1" 2>/dev/null || true
}

# I/O tuning: read_ahead_kb + nr_requests per scenario.
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

# The camera guard owns the VM knobs while a capture is streaming: it lowers
# swappiness for the duration and restores exactly what it found. Writing here at the
# same time both defeats the guard AND leaves the guard restoring a stale value over
# whatever this script set. The hold forces the FSM to HEAVY, which changes app_hint,
# which is precisely what triggers this script - so the collision was the common case,
# not the rare one. Leave the VM section alone until the guard releases.
_cam_guard=0
[ -f /dev/.asb/camera_guard ] && _cam_guard=1

# VM dirty limits — favour aggressive flushing on screen-off + cool device so writeback
# completes during idle and doesn't bite during the next session.
#
# dirty_ratio and dirty_bytes are MUTUALLY EXCLUSIVE in the kernel: writing one zeroes
# the other (mm/page-writeback.c). service.sh's apply_vm deliberately picks the BYTES
# family where the device offers it - it even zeroes the ratios on purpose to switch
# modes - so writing ratios here silently destroyed the profile's byte limits on the
# first tuner run and reverted the device to the percentage model. Whichever family is
# actually in force is now the one this script writes.
_dirty_mode="ratio"
if [ -r /proc/sys/vm/dirty_bytes ]; then
  _db_cur="$(cat /proc/sys/vm/dirty_bytes 2>/dev/null)"
  case "$_db_cur" in ''|0) : ;; *) _dirty_mode="bytes" ;; esac
fi

if [ "$_cam_guard" = "0" ]; then
  if [ "$SCREEN" = "0" ]; then
    if [ "$_dirty_mode" = "bytes" ]; then
      writef /proc/sys/vm/dirty_bytes 268435456
      writef /proc/sys/vm/dirty_background_bytes 67108864
    else
      writef /proc/sys/vm/dirty_ratio 40
      writef /proc/sys/vm/dirty_background_ratio 10
    fi
    writef /proc/sys/vm/laptop_mode 1
  else
    writef /proc/sys/vm/laptop_mode 0
    case "$HINT" in
      4|3) _dr=5;  _dbr=2  ; _dby=33554432;  _dbby=8388608  ;;
      *)   _dr=20; _dbr=5  ; _dby=134217728; _dbby=33554432 ;;
    esac
    if [ "$_dirty_mode" = "bytes" ]; then
      writef /proc/sys/vm/dirty_bytes "$_dby"
      writef /proc/sys/vm/dirty_background_bytes "$_dbby"
    else
      writef /proc/sys/vm/dirty_ratio "$_dr"
      writef /proc/sys/vm/dirty_background_ratio "$_dbr"
    fi
  fi
fi

# Swappiness — NUDGE the profile's value, never replace it.
#
# This used to write a flat 60/80/90 for every scenario, which overrode the profile
# outright: performance asks for 12 and got 60, balanced asks for 35 and got 90. The
# user's memory setting was meaningless in Smart Mode and the action screen reported a
# live value nobody had chosen - which is exactly what the field reports showed. The
# old comment ("gaming wants files in RAM") also argued for the opposite of what the
# numbers did: a LOWER swappiness reclaims file cache first, so 60 for gaming evicted
# more cache than 90 did for idle.
#
# The profile owns the baseline. Screen-off and idle can afford to lean harder on zram
# because nothing is waiting on a page; gaming and heavy pull the other way so a fault
# on the hot path is less likely. The nudge is bounded and clamped to 0..100.
if [ "$_cam_guard" = "0" ]; then
  _prof="$(cat /data/adb/asb/active_profile 2>/dev/null)"
  [ -n "$_prof" ] || _prof="$(cat /data/adb/modules/AutoSystemBoost/current_profile 2>/dev/null)"
  case "$_prof" in
    performance|battery) : ;;
    *) _prof="balanced" ;;   # smart blends battery<->balanced; balanced is its baseline
  esac
  _base="$(grep -E '^VM_SWAPPINESS=' "/data/adb/modules/AutoSystemBoost/profiles/${_prof}.sh" \
           2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r')"
  case "$_base" in ''|*[!0-9]*) _base=35 ;; esac

  if [ "$SCREEN" = "0" ]; then
    _swp=$((_base + 20))
  else
    case "$HINT" in
      4|3) _swp=$((_base - 10)) ;;
      1|0) _swp=$((_base + 10)) ;;
      *)   _swp=$_base ;;
    esac
  fi
  [ "$_swp" -lt 0 ]   && _swp=0
  [ "$_swp" -gt 100 ] && _swp=100
  writef /proc/sys/vm/swappiness "$_swp"
fi

# Thermal back-off: when bucket=2 (hot), force shorter readahead and shallower
if [ "$THERM" = "2" ]; then
  for b in /sys/block/sd* /sys/block/mmcblk*; do
    [ -d "$b/queue" ] || continue
    [ "$(cat "$b/queue/rotational" 2>/dev/null)" = "1" ] && continue
    writef "$b/queue/read_ahead_kb" 64
    writef "$b/queue/nr_requests"   64
  done
fi

exit 0
