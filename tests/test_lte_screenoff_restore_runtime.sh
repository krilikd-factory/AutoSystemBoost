#!/bin/sh
# Runtime: screen-off LTE always gives 5G back. A good record restores the exact mask; an
# unreadable one still returns the NR bit; a phone whose earlier restore dropped its record
# gets 5G back once.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL lte restore: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
echo net_screen_off_lte=1 > "$T/mod/config/governor.conf"
cat > "$T/bin/cmd" <<'S'
#!/bin/sh
case "$2" in
  get-allowed-network-types-for-users) cat "$MASK" ;;
  set-allowed-network-types-for-users) shift 2; [ "$1" = -s ] && shift 2; echo "$1" > "$MASK" ;;
esac
S
printf '#!/bin/sh\necho 1\n' > "$T/bin/settings"
printf '#!/bin/sh\necho "id=1 simSlotIndex=0"\n' > "$T/bin/dumpsys"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st"
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001     # 916481
NR_OFF=01011111110000000001    # 392193

echo "$NR_OFF" > "$MASK"; printf '0|916481\n' > "$T/st/lte_screenoff.saved"
sh "$L" restore
[ "$(cat "$MASK")" = "$NR_ON" ] || f "good record not restored: $(cat "$MASK")"
[ -f "$T/st/lte_screenoff.saved" ] && f "record kept after restore"

echo "$NR_OFF" > "$MASK"; printf 'garbage\n' > "$T/st/lte_screenoff.saved"
sh "$L" restore
[ "$(cat "$MASK")" = "$NR_ON" ] || f "unreadable record: NR not given back ($(cat "$MASK"))"

rm -f "$T/st/"*; echo "$NR_OFF" > "$MASK"
echo "10-08 01:07:30 restore: bad save file dropped" > "$T/st/lte_screenoff.log"
sh "$L" restore
[ "$(cat "$MASK")" = "$NR_ON" ] || f "dropped-record repair did not give 5G back"
echo "$NR_OFF" > "$MASK"; sh "$L" restore
[ "$(cat "$MASK")" = "$NR_OFF" ] || f "repair ran twice (a later user choice must stand)"
[ "$fail" = 0 ] && echo "PASS lte screen-off restore runtime"
exit "$fail"
