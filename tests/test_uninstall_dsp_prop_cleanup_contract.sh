#!/bin/sh
# Contract: uninstalling the module removes its own persistent properties and nothing else.
#
# A field report on V64 found persist.vendor.asb.dsp.* surviving uninstall under
# /data/property, because asb_audio_apply.sh writes them with its own resetprop helpers
# that bypass asb_persist_safe - so baseline.txt never saw them and nothing deleted them.
# The fix deletes the persist.asb.* / persist.vendor.asb.* namespaces wholesale.
#
# This test extracts the sed selector straight from uninstall.sh (not a copy of it) and
# runs it against a representative getprop dump, so the test fails the moment the
# selector in the script stops matching the namespace - or starts matching anything wider.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UNINSTALL="$ROOT/uninstall.sh"
fail() { echo "FAIL uninstall dsp cleanup: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }

[ -f "$UNINSTALL" ] || fail "uninstall.sh not found"

# The cleanup must exist, delete persistently (-p --delete, not just the in-memory value),
# and run while resetprop is still available.
need "$UNINSTALL" 'resetprop -p --delete'
need "$UNINSTALL" 'persist\.\(vendor\.\)'
need "$UNINSTALL" 'command -v resetprop'

# Pull the real selector line out of the script.
SED_LINE="$(grep -F 'sed -n' "$UNINSTALL" | grep -F 'persist' | head -1)"
[ -n "$SED_LINE" ] || fail "namespace selector sed line not found in uninstall.sh"
SED_EXPR="$(printf '%s\n' "$SED_LINE" | sed -n "s/.*sed -n '\([^']*\)'.*/\1/p")"
[ -n "$SED_EXPR" ] || fail "could not extract sed expression from: $SED_LINE"

# Representative getprop dump: both ASB namespaces, plus neighbours that must survive.
#  - persist.vendor.audio.*   : vendor audio props, restored via baseline, not ours to delete
#  - persist.asbd.evil        : a prop that merely starts with the same letters
#  - persist.sys.oplus.*      : OEM props handled by their own stale-prop list
DUMP='
[persist.asb.dsp.enable]: [1]
[persist.asb.dsp.route]: [bt]
[persist.asb.force_disableabsvol]: [1]
[persist.vendor.asb.dsp.gain_mb]: [2500]
[persist.vendor.asb.dsp.bass_db]: [4]
[persist.vendor.asb.dsp.comp_ratio_x10]: [60]
[persist.vendor.asb.dsp.ceiling_mb]: [1800]
[persist.vendor.audio.hifi]: [true]
[persist.vendor.audio.fluence.voicecall]: [true]
[persist.asbd.evil]: [1]
[persist.sys.oplus.athena.reclaim_enable]: [1]
[ro.build.fingerprint]: [x]
'
MATCHED="$(printf '%s\n' "$DUMP" | sed -n "$SED_EXPR")"

for _p in persist.asb.dsp.enable persist.asb.dsp.route persist.asb.force_disableabsvol \
          persist.vendor.asb.dsp.gain_mb persist.vendor.asb.dsp.bass_db \
          persist.vendor.asb.dsp.comp_ratio_x10 persist.vendor.asb.dsp.ceiling_mb; do
  printf '%s\n' "$MATCHED" | grep -Fqx "$_p" || fail "selector misses ASB prop: $_p"
done
for _p in persist.vendor.audio.hifi persist.vendor.audio.fluence.voicecall \
          persist.asbd.evil persist.sys.oplus.athena.reclaim_enable; do
  printf '%s\n' "$MATCHED" | grep -Fq "$_p" && fail "selector wrongly catches foreign prop: $_p"
done

# Every selected name must carry the asb. marker after the optional vendor. segment -
# belt-and-braces against a future edit widening the pattern.
printf '%s\n' "$MATCHED" | while IFS= read -r _m; do
  [ -n "$_m" ] || continue
  case "$_m" in
    persist.asb.*|persist.vendor.asb.*) ;;
    *) echo "FAIL uninstall dsp cleanup: matched non-ASB prop: $_m" >&2; exit 1 ;;
  esac
done

echo "PASS uninstall dsp cleanup contract"
