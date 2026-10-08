#!/bin/sh
# Contract + fixture: asbdiag names other enabled modules that set properties ASB manages,
# with the differing values (AIST v2.1 shares 141 keys with ASB, 16 at other values).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/tools/asb_diag.sh"
fail=0; f() { echo "FAIL module overlap: $*" >&2; fail=1; }
grep -q 'SEC "0a0. MODULE OVERLAP' "$D" || f "section missing"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || f "system/bin/asbdiag out of sync"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '# c\nk.same=1\nk.diff=true\nk.only=1\n' > "$T/asb"
printf 'k.same=1\nk.diff=false\nk.other=1\n# k.diff=x\n' > "$T/other"
awk_prog="$(sed -n "/_ov_rows=\"\$(awk -F= '/,/' \"\$_ov_asb\" \"\$_ov_m\/system.prop\" 2>\/dev\/null)\"/p" "$D" | sed "1s/.*awk -F= '//; \$s/' \"\\\$_ov_asb\".*//")"
[ -n "$awk_prog" ] || f "could not extract the overlap program"
out="$(awk -F= "$awk_prog" "$T/asb" "$T/other")"
printf '%s\n' "$out" | grep -qx 'k.diff|true|false' || f "differing key not reported: $out"
printf '%s\n' "$out" | grep -qx '#|2|1' || f "summary wrong: $out"
printf '%s\n' "$out" | grep -q 'k.same|' && f "equal key reported as different"
[ "$fail" = 0 ] && echo "PASS module overlap contract"
exit "$fail"
