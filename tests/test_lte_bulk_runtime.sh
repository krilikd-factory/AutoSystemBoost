#!/bin/sh
# Runtime (fix131): a download is not light traffic. Field OP15 (25429): with "5G only when
# needed" the phone sat on LTE for 20-90 minutes at a time with the screen on, through a
# 17-minute download at 2-7 Mbit/s - the give-back wanted one window over 12 Mbit/s, which an
# LTE cell near its own limit never shows - and the screen-off mode switched to LTE in the
# middle of a 5-9 Mbit/s download. Checked here with the REAL script:
#   light mode: drop only under 2 Mbit/s; two windows in a row at 3 Mbit/s give 5G back;
#               one busy window alone does not; the LTE-held tick is 10 s;
#   screen off: a transfer window keeps 5G; a stream still switches; a transfer starting
#               on LTE gives 5G back and holds it; a light record kept at screen-off is
#               watched the same way.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
fail=0; f() { echo "FAIL lte bulk: $*" >&2; fail=1; }
cleanup() { for p in "$T/st/lte_screenoff.pid" "$T/st/lte_light.pid"; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/st" "$T/mod/config" "$T/net/rmnet_data2/statistics"
cat > "$T/bin/cmd" <<'S'
#!/bin/sh
case "$2" in
  get-allowed-network-types-for-users) cat "$MASK" ;;
  set-allowed-network-types-for-users) shift 2; [ "$1" = -s ] && shift 2; echo "$1" > "$MASK" ;;
esac
S
printf '#!/bin/sh\necho 1\n' > "$T/bin/settings"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
echo "id=1 simSlotIndex=0"
echo "mCallState=0"
cat "$WAKEF" 2>/dev/null
S
cat > "$T/bin/ip" <<'S'
#!/bin/sh
echo "1.1.1.1 via 10.0.0.1 dev rmnet_data2 src 10.0.0.2 uid 0"
S
printf '#!/bin/sh\necho 1\n' > "$T/bin/getprop"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st" \
       ASB_STATE_FILE="$T/state" WAKEF="$T/wake" ASB_NET_SYS="$T/net" ASB_LTE_SETTLE_S=0
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001; NR_OFF=1011111110000000001; NR_ON_DEC=916481
SAVE="$T/st/lte_screenoff.saved"
mask() { cat "$MASK"; }
cfg() { printf 'net_screen_off_lte=%s\nnet_lte_light=%s\n' "$1" "$2" > "$T/mod/config/governor.conf"; }
rx() { echo "$1" > "$T/net/rmnet_data2/statistics/rx_bytes"; echo 0 > "$T/net/rmnet_data2/statistics/tx_bytes"; }
sed '/^case "\$1" in$/,$d' "$L" > "$T/hdr.sh"
ticks() { sh -c '. "$1/hdr.sh"; shift; _lowN=0; _busyN=0; for k in "$@"; do _light_tick "$k"; done' _ "$T" "$@"; }
fresh() { sh "$L" restore >/dev/null 2>&1; rm -f "$SAVE" "$T/st/lte_light.hold" "$T/st/lte_screenoff.log"; echo "$NR_ON" > "$MASK"; }

# ---- light mode (screen on) ------------------------------------------------------------
cfg 0 1; printf 'screen=1\nsmart_app_hint=2\n' > "$T/state"; echo "mWakefulness=Awake" > "$WAKEF"
export ASB_LTE_LIGHT_LOW_TICKS=3
fresh; ticks 2500 2500 2500
[ "$(mask)" = "$NR_ON" ] || f "dropped 5G at 2.5 Mbit/s (the drop mark is 2 Mbit/s now)"
ticks 1500 1500 1500
[ "$(mask)" = "$NR_OFF" ] || f "three windows under 2 Mbit/s did not drop to LTE"
ticks 3500 800 3500 900
[ "$(mask)" = "$NR_OFF" ] || f "single busy windows (not in a row) gave 5G back"
ticks 3500 3500
[ "$(mask)" = "$NR_ON" ] || f "two busy windows in a row (a download held on LTE) did not give 5G back"
grep -q 'light: 3500 kbit/s sustained over 2 windows - 5G back' "$T/st/lte_screenoff.log" || f "sustained give-back not logged"
[ -s "$T/st/lte_light.hold" ] || f "no hold after the sustained give-back"
ltk="$(sh -c '. "$1/hdr.sh"; echo "$LIGHT_TICK_LTE_S"' _ "$T")"
[ "$ltk" = 10 ] || f "LTE-held tick is $ltk s, want 10"
ltk="$(ASB_LTE_LIGHT_TICK_S=1 sh -c '. "$1/hdr.sh"; echo "$LIGHT_TICK_LTE_S"' _ "$T")"
[ "$ltk" = 1 ] || f "LTE-held tick longer than the normal tick ($ltk)"

# ---- screen off ------------------------------------------------------------------------
# 1 s windows: stream mark 16 KiB/s (~128 kbit/s), transfer mark 3000 kbit/s (~375 KiB/s).
export ASB_LTE_DELAY_S=1 ASB_LTE_OFF_MIN_KIB=16 ASB_LTE_OFF_BULK_HOLD_S=2
cfg 1 0; echo screen=0 > "$T/state"; echo "mWakefulness=Asleep" > "$WAKEF"
fresh; b=1000000; rx $b
sh "$L" arm
# A transfer: ~8 Mbit/s for three windows - 5G stays.
i=0; while [ "$i" -lt 16 ] && ! grep -q 'is a transfer' "$T/st/lte_screenoff.log" 2>/dev/null; do
  b=$((b + 500000)); rx $b; sleep 0.5; i=$((i + 1)); done
for _ in 1 2 3 4; do b=$((b + 500000)); rx $b; sleep 0.5; done
[ -f "$SAVE" ] && f "switched to LTE in the middle of a transfer"
grep -q 'is a transfer - 5G kept' "$T/st/lte_screenoff.log" || f "kept-for-transfer not logged"
[ "$(grep -c 'is a transfer' "$T/st/lte_screenoff.log")" = 1 ] || f "transfer note logged more than once per screen-off"
# The transfer ends, a stream goes on (~100 KiB/s): LTE.
i=0; while [ "$i" -lt 12 ] && [ ! -f "$SAVE" ]; do b=$((b + 50000)); rx $b; sleep 0.5; i=$((i + 1)); done
[ -f "$SAVE" ] || f "a stream after the transfer did not switch to LTE"
[ "$(mask)" = "$NR_OFF" ] || f "mask not LTE for the stream"
# A transfer starts on LTE: 5G back, then held.
i=0; while [ "$i" -lt 12 ] && [ -f "$SAVE" ]; do b=$((b + 600000)); rx $b; sleep 0.5; i=$((i + 1)); done
[ -f "$SAVE" ] && f "a transfer on LTE did not give 5G back"
[ "$(mask)" = "$NR_ON" ] || f "mask not 5G after the transfer give-back"
grep -q 'bulk: .* kbit/s with the screen off - 5G back for at least 2s' "$T/st/lte_screenoff.log" || f "transfer give-back not logged"
# Inside the hold a stream does not switch back at once...
b=$((b + 50000)); rx $b; sleep 0.6
[ -f "$SAVE" ] && f "re-switched to LTE inside the hold"
# ...after it, it does.
i=0; while [ "$i" -lt 14 ] && [ ! -f "$SAVE" ]; do b=$((b + 50000)); rx $b; sleep 0.5; i=$((i + 1)); done
[ -f "$SAVE" ] || f "no LTE after the hold for a stream"
sh "$L" screen_on
[ -f "$T/st/lte_screenoff.pid" ] && f "screen_on left the screen-off watcher running"
[ "$(mask)" = "$NR_ON" ] || f "screen_on did not give a screen-off record back"

# A light record kept at screen-off (both modes on) is watched for transfers too.
cfg 1 1; fresh
printf '0|%s|light\n' "$NR_ON_DEC" > "$SAVE"; echo "$NR_OFF" > "$MASK"
b=5000000; rx $b
sh "$L" arm
[ -s "$T/st/lte_screenoff.pid" ] || f "no watcher over a light record kept at screen-off"
i=0; while [ "$i" -lt 12 ] && [ -f "$SAVE" ]; do b=$((b + 600000)); rx $b; sleep 0.5; i=$((i + 1)); done
[ -f "$SAVE" ] && f "a transfer over a kept light record did not give 5G back"
sh "$L" restore >/dev/null 2>&1

[ "$fail" = 0 ] && echo "PASS lte transfers keep 5G (light mode and screen off)"
exit "$fail"
