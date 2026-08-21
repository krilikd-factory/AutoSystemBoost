#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT_DIR/tools/asb_config_backup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"; STATE="$TMP/state"; EXPORT_ROOT="$TMP/external"
mkdir -p "$MOD/config" "$MOD/runtime" "$STATE"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"
cp "$ROOT_DIR/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
run() { MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_PROFILE_EXPORT_ROOT="$EXPORT_ROOT" sh "$HELPER" "$@"; }
need() { grep -Fqx "$2" "$1" >/dev/null || { echo "FAIL: missing [$2]" >&2; exit 1; }; }
KEYS='gnss_trim night_modem_idle doze_level wifi_country'

run create battery-test $KEYS >/dev/null
run list | grep -q '^battery-test|.*|ok$' || { echo 'FAIL: profile not listed as healthy' >&2; exit 1; }
[ -f "$STATE/config_profiles/battery-test.conf" ] || { echo 'FAIL: profile missing' >&2; exit 1; }
run preview battery-test $KEYS >/dev/null

# Restore must be one writer transaction and carry only the supplied user keys.
sed -i 's/^gnss_trim=.*/gnss_trim=1/' "$MOD/config/governor.conf"
run restore battery-test $KEYS >/dev/null
need "$MOD/config/governor.conf" 'gnss_trim=0'

# A user may choose only documented external destinations, never an arbitrary path. The export
# remains checksummed and can be brought back into the canonical profile store safely.
run export battery-test downloads >/dev/null
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.conf" ] || { echo 'FAIL: Downloads export missing' >&2; exit 1; }
run list-external downloads | grep -q '^battery-test|.*|ok$' || { echo 'FAIL: exported profile not listed healthy' >&2; exit 1; }
if run export battery-test ../../escape >/dev/null 2>&1; then echo 'FAIL: arbitrary export destination accepted' >&2; exit 1; fi
run delete battery-test >/dev/null
run import-external downloads battery-test >/dev/null
[ -f "$STATE/config_profiles/battery-test.conf" ] || { echo 'FAIL: exported profile did not re-import' >&2; exit 1; }

# Invalid names cannot escape the profile store and checksum corruption blocks restore.
if run create '../escape' $KEYS >/dev/null 2>&1; then echo 'FAIL: traversal profile name accepted' >&2; exit 1; fi
printf '%s\n' '# tamper' >> "$STATE/config_profiles/battery-test.conf"
if run restore battery-test $KEYS >/dev/null 2>&1; then echo 'FAIL: checksum mismatch accepted' >&2; exit 1; fi
run delete battery-test >/dev/null
[ ! -e "$STATE/config_profiles/battery-test.conf" ] || { echo 'FAIL: profile not deleted' >&2; exit 1; }

echo 'PASS named config profiles contract'
