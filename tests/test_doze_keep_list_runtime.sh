#!/bin/sh
# Runtime (fix152): the apps picked in the WebUI are kept out of Doze, for real and at once.
#
# Testers liked the trim ("the best tweak against night drain") and asked to choose the
# apps it must leave alone from the WebUI. The old list showed only apps Android still
# exempted, so an app ASB had already trimmed was not there to tick, and a ticked app that
# Android dozes changed nothing. The REAL applier runs on a fake pm / deviceidle whose
# exemption list persists between calls:
#   - a kept app ASB trimmed earlier is given back and no longer recorded as removed;
#   - a kept app Android dozes is made exempt and recorded as ASB's grant;
#   - unticking it withdraws only ASB's grant; trim off or stock withdraws all grants and
#     returns every trimmed app; protected and system apps are never touched;
#   - `list` reports apps, exemptions, records and the rules' protection for the picker;
#   - a hostile line in the keep file never reaches deviceidle.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_doze_apply.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL doze keep list: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
cat > "$T/bin/pm" <<'S'
#!/bin/sh
printf 'package:%s\n' org.telegram.messenger com.example.vpn com.example.game com.azure.authenticator com.example.trimmed
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = deviceidle ] || exit 0
[ "$2" = whitelist ] || exit 0
case "${3:-}" in
  +*) echo "$3" >> "$WL_LOG"; p="${3#+}"; grep -qx "$p" "$WL" || echo "$p" >> "$WL"; exit 0 ;;
  -*) echo "$3" >> "$WL_LOG"; p="${3#-}"; grep -vx "$p" "$WL" > "$WL.n"; mv "$WL.n" "$WL"; exit 0 ;;
esac
echo 'system-excidle,com.android.phone,1001'
while IFS= read -r p; do echo "user,$p,10$(printf '%s' "$p" | wc -c)"; done < "$WL"
S
cat > "$T/bin/settings" <<'S'
#!/bin/sh
exit 0
S
chmod +x "$T/bin/"*
printf '%s\n' com.example.vpn com.example.game com.azure.authenticator > "$T/wl"
printf '%s\n' com.example.trimmed > "$T/st/doze_whitelist_removed"
printf '%s\n' org.telegram.messenger com.example.trimmed com.example.vpn 'x;touch /tmp/pwn' > "$T/st/doze_whitelist_keep"
printf '%s' 'com.example.vpn' >> "$T/st/doze_whitelist_keep"
conf() { printf 'doze_level=%s\ndoze_trim_whitelist=%s\n' "$1" "$2" > "$T/mod/config/governor.conf"; }
apply() {
  : > "$T/wl.log"
  PATH="$T/bin:$PATH" WL="$T/wl" WL_LOG="$T/wl.log" MODDIR="$T/mod" ASB_DOZE_STATE_DIR="$T/st" \
    sh "$SRC" "$@" </dev/null 2>/dev/null
}
conf aggressive 1
apply > "$T/out"
grep -qx '+org.telegram.messenger' "$T/wl.log" || f "a kept app Android dozes was not made exempt"
grep -qx 'org.telegram.messenger' "$T/st/doze_whitelist_added" || f "ASB's grant was not recorded"
grep -qx '+com.example.trimmed' "$T/wl.log" || f "a kept app ASB had trimmed was not given back"
grep -qx 'com.example.trimmed' "$T/st/doze_whitelist_removed" && f "a returned app is still recorded as removed"
grep -qx 'com.example.trimmed' "$T/st/doze_whitelist_added" && f "an app given back was recorded as ASB's grant"
grep -qx -- '-com.example.game' "$T/wl.log" || f "an ordinary exempt app was not trimmed"
grep -q 'com.example.vpn' "$T/wl.log" && f "a kept app that was already exempt was touched"
grep -q 'authenticator' "$T/wl.log" && f "a protected app was touched"
grep -q 'com.android.phone' "$T/wl.log" && f "a system entry was touched"
grep -q 'pwn\|touch' "$T/wl.log" && f "a hostile keep-file line reached deviceidle"
[ -e /tmp/pwn ] && f "a hostile keep-file line ran"
grep -q 'org.telegram.messenger is kept - ASB made it exempt from Doze' "$T/out" || f "no line says the kept app was made exempt"
apply list > "$T/list"
grep -qx 'trim=1' "$T/list" || f "list: trim state missing"
grep -qx 'A com.azure.authenticator p' "$T/list" || f "list: rule protection not reported"
grep -qx 'A com.example.game -' "$T/list" || f "list: an ordinary app line wrong"
grep -qx 'E org.telegram.messenger' "$T/list" || f "list: current exemptions missing"
grep -qx 'R com.example.game' "$T/list" || f "list: trimmed apps missing"
grep -qx 'G org.telegram.messenger' "$T/list" || f "list: ASB grants missing"
grep -qx 'K com.example.vpn' "$T/list" || f "list: last keep line without a newline lost"
grep -q 'pwn' "$T/list" && f "list: hostile keep line passed through"
grep -q 'com.android.phone' "$T/list" && f "list: a system entry listed as a user app"
[ -s "$T/wl.log" ] && f "list changed the exemption list: $(tr '\n' ' ' < "$T/wl.log")"
printf '%s\n' com.example.trimmed com.example.vpn > "$T/st/doze_whitelist_keep"
apply >/dev/null
grep -qx -- '-org.telegram.messenger' "$T/wl.log" || f "unticking did not withdraw ASB's grant"
grep -qx 'org.telegram.messenger' "$T/st/doze_whitelist_added" && f "a withdrawn grant is still recorded"
grep -qx -- '-com.example.vpn' "$T/wl.log" && f "unticking another app withdrew the user's own exemption"
printf '%s\n' org.telegram.messenger com.example.trimmed com.example.vpn > "$T/st/doze_whitelist_keep"
apply >/dev/null
grep -qx 'org.telegram.messenger' "$T/st/doze_whitelist_added" || f "re-ticking did not grant again"
conf aggressive 0
apply >/dev/null
grep -qx -- '-org.telegram.messenger' "$T/wl.log" || f "trim off did not withdraw ASB's grant"
grep -qx '+com.example.game' "$T/wl.log" || f "trim off did not give back the trimmed app"
[ -e "$T/st/doze_whitelist_added" ] && f "grant record left behind with trim off"
grep -qx 'com.example.vpn' "$T/wl" || f "the user's own exemption lost with trim off"
grep -qx 'com.example.trimmed' "$T/wl" || f "an app returned earlier lost its exemption with trim off"
apply list > "$T/list.off"
grep -qx 'trim=0' "$T/list.off" || f "list: trim off not reported"
conf moderate 1
apply list > "$T/list.mod"
grep -qx 'trim=0' "$T/list.mod" || f "list: trim reported working with Deep Sleep at moderate"
U="$ROOT/uninstall.sh"
grep -q 'done < /data/adb/asb/doze_whitelist_added' "$U" || f "uninstall does not withdraw ASB's grants"
grep -q 'dumpsys deviceidle whitelist "-$_p"' "$U" || f "uninstall grant removal is not a withdrawal"
[ "$fail" = 0 ] && echo "PASS doze keep list: kept apps given back or made exempt at once, grants withdrawn on untick, off and uninstall"
exit "$fail"
