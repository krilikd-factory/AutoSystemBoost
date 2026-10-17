#!/bin/sh
# Contract: gnss_trim restricts BOTH location ops in self-healing FOREGROUND mode,
# records per-op state, and every restore path (off-switch, hourly loop, uninstall)
# parses both the legacy pkg|mode and the current pkg|op|mode record shapes.
#
# Why: two field-visible defects.
#   1. Only COARSE_LOCATION was set with mode "ignore". GNSS drain is a FINE fix, and
#      "ignore" is sticky - it survives the process being promoted. The restore loop ran
#      only from the screen-off hourly cycle, so a navigation app opened after an
#      overnight trim had no location until the next screen-off pass (user report: fix
#      lost mid-drive, recovered at reboot).
#   2. uninstall replayed every record as COARSE_LOCATION regardless of the op.
# MODE_FOREGROUND denies cached processes and allows promoted ones automatically -
# Android flips it with the process state, so no restore timing can strand an app.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GNSS="$ROOT/runtime/asb_gnss_trim.sh"
UNINSTALL="$ROOT/uninstall.sh"
fail() { echo "FAIL gnss foreground contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in ${1#$ROOT/}"; }
absent() { grep -Fq "$2" "$1" && fail "forbidden [$2] in ${1#$ROOT/}" || true; }

[ -f "$GNSS" ] || fail "asb_gnss_trim.sh not found"

# The trim loop covers both ops and uses the self-healing mode.
need "$GNSS" 'for _lop in COARSE_LOCATION FINE_LOCATION; do'
need "$GNSS" 'appops set "$_p" "$_lop" foreground'
absent "$GNSS" 'appops set "$_p" COARSE_LOCATION ignore'

# An app already on ignore/deny/foreground asked for it itself: never rewritten.
need "$GNSS" 'case "$_prev" in ignore|deny|foreground) continue ;; esac'

# State records are per-op: pkg|op|mode.
need "$GNSS" 'printf '"'"'%s|%s|%s\n'"'"' "$_p" "$_lop" "$_prev"'

# Both restore loops in the trim script parse the pipe-bearing record shape and
# sanitise the op name.
[ "$(grep -cF '*"|"*) _rop=' "$GNSS")" -ge 2 ] || fail "gnss restore loops do not parse pkg|op|mode"
[ "$(grep -cF 'COARSE_LOCATION|FINE_LOCATION' "$GNSS")" -ge 2 ] || fail "op sanitiser missing in gnss restores"

# Navigator/safety exclusions must survive any refactor of this file.
need "$GNSS" '*navi*|*waze*|*yandex*'
need "$GNSS" '*emergency*|*sos*|*safety*'

# uninstall.sh restores per-op too, and the record guard admits the pipe character.
need "$UNINSTALL" 'case "$_rop" in COARSE_LOCATION|FINE_LOCATION) : ;; *) _rop="COARSE_LOCATION" ;; esac'
need "$UNINSTALL" 'appops set "$_rp" "$_rop" "$_rm"'
[ "$(grep -cF 'appops set "$_rp" "$_rop" "$_rm"' "$UNINSTALL")" -ge 2 ] \
  || fail "uninstall has two gnss restore blocks; both must be op-aware"

echo "PASS gnss foreground contract"
