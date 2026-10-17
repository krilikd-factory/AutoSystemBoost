#!/bin/sh
# Runtime (fix158): Deep Sleep on night - what Trimmed and the ticked apps do by day.
#
# A tester asked what the picker's labels mean and to check that Trimmed works. With Deep
# Sleep on night the trim runs inside the sleep window only, and outside it every trimmed app
# is given back - correct, but the picker said "trimming works" by day and showed an empty
# Trimmed with no reason. Worse, the same day path withdrew the exemptions ASB had given to
# ticked apps, so a ticked messenger Android did not exempt was exempt at night and dozed by
# day, against what the card promises. The REAL applier runs on a fake pm / deviceidle and a
# fake clock:
#   - in the window the exempt user apps are trimmed and a ticked app gets ASB's exemption;
#   - out of it the trimmed apps come back and the ticked app keeps its exemption;
#   - unticking by day withdraws ASB's exemption; trim off withdraws everything;
#   - `list` says whether the window is open and when it is, for the picker.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_doze_apply.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL doze night keep: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
cat > "$T/bin/pm" <<'S'
#!/bin/sh
printf 'package:%s\n' org.telegram.messenger com.example.vpn com.example.game
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = deviceidle ] && [ "$2" = whitelist ] || exit 0
case "${3:-}" in
  +*) p="${3#+}"; grep -qx "$p" "$WL" || echo "$p" >> "$WL"; exit 0 ;;
  -*) p="${3#-}"; grep -vx "$p" "$WL" > "$WL.n"; mv "$WL.n" "$WL"; exit 0 ;;
esac
while IFS= read -r p; do echo "user,$p,10001"; done < "$WL"
S
printf '#!/bin/sh\necho "$FAKE_HM"\n' > "$T/bin/date"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/settings"
chmod +x "$T/bin/"*
conf() { printf 'doze_level=%s\ndoze_trim_whitelist=%s\nnight_quiet_auto=0\nnight_quiet_hour_start=23\nnight_quiet_hour_end=6\n' "$1" "$2" > "$T/mod/config/governor.conf"; }
at() { PATH="$T/bin:$PATH" FAKE_HM="$1" WL="$T/wl" MODDIR="$T/mod" ASB_DOZE_STATE_DIR="$T/st" sh "$SRC" ${2:-} </dev/null 2>/dev/null; }
has() { grep -qx "$1" "$T/wl"; }
printf '%s\n' com.example.vpn com.example.game > "$T/wl"
printf '%s\n' org.telegram.messenger > "$T/st/doze_whitelist_keep"
conf night 1
at 02:30 > "$T/o1"
has org.telegram.messenger || f "night: the ticked app was not made exempt"
has com.example.game && f "night: an exempt user app was not trimmed"
grep -qx com.example.game "$T/st/doze_whitelist_removed" 2>/dev/null || f "night: the trim was not recorded"
at 02:40 list > "$T/l1"
grep -qx 'window=1' "$T/l1" || f "list at night: window not open"
grep -qx 'R com.example.game' "$T/l1" || f "list at night: Trimmed empty"
at 14:00 > "$T/o2"
has com.example.game || f "day: a trimmed app was not given back"
has com.example.vpn || f "day: a trimmed app was not given back"
has org.telegram.messenger || f "day: the ticked app lost the exemption ASB gave it"
grep -qx org.telegram.messenger "$T/st/doze_whitelist_added" 2>/dev/null || f "day: ASB's grant record lost"
[ -s "$T/st/doze_whitelist_removed" ] && f "day: trimmed apps still recorded"
grep -q 'ticked apps keep their exemption' "$T/o2" || f "day: no line says the ticked apps keep their exemption"
at 14:10 list > "$T/l2"
grep -qx 'trim=1' "$T/l2" || f "list by day: trim switch state lost"
grep -qx 'window=0' "$T/l2" || f "list by day: window reported open"
grep -qx 'night=23:00-06:00' "$T/l2" || f "list by day: no sleep window"
grep -q '^R ' "$T/l2" && f "list by day: Trimmed not empty"
grep -qx 'G org.telegram.messenger' "$T/l2" || f "list by day: ASB's grant missing"
at 23:30 >/dev/null
has com.example.game && f "next night: not trimmed again"
has org.telegram.messenger || f "next night: the ticked app lost its exemption"
at 12:00 >/dev/null
: > "$T/st/doze_whitelist_keep"
at 12:30 >/dev/null
has org.telegram.messenger && f "unticked by day: ASB's exemption not withdrawn"
grep -qx org.telegram.messenger "$T/st/doze_whitelist_added" 2>/dev/null && f "unticked by day: grant still recorded"
has com.example.game || f "unticked by day: an app Android exempted was touched"
printf '%s\n' org.telegram.messenger > "$T/st/doze_whitelist_keep"
at 13:00 >/dev/null
has org.telegram.messenger || f "ticked by day: not made exempt"
conf night 0
at 13:30 >/dev/null
has org.telegram.messenger && f "trim off: ASB's exemption kept"
[ -e "$T/st/doze_whitelist_added" ] && f "trim off: grant record left behind"
conf aggressive 1
at 14:00 list > "$T/l3"
grep -q '^window=' "$T/l3" && f "aggressive: a sleep window reported"
grep -qx 'trim=1' "$T/l3" || f "aggressive: trim not reported"
[ "$fail" = 0 ] && echo "PASS doze night keep: trimmed apps back by day, ticked apps exempt day and night, the picker told when the window opens"
exit "$fail"
