#!/bin/sh
# Runtime (fix114): "5G only when needed" with the screen on. Light mobile traffic drops the
# NR leg after LIGHT_LOW_TICKS windows; a heavy window gives it back and holds it; Wi-Fi,
# a game and a call leave 5G alone; screen-on keeps a light record but gives back a
# screen-off one; the toggle off or screen-off without the screen-off mode give it back.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
fail=0; f() { echo "FAIL lte light: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config" "$T/net/rmnet_data2/statistics" "$T/net/rmnet_data3/statistics"
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
cat "$CALLF" 2>/dev/null
echo "mWakefulness=Awake"
S
cat > "$T/bin/ip" <<'S'
#!/bin/sh
case "$*" in
  "route show table all") cat "$TABLESF" 2>/dev/null ;;
  *) echo "1.1.1.1 via 10.0.0.1 dev $(cat "$ROUTEF") src 10.0.0.2 uid 0" ;;
esac
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st" \
       ASB_STATE_FILE="$T/state" CALLF="$T/call" ROUTEF="$T/route" ASB_NET_SYS="$T/net" TABLESF="$T/tables" \
       ASB_LTE_LIGHT_LOW_TICKS=3
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001; NR_OFF=1011111110000000001   # binary, as cmd prints it; bit 19 (524288) is NR
NR_ON_DEC=916481                                          # the record keeps it in decimal
SAVE="$T/st/lte_screenoff.saved"
cfg() { printf 'net_screen_off_lte=%s\nnet_lte_light=%s\n' "$1" "$2" > "$T/mod/config/governor.conf"; }
fresh() { rm -f "$SAVE" "$T/st/lte_light.hold"; echo "$NR_ON" > "$MASK"; }
# Everything above the dispatcher, so _light_tick can be driven without the sleeping loop.
sed '/^case "\$1" in$/,$d' "$L" > "$T/hdr.sh"
ticks() { sh -c '. "$1/hdr.sh"; shift; _lowN=0; for k in "$@"; do _light_tick "$k"; done' _ "$T" "$@"; }
mask() { cat "$MASK"; }
cfg 1 1; echo rmnet_data2 > "$ROUTEF"; echo mCallState=0 > "$T/call"
printf 'screen=1\nsmart_app_hint=2\n' > "$T/state"
fresh

ticks 800 900
[ "$(mask)" = "$NR_ON" ] || f "dropped 5G before LOW_TICKS light windows"
ticks 800 900 700
[ "$(mask)" = "$NR_OFF" ] || f "three light windows did not drop the NR leg (mask $(mask))"
[ "$(cut -d'|' -f3 "$SAVE" 2>/dev/null)" = light ] || f "record does not say light: $(cat "$SAVE" 2>/dev/null)"
ticks 800 5000 800 700
[ "$(mask)" = "$NR_OFF" ] || f "a medium window (between the marks) gave 5G back"
sh "$L" screen_on; sh "$L" arm >/dev/null 2>&1
[ "$(mask)" = "$NR_OFF" ] || f "screen_on / screen-off with both modes on gave a light record back"

# Heavy window: 5G back at once and held.
ticks 20000
[ "$(mask)" = "$NR_ON" ] || f "a heavy window did not give 5G back"
[ -f "$SAVE" ] && f "record kept after the heavy-window restore"
[ -s "$T/st/lte_light.hold" ] || f "no hold after a heavy window"
ticks 100 100 100
[ "$(mask)" = "$NR_ON" ] || f "re-applied inside the hold"
rm -f "$T/st/lte_light.hold"

# A game in front, a call: no apply.
printf 'screen=1\nsmart_app_hint=4\n' > "$T/state"; ticks 100 100 100
[ "$(mask)" = "$NR_ON" ] || f "applied with a game in front"
printf 'screen=1\nsmart_app_hint=2\n' > "$T/state"
echo "mCallState=2" > "$T/call"; ticks 100 100 100
[ "$(mask)" = "$NR_ON" ] || f "applied during a call"
echo "mCallState=0" > "$T/call"

# A screen-off record is not the watcher's: never re-tagged, given back on screen-on.
printf '0|%s|off\n' "$NR_ON_DEC" > "$SAVE"; echo "$NR_OFF" > "$MASK"
ticks 30000 30000
[ "$(mask)" = "$NR_OFF" ] || f "the watcher touched a screen-off record"
sh "$L" screen_on; sh "$L" arm >/dev/null 2>&1; sh "$L" restore >/dev/null 2>&1
[ "$(mask)" = "$NR_ON" ] || f "screen_on did not give back a screen-off record"

# Old two-field records are screen-off ones.
printf '0|%s\n' "$NR_ON_DEC" > "$SAVE"; echo "$NR_OFF" > "$MASK"
[ "$(sh -c '. "$1/hdr.sh"; _saved_reason' _ "$T")" = off ] || f "two-field record not read as screen-off"
sh "$L" screen_on; sh "$L" restore >/dev/null 2>&1
[ "$(mask)" = "$NR_ON" ] || f "two-field record not given back on screen_on"

# Toggle off: screen_on gives a light record back.
fresh; ticks 100 100 100; cfg 1 0
sh "$L" screen_on
[ "$(mask)" = "$NR_ON" ] || f "light record kept with the toggle off"
# Screen off without the screen-off mode: a light record is given back.
cfg 0 1; fresh; ticks 100 100 100
[ "$(mask)" = "$NR_OFF" ] || f "light mode needs the screen-off mode to work"
sh "$L" arm >/dev/null 2>&1
[ "$(mask)" = "$NR_ON" ] || f "light record kept at screen-off with the screen-off mode off"
grep -q 'bad save' "$T/st/lte_screenoff.log" 2>/dev/null && f "a 3-field record was read as corrupt"

# Status shows the reason.
fresh; cfg 1 1; ticks 100 100 100
sh "$L" status | grep -qx 'reason=light' || f "status has no reason=light"
sh "$L" restore >/dev/null 2>&1

# Routes: Wi-Fi is not mobile; rmnet and a VPN over rmnet are.
on_mobile() { sh -c '. "$1/hdr.sh"; _on_mobile' _ "$T"; }
echo wlan0 > "$ROUTEF"; on_mobile && f "Wi-Fi route read as mobile"
echo rmnet_data3 > "$ROUTEF"; on_mobile || f "rmnet route not read as mobile"
# fix119: 464XLAT and VPNs. Android keeps defaults per network table; the main table has none.
echo v4-rmnet_data2 > "$ROUTEF"; on_mobile || f "CLAT (v4-rmnet) route not read as mobile"
echo tun0 > "$ROUTEF"
printf 'default via 10.0.0.1 dev rmnet_data2 table rmnet_data2 proto static\ndefault dev tun0 table tun0 proto static\n' > "$T/tables"
on_mobile || f "VPN over mobile data not read as mobile"
printf 'default via 192.168.1.1 dev wlan0 table wlan0 proto static\ndefault via 10.0.0.1 dev rmnet_data2 table rmnet_data2 proto static\ndefault dev tun0 table tun0 proto static\n' > "$T/tables"
on_mobile && f "VPN over Wi-Fi (mobile kept up for handover) read as mobile"
printf 'default via 192.168.1.1 dev wlan0 table wlan0 proto static\n' > "$T/tables"
on_mobile && f "VPN over Wi-Fi read as mobile"
: > "$T/tables"; on_mobile && f "VPN with no default anywhere read as mobile"

# Counters: summed over every rmnet_data*, safe past 2^31 (mksh is 32-bit).
echo 3000000000 > "$T/net/rmnet_data2/statistics/rx_bytes"; echo 1024 > "$T/net/rmnet_data2/statistics/tx_bytes"
echo 2048 > "$T/net/rmnet_data3/statistics/rx_bytes"; echo 0 > "$T/net/rmnet_data3/statistics/tx_bytes"
k="$(sh -c '. "$1/hdr.sh"; _rmnet_kib' _ "$T")"
[ "$k" = 2929690 ] || f "rmnet KiB with a >2^31 counter: $k (want 2929690)"

# The watcher itself: starts once on screen_on, stops on arm.
cfg 1 1; export ASB_LTE_LIGHT_TICK_S=30
sh "$L" screen_on; p1="$(cat "$T/st/lte_light.pid" 2>/dev/null)"
sh "$L" screen_on; p2="$(cat "$T/st/lte_light.pid" 2>/dev/null)"
[ -n "$p1" ] && [ "$p1" = "$p2" ] || f "screen_on started a second watcher ($p1 / $p2)"
sh "$L" arm >/dev/null 2>&1
[ -f "$T/st/lte_light.pid" ] && f "screen-off did not stop the watcher"
sleep 0.2
# A zombie still answers kill -0 where nothing reaps orphans (some CI inits): check the state.
if [ -n "$p1" ] && [ -d "/proc/$p1" ]; then
  case "$(awk '{print $3}' "/proc/$p1/stat" 2>/dev/null)" in
    Z|X|'') : ;;
    *) f "watcher still alive after arm"; kill "$p1" 2>/dev/null ;;
  esac
fi
sh "$L" restore >/dev/null 2>&1

# End to end with a 1 s window: idle counters drop 5G, a burst (~80 Mbit/s) gives it back.
export ASB_LTE_LIGHT_TICK_S=1 ASB_LTE_LIGHT_LOW_TICKS=2
fresh; echo rmnet_data2 > "$ROUTEF"
sh "$L" screen_on
i=0; while [ "$i" -lt 40 ] && [ "$(mask)" != "$NR_OFF" ]; do sleep 0.2; i=$((i + 1)); done
[ "$(mask)" = "$NR_OFF" ] || f "the watcher did not drop 5G on an idle link"
(
  b=3000000000
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    b=$((b + 10000000)); echo "$b" > "$T/net/rmnet_data2/statistics/rx_bytes"; sleep 0.2
  done
) &
i=0; while [ "$i" -lt 30 ] && [ "$(mask)" != "$NR_ON" ]; do sleep 0.2; i=$((i + 1)); done
wait
[ "$(mask)" = "$NR_ON" ] || f "the watcher did not give 5G back on a burst"
grep -q 'light: .* 5G back' "$T/st/lte_screenoff.log" 2>/dev/null || f "burst restore not logged"
sh "$L" restore >/dev/null 2>&1
rm -rf "$T"
[ "$fail" = 0 ] && echo "PASS lte light-traffic mode (5G only when needed)"
exit "$fail"
