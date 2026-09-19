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

# The camera guard owns the VM knobs while a capture is streaming: it lowers swappiness for the
# duration and restores exactly what it found.
_cam_guard=0
[ -f /dev/.asb/camera_guard ] && _cam_guard=1

# VM dirty limits — favour aggressive flushing on screen-off + cool device so writeback
# completes during idle and doesn't bite during the next session.
#
# dirty_ratio and dirty_bytes are MUTUALLY EXCLUSIVE in the kernel: writing one zeroes the
# other (mm/page-writeback.c).
# service.sh's apply_vm deliberately picks the BYTES family where the device offers it - it
# even zeroes the ratios on purpose to switch modes - so writing ratios here silently destroyed
# the profile's byte limits on the first tuner run and reverted the device to the percentage
# model.
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
    # Wi-Fi power save on while the screen is off.
    #
    # The radio otherwise stays fully awake between beacons. Power save lets it sleep in
    # the gaps and wake on the beacon, which is what the mode exists for - the trade is
    # a few milliseconds of extra latency on the first packet, invisible with the screen
    # off and material to nothing running there.
    #
    # Only for profiles that left it at auto: battery already forces it on and
    # performance deliberately forces it off, and neither choice should be overridden
    # from here. Restored on wake by the branch below, the same way the uclamp tier is.
    # Driven by the wifi_powersave tweak now, not by profile alone.
    #
    #   off        - do nothing, the shipped default
    #   screen_off - sleep the radio between beacons while the display is off
    #   always     - leave power save on regardless of screen state
    #
    # Default off because this is the user's radio: on a phone that streams or casts with
    # the screen off, the extra beacon latency is real, and nobody should discover a new
    # behaviour they did not ask for.
    _wpm="$(_cfg wifi_powersave)"
    case "$_wpm" in screen_off|always) : ;; *) _wpm=off ;; esac
    if [ "$_wpm" != "off" ] && command -v iw >/dev/null 2>&1; then
      _pm_now="$(iw dev wlan0 get power_save 2>/dev/null | grep -oE 'on|off' | head -1)"
      if [ "$_pm_now" = "off" ]; then
        printf 'off\n' > /data/adb/asb/wifipm_restore 2>/dev/null
        iw dev wlan0 set power_save on >/dev/null 2>&1 || true
      fi
    fi
    # Foreground uclamp tier follows the screen, like the background tier already does.
    #
    # With the screen off there is no foreground app by definition - whatever is running
    # is background or system work. The tier nevertheless keeps its profile value (59 on
    # this device), so anything the scheduler places there may ask for 59% of peak while
    # nobody is looking.
    #
    # The FSM owns the background tier but has no field for foreground, so this is the
    # cheapest correct place: the tuner already knows the screen state and already writes
    # per-screen values. 35 keeps a real working floor - the empty-uclamp defect is not
    # repeated - and the profile value is restored the moment the screen comes back.
    _ucfg_node=/dev/cpuctl/foreground/cpu.uclamp.max
    if [ -w "$_ucfg_node" ]; then
      _ucfg_now="$(cat "$_ucfg_node" 2>/dev/null | cut -d. -f1 | tr -dc '0-9')"
      case "$_ucfg_now" in ''|*[!0-9]*) _ucfg_now=0 ;; esac
      if [ "$_ucfg_now" -gt 35 ] 2>/dev/null; then
        printf '%s\n' "$_ucfg_now" > /data/adb/asb/ucfg_restore 2>/dev/null
        writef "$_ucfg_node" 35
      fi
    fi
  else
    writef /proc/sys/vm/laptop_mode 0
    # Screen on: put Wi-Fi power save back only if we turned it on.
    #
    # The marker is written only when the mode was off beforehand, so a user who set it
    # on themselves is never flipped, and a missing file means we touched nothing.
    # "always" means keep it on with the screen up too, so skip the restore there.
  _wpm="$(_cfg wifi_powersave)"
  if [ "$_wpm" != "always" ] && [ -f /data/adb/asb/wifipm_restore ] && command -v iw >/dev/null 2>&1; then
      iw dev wlan0 set power_save off >/dev/null 2>&1 || true
      rm -f /data/adb/asb/wifipm_restore 2>/dev/null
    fi
    # Screen back on: restore the profile's foreground tier immediately.
    #
    # Without this the tier stays at 35 and the first app the user opens is throttled -
    # a saving that costs responsiveness is not a saving. The saved value is written by
    # the screen-off branch above; if the file is missing nothing is touched, so a
    # half-applied state can never leave the tier pinned.
    _ucfg_node=/dev/cpuctl/foreground/cpu.uclamp.max
    _ucfg_save="$(cat /data/adb/asb/ucfg_restore 2>/dev/null | tr -dc '0-9')"
    case "$_ucfg_save" in ''|*[!0-9]*) : ;; *)
      [ -w "$_ucfg_node" ] && writef "$_ucfg_node" "$_ucfg_save"
      rm -f /data/adb/asb/ucfg_restore 2>/dev/null ;;
    esac
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
# This used to write a flat 60/80/90 for every scenario, which overrode the profile outright:
# performance asks for 12 and got 60, balanced asks for 35 and got 90.
# The user's memory setting was meaningless in Smart Mode and the action screen reported a live
# value nobody had chosen - which is exactly what the field reports showed.
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

  # Screen off raises swappiness only when memory is actually tight.
  #
  # The old rule was unconditional: +20 whenever the screen went off. A capture shows
  # what that costs - zram grew by 3.2 GiB during DEEP_IDLE alone. Compressing three
  # gigabytes is CPU work done while the phone is supposed to be asleep, and every one
  # of those pages has to be decompressed again when the user picks the phone up.
  #
  # Swapping out background apps is worth it when something needs the RAM. With half the
  # memory free it is pure overhead: the pages are evicted, then faulted straight back.
  #
  # 25% free is the line: below it the device is genuinely under pressure and the old
  # behaviour is right; above it, keep the profile value and let the pages sit.
  _mt="$(grep -m1 MemTotal /proc/meminfo 2>/dev/null | tr -dc "0-9")"
  _ma="$(grep -m1 MemAvailable /proc/meminfo 2>/dev/null | tr -dc "0-9")"
  _freepct=100
  [ -n "$_mt" ] && [ "$_mt" -gt 0 ] 2>/dev/null && [ -n "$_ma" ] && \
    _freepct=$(( _ma * 100 / _mt ))
  # PSI, not free-memory share: it measures pressure instead of its aftermath.
#
# A field snapshot reads available=3883 of 15109 - 25%, right on the threshold - while
# memory PSI some/avg60 sits at 0.17, which is nothing. The two disagree because zram had
# already absorbed 6.3 GiB: the system evicted gigabytes, and "available" looks healthy
# BECAUSE of that work, not instead of it. Gating on the share therefore raises swappiness
# exactly when the swapping has already happened.
#
# PSI "some" is the fraction of time at least one task stalled waiting on memory. Above 5
# there is real contention worth swapping for; below it the pages would be faulted back.
# Free share stays as the fallback where PSI is absent.
_psi="$(sed -n 's/^some .*avg60=\([0-9.]*\).*/\1/p' /proc/pressure/memory 2>/dev/null | head -1)"
_psi_i="${_psi%%.*}"
case "$_psi_i" in ''|*[!0-9]*) _psi_i="" ;; esac
if [ "$SCREEN" = "0" ] && { [ -n "$_psi_i" ] && [ "$_psi_i" -ge 5 ] 2>/dev/null \
   || { [ -z "$_psi_i" ] && [ "$_freepct" -lt 25 ] 2>/dev/null; }; }; then
    _swp=$((_base + 20))
  elif [ "$SCREEN" = "0" ]; then
    _swp=$_base
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
