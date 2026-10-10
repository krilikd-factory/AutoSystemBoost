#!/bin/sh
# Runtime (fix86): a screen-off LTE apply skipped for a call or tethering re-arms itself
# instead of leaving 5G on for the rest of the night (OP15: skip at 03:12, nothing until 11:10).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
fail=0; f() { echo "FAIL lte retry: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
echo net_screen_off_lte=1 > "$T/mod/config/governor.conf"
echo screen=0 > "$T/state"
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
cat "$WAKEF" 2>/dev/null
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st" \
       ASB_STATE_FILE="$T/state" CALLF="$T/call" WAKEF="$T/wake" ASB_LTE_RETRY_S=3601
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001
echo "$NR_ON" > "$MASK"
echo "mCallState=2" > "$T/call"
sh "$L" apply
[ "$(cat "$T/st/lte_screenoff.retry" 2>/dev/null)" = 1 ] || f "skip did not count a retry"
[ -s "$T/st/lte_screenoff.pid" ] || f "skip did not re-arm a timer"
grep -q 'will retry every 3601s' "$T/st/lte_screenoff.log" || f "first skip not logged"
sh "$L" apply
[ "$(grep -c 'skipped' "$T/st/lte_screenoff.log")" = 1 ] || f "every retry is logged"
sh "$L" restore
[ -f "$T/st/lte_screenoff.retry" ] && f "screen-on did not clear the retry counter"
[ -f "$T/st/lte_screenoff.pid" ] && f "screen-on did not disarm the retry timer"
# call over: the apply goes through
echo "mCallState=0" > "$T/call"
sh "$L" apply
[ -f "$T/st/lte_screenoff.saved" ] || f "apply after the call did not happen"
sleep 0.3
ps -eo pid=,args= 2>/dev/null | grep -q "[s]leep 3601" && f "disarm left the timer sleep running"
# a stale state file (screen=1) must not block the apply when the power manager says asleep
sh "$L" restore; echo "$NR_ON" > "$MASK"; echo screen=1 > "$T/state"
echo "mWakefulness=Awake" > "$T/wake"; sh "$L" apply
[ -f "$T/st/lte_screenoff.saved" ] && f "applied while the screen is really on"
echo "mWakefulness=Asleep" > "$T/wake"; sh "$L" apply
[ -f "$T/st/lte_screenoff.saved" ] || f "stale screen=1 in the state file blocked the apply"
rm -rf "$T"
[ "$fail" = 0 ] && echo "PASS lte screen-off retries a skipped apply"
exit "$fail"
