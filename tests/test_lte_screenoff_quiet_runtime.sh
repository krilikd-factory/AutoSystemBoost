#!/bin/sh
# Runtime (fix122): screen-off LTE switches only when mobile data is moving (an idle phone
# keeps 5G - nothing to save, and the restore at the unlock is a data stall); it settles
# and re-checks the power manager before switching, so a timer running out as the phone
# wakes cannot apply under the user's thumb; a switch the screen interrupted is given back;
# MediaTek's ccmni links are counted; a phone with no counters keeps the old behaviour.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
fail=0; f() { echo "FAIL lte quiet: $*" >&2; fail=1; }
cleanup() { [ -f "$T/st/lte_screenoff.pid" ] && kill "$(cat "$T/st/lte_screenoff.pid")" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/st" "$T/mod/config" "$T/net/rmnet_data3/statistics"
echo net_screen_off_lte=1 > "$T/mod/config/governor.conf"
echo screen=0 > "$T/state"
cat > "$T/bin/cmd" <<'S'
#!/bin/sh
case "$2" in
  get-allowed-network-types-for-users) cat "$MASK" ;;
  set-allowed-network-types-for-users) shift 2; [ "$1" = -s ] && shift 2; echo "$1" > "$MASK"
    [ -f "$WAKE_ON_SET" ] && echo "mWakefulness=Awake" > "$WAKEF" ;;
esac
S
printf '#!/bin/sh\necho 1\n' > "$T/bin/settings"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
echo "id=1 simSlotIndex=0"
echo "mCallState=0"
cat "$WAKEF" 2>/dev/null
S
printf '#!/bin/sh\ncat "$DSF" 2>/dev/null\n' > "$T/bin/getprop"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st" \
       ASB_STATE_FILE="$T/state" WAKEF="$T/wake" DSF="$T/ds" ASB_NET_SYS="$T/net" \
       WAKE_ON_SET="$T/wake_on_set" ASB_LTE_DELAY_S=1 ASB_LTE_SETTLE_S=0
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001; NR_OFF=1011111110000000001
SAVE="$T/st/lte_screenoff.saved"
rx() { echo "$1" > "$T/net/rmnet_data3/statistics/rx_bytes"; echo 0 > "$T/net/rmnet_data3/statistics/tx_bytes"; }
reset() { sh "$L" restore >/dev/null 2>&1; rm -f "$SAVE" "$T/st/lte_screenoff.quiet" "$WAKE_ON_SET"; echo "$NR_ON" > "$MASK"
          echo "mWakefulness=Asleep" > "$WAKEF"; echo 1 > "$T/ds"; echo screen=0 > "$T/state"; }

# 1. Idle in the pocket: windows pass, 5G stays, the timer keeps watching.
reset; rx 1000000
sh "$L" arm; sleep 2.6
[ -f "$SAVE" ] && f "applied with no mobile data moving"
[ "$(cat "$MASK")" = "$NR_ON" ] || f "mask changed on an idle phone"
[ "$(cat "$T/st/lte_screenoff.quiet" 2>/dev/null)" -ge 1 ] 2>/dev/null || f "quiet windows not counted"
[ -s "$T/st/lte_screenoff.pid" ] && kill -0 "$(cat "$T/st/lte_screenoff.pid")" 2>/dev/null || f "timer stopped watching after a quiet window"
sh "$L" status | grep -q '^quiet_windows=[1-9]' || f "status does not report quiet windows"
# ...then a stream starts (2 MiB in a 1 s window): the next window switches.
rx 3200000; sleep 1.6
[ -f "$SAVE" ] || f "a stream with the screen off did not switch to LTE"
[ "$(cat "$MASK")" = "$NR_OFF" ] || f "mask not LTE after the stream window: $(cat "$MASK")"

# 2. Screen on mid-wait: the timer goes, nothing is switched.
reset; rx 1000000
sh "$L" arm; sleep 0.3; sh "$L" screen_on; rx 9000000; sleep 1.5
[ -f "$SAVE" ] && f "applied after the screen came on"
[ -f "$T/st/lte_screenoff.pid" ] && f "screen_on did not disarm the timer"

# 3. The wake race: Android already reports the display ON while the governor file says off.
reset; echo 2 > "$T/ds"
sh "$L" apply
[ -f "$SAVE" ] && f "applied while Android's display state is ON"
# ...and the power manager Awake during the settle (display state not yet moved).
reset; ( sleep 0.4; echo "mWakefulness=Awake" > "$WAKEF" ) &
ASB_LTE_SETTLE_S=1 sh "$L" apply; wait
[ -f "$SAVE" ] && f "applied although the power manager turned Awake during the settle"
[ "$(cat "$MASK")" = "$NR_ON" ] || f "mask changed in the wake race"

# 4. The screen comes on during the switch itself: 5G is given straight back.
reset; true > "$WAKE_ON_SET"
sh "$L" apply
[ -f "$SAVE" ] && f "record left after an interrupted switch"
[ "$(cat "$MASK")" = "$NR_ON" ] || f "5G not given back after the screen came on during the switch"
grep -q 'the screen came on during the switch' "$T/st/lte_screenoff.log" || f "interrupted switch not logged"

# 5. MediaTek: ccmni counted.
reset; rm -rf "$T/net/rmnet_data3"; mkdir -p "$T/net/ccmni1/statistics"
echo 5242880 > "$T/net/ccmni1/statistics/rx_bytes"; echo 1048576 > "$T/net/ccmni1/statistics/tx_bytes"
sed '/^case "\$1" in$/,$d' "$L" > "$T/hdr.sh"
kib="$(sh -c '. "$1"; _rmnet_kib' x "$T/hdr.sh")"
[ "$kib" = 6144 ] || f "ccmni traffic not counted (got '$kib' KiB)"

# 6. No counters at all: the old behaviour - apply after one window.
reset; rm -rf "$T/net/ccmni1"
sh "$L" arm; sleep 1.6
[ -f "$SAVE" ] || f "a phone without mobile counters never switches any more"

[ "$fail" = 0 ] && echo "PASS lte screen-off: only with data moving, settle and re-check, interrupted switch undone, ccmni"
exit "$fail"
