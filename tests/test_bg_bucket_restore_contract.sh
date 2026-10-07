#!/bin/sh
# Contract + runtime: standby buckets forced by background trimming are recorded and
# handed back, and uninstall does it too.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/service.sh"; U="$ROOT/uninstall.sh"
fail=0; f() { echo "FAIL bg buckets: $*" >&2; fail=1; }
blk="$(sed -n '/^asb_bg_trim_apply_buckets() {/,/^}/p' "$S")"
printf '%s\n' "$blk" | grep -q 'am set-standby-bucket' && f "apply_buckets forces a bucket without recording it"
grep -q '/data/adb/asb/bg_buckets_orig' "$U" || f "uninstall does not restore recorded buckets"
# Uninstall's fallback list must be the heavy list, or an old install keeps apps in rare.
heavy="$(sed -n '/^_BG_TRIM_HEAVY="/,/^"/p' "$S" | grep -E '^[a-z]' | sort | tr '\n' ' ')"
unl="$(sed -n '/for _bp in com.facebook.katana/,/; do/p' "$U" | tr -s ' \\\n' '\n' | sed 's/;$//' | grep -E '^com\.' | sort | tr '\n' ' ')"
[ "$heavy" = "$unl" ] || f "uninstall fallback list differs from _BG_TRIM_HEAVY: [$heavy] vs [$unl]"

# Runtime: extract the two helpers and drive them with a stub am.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/am" <<'A'
#!/bin/sh
case "$1" in
  get-standby-bucket) case "$2" in com.inst|com.daily) echo 10 ;; com.gone) echo "Error: no package" ;; *) echo 30 ;; esac ;;
  set-standby-bucket) echo "$2 $3" >> "$AMLOG" ;;
esac
A
chmod +x "$T/bin/am"
{ sed -n '/^ASB_BG_BUCKETS_ORIG=/p' "$S"; sed -n '/^asb_bg_bucket_set() {/,/^}/p;/^asb_bg_bucket_restore() {/,/^}/p;/^asb_bg_bucket_demote_idle() {/,/^}/p' "$S"; } \
  | sed "s#/data/adb/asb#$T/d#g" > "$T/h.sh"
cat >> "$T/h.sh" <<'E'
asb_bg_bucket_set com.inst rare
asb_bg_bucket_set com.inst rare
asb_bg_bucket_set com.gone rare
asb_bg_bucket_set com.msg active
asb_bg_bucket_demote_idle com.daily rare
asb_bg_bucket_demote_idle com.weekly rare
asb_bg_bucket_restore
E
AMLOG="$T/am.log" PATH="$T/bin:$PATH" bash "$T/h.sh"
grep -qx 'com.inst 10' "$T/am.log" || f "original bucket not restored"
grep -qx 'com.msg 30' "$T/am.log" || f "second app not restored"
grep -q 'com.gone' "$T/am.log" && f "uninstalled package touched"
[ "$(grep -c '^com.inst rare$' "$T/am.log")" = 2 ] || f "set not applied"
[ -f "$T/d/bg_buckets_orig" ] && f "record not cleared after restore"
grep -q '^com.daily ' "$T/am.log" && f "an app in daily use was demoted"
grep -qx 'com.weekly rare' "$T/am.log" || f "an app out of daily use was not demoted"
# Heavy apps go through the idle-only rule; aggressive without opt-in gets the periodic pass.
printf '%s\n' "$blk" | grep -q 'asb_bg_bucket_demote_idle "$_p" rare' || f "heavy apps bypass the idle-only rule"
sed -n '/allow_disruptive_bg_trim \]; then/,/return 0/p' "$S" | grep -q 'asb_bg_trim_periodic' || f "smart aggressive has no periodic pass"
[ "$fail" = 0 ] && echo "PASS bg bucket restore"
exit "$fail"
