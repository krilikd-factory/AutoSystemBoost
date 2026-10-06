#!/usr/bin/env bash
# Contract for runtime/asb_lte_screenoff.sh - the opt-in "LTE while screen off" tweak.
#
# It changes the modem's allowed network types, so the safety rules are the whole point
# and every one of them is pinned here against a fake `cmd phone`:
#   - off by default, and a no-op while the toggle is 0;
#   - acts only with the screen off and never during a call;
#   - removes exactly the NR bit and saves the original mask;
#   - restore puts back the saved mask exactly and drops the save file;
#   - a ROM that ignores the write is restored and marked unsupported, after which
#     nothing further is attempted.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/runtime/asb_lte_screenoff.sh"
fail() { echo "FAIL lte_screenoff contract: $*"; exit 1; }
[ -f "$S" ] || fail "script missing"

grep -q '^net_screen_off_lte=0$' "$ROOT/config/governor.conf.shipped" || fail "shipped default is not 0"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/mod/config" "$T/state" "$T/dev"
cat > "$T/bin/settings" <<'EOF'
#!/bin/sh
echo 1
EOF
cat > "$T/bin/dumpsys" <<EOF
#!/bin/sh
echo "mCallState=\$(cat $T/callstate 2>/dev/null || echo 0)"
EOF
cat > "$T/bin/cmd" <<EOF
#!/bin/sh
shift
case "\$1" in
  get-allowed-network-types-for-users)
    m=\$(cat $T/mask); out=""
    for p in "GPRS 1" "EDGE 2" "UMTS 4" "LTE 4096" "GSM 32768" "LTE_CA 262144" "NR 524288"; do
      n=\${p% *}; b=\${p#* }; [ \$(( m & b )) -ne 0 ] && out="\${out:+\$out|}\$n"
    done
    echo "\$out" ;;
  set-allowed-network-types-for-users)
    [ -f $T/ignore_writes ] && exit 0
    r="\$4"; v=0
    while [ -n "\$r" ]; do c="\${r%"\${r#?}"}"; r="\${r#?}"; v=\$(( v*2 + c )); done
    echo "\$v" > $T/mask ;;
esac
EOF
chmod +x "$T/bin/"*
sed "s|/data/adb/asb|$T/state|; s|/dev/.asb/state|$T/dev/state|" "$S" > "$T/run.sh"
export PATH="$T/bin:$PATH" MODDIR="$T/mod"
run() { sh "$T/run.sh" "$@" </dev/null >/dev/null 2>&1; }

ORIG=786439          # GPRS|EDGE|UMTS|LTE|GSM|LTE_CA|NR
echo "$ORIG" > "$T/mask"; echo "screen=0" > "$T/dev/state"

echo "net_screen_off_lte=0" > "$T/mod/config/governor.conf"
run apply; [ "$(cat "$T/mask")" = "$ORIG" ] || fail "acted with the toggle off"

echo "net_screen_off_lte=1" > "$T/mod/config/governor.conf"
echo "screen=1" > "$T/dev/state"
run apply; [ "$(cat "$T/mask")" = "$ORIG" ] || fail "acted with the screen on"

echo "screen=0" > "$T/dev/state"; echo 2 > "$T/callstate"
run apply; [ "$(cat "$T/mask")" = "$ORIG" ] || fail "acted during a call"
rm -f "$T/callstate"

run apply
[ "$(cat "$T/mask")" = "$(( ORIG & ~524288 ))" ] || fail "did not remove exactly the NR bit"
[ "$(cat "$T/state/lte_screenoff.saved")" = "1|$ORIG" ] || fail "original mask not saved"

run restore
[ "$(cat "$T/mask")" = "$ORIG" ] || fail "restore did not put the original back"
[ ! -e "$T/state/lte_screenoff.saved" ] || fail "save file left after a good restore"

: > "$T/ignore_writes"
run apply
[ "$(cat "$T/mask")" = "$ORIG" ] || fail "mask changed although the ROM ignored the write"
[ -e "$T/state/lte_screenoff.unsupported" ] || fail "ignored write did not mark unsupported"
rm -f "$T/ignore_writes"
run apply
[ "$(cat "$T/mask")" = "$ORIG" ] || fail "acted again after being marked unsupported"

grep -q 'asb_lte_screenoff.sh" restore' "$ROOT/uninstall.sh" || fail "uninstall does not restore"
grep -q 'lte_screenoff.saved' "$ROOT/service.sh" || fail "no boot-time restore"

# A call on the second SIM blocks it too. The registry prints one mCallState per phone and
# the first version only looked at the first line.
rm -f "$T/state/lte_screenoff.unsupported"
cat > "$T/bin/dumpsys" <<'EOF2'
#!/bin/sh
echo "mCallState=0"
echo "mCallState=2"
EOF2
chmod +x "$T/bin/dumpsys"
run apply; [ "$(cat "$T/mask")" = "$ORIG" ] || fail "acted during a call on SIM 2"

# The uninstaller must restore before it deletes /data/adb/asb - the saved mask lives
# there - and must defer the restore when telephony is not up yet.
U="$ROOT/uninstall.sh"
_l_rest="$(grep -n 'asb_lte_screenoff.sh" restore' "$U" | head -1 | cut -d: -f1)"
_l_rm="$(grep -n '^rm -rf /data/adb/asb 2>/dev/null' "$U" | head -1 | cut -d: -f1)"
[ -n "$_l_rest" ] && [ -n "$_l_rm" ] && [ "$_l_rest" -lt "$_l_rm" ] \
  || fail "uninstall restores 5G after removing the saved mask"
grep -q 'ASB_LTE_STATE_DIR=' "$U" || fail "uninstall has no deferred restore"
grep -q 'STATE_DIR="${ASB_LTE_STATE_DIR:-/data/adb/asb}"' "$S" || fail "state dir not overridable"

echo "PASS lte_screenoff contract"
