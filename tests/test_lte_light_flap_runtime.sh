#!/bin/sh
# Runtime (fix154): "5G only when needed" stops flapping while the phone is in active use.
#
# Two field days on an OP15 (fix150, fix153): after every 10-minute hold the watcher went
# back to LTE as soon as three quiet minutes had passed, and while feeds were being scrolled
# 5G came back 40 s, 50 s, 121 s, 162 s, 253 s, 304 s, 334 s later - a network-type switch
# each way, every 12-15 minutes, for an LTE stint that saved nothing. Now a give-back that
# ends an LTE stint shorter than 5 minutes doubles the next hold (600 -> 1200 -> 2400 s,
# no further); a stint that lasted brings the hold back to 600 s. The REAL _light_tick runs
# on a mocked `cmd phone`.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL lte light flap: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
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
echo "mWakefulness=Awake"
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st" \
       ASB_STATE_FILE="$T/state" ASB_LTE_LIGHT_LOW_TICKS=3
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001
SAVE="$T/st/lte_screenoff.saved"
printf 'net_screen_off_lte=1\nnet_lte_light=1\n' > "$T/mod/config/governor.conf"
printf 'screen=1\nsmart_app_hint=2\n' > "$T/state"
echo "$NR_ON" > "$MASK"
sed '/^case "\$1" in$/,$d' "$L" > "$T/hdr.sh"
ticks() { sh -c '. "$1/hdr.sh"; shift; _lowN=0; for k in "$@"; do _light_tick "$k"; done' _ "$T" "$@"; }
hold_left() { echo $(( $(cat "$T/st/lte_light.hold") - $(date +%s) )); }
stint() {   # seconds the LTE stint lasted before the heavy window
  rm -f "$T/st/lte_light.hold"
  ticks 100 100 100
  [ -f "$SAVE" ] || { f "light traffic did not choose LTE"; return; }
  echo $(( $(date +%s) - $1 )) > "$T/st/lte_screenoff.since"
  ticks 20000
  [ -f "$SAVE" ] && f "a heavy window did not give 5G back"
}
in_range() { [ "$1" -ge $(( $2 - 3 )) ] && [ "$1" -le "$2" ]; }
stint 40
in_range "$(hold_left)" 1200 || f "a 40 s stint did not double the hold: $(hold_left)"
grep -q '5G back for at least 1200s (LTE lasted 4[0-9]s)$' "$T/st/lte_screenoff.log" || f "log does not say why: $(tail -n 2 "$T/st/lte_screenoff.log")"
stint 100
in_range "$(hold_left)" 2400 || f "a second short stint did not double again: $(hold_left)"
stint 60
in_range "$(hold_left)" 2400 || f "the hold grew past its ceiling: $(hold_left)"
stint 900
in_range "$(hold_left)" 600 || f "a stint that lasted did not bring the hold back: $(hold_left)"
ticks 100 100 100
[ -f "$SAVE" ] && f "LTE chosen inside the hold"
[ "$fail" = 0 ] && echo "PASS lte light flap: a short LTE stint doubles the 5G hold up to 40 min, a long one resets it"
exit "$fail"
