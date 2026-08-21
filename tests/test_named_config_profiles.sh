#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT_DIR/tools/asb_config_backup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"; STATE="$TMP/state"; SMART="$TMP/smart"; EXPORT_ROOT="$TMP/external"
mkdir -p "$MOD/config" "$MOD/runtime" "$STATE" "$SMART"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"
cp "$ROOT_DIR/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
run() { MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_SMART_STATE="$SMART" ASB_SMART_RESTORE_SKIP_DAEMON=1 ASB_PROFILE_EXPORT_ROOT="$EXPORT_ROOT" sh "$HELPER" "$@"; }
need() { grep -Fqx "$2" "$1" >/dev/null || { echo "FAIL: missing [$2]" >&2; exit 1; }; }
KEYS='gnss_trim night_modem_idle doze_level wifi_country'
# Minimal non-empty learner artifacts: helper hashes and bounds them; native validates their
# own magic/version on next boot. A host test must not invent a device binary schema.
printf 'bucket-learning-fixture\n' > "$SMART/buckets.bin"
printf 'appheat-learning-fixture\n' > "$SMART/smart_appheat.bin"
printf 'sleep_min=1380\nwake_min=420\nsamples=12\n' > "$SMART/night_window.conf"

run create battery-test $KEYS >/dev/null
run list | grep -q '^battery-test|.*|ok|saved$' || { echo 'FAIL: profile not listed with saved Smart learning' >&2; exit 1; }
[ -f "$STATE/config_profiles/battery-test.conf" ] || { echo 'FAIL: profile missing' >&2; exit 1; }
[ -f "$STATE/config_profiles/battery-test.smart/manifest" ] || { echo 'FAIL: Smart learning manifest missing' >&2; exit 1; }
run preview battery-test $KEYS | grep -q 'Smart learning' || { echo 'FAIL: preview did not disclose Smart learning payload' >&2; exit 1; }

# Restore must be one writer transaction and carry only the supplied user keys.
sed -i 's/^gnss_trim=.*/gnss_trim=1/' "$MOD/config/governor.conf"
rm -f "$SMART/buckets.bin" "$SMART/smart_appheat.bin" "$SMART/night_window.conf"
run restore battery-test $KEYS | grep -q 'smart_learning=restored' || { echo 'FAIL: Smart learning did not restore' >&2; exit 1; }
need "$MOD/config/governor.conf" 'gnss_trim=0'
[ -s "$SMART/buckets.bin" ] && [ -s "$SMART/smart_appheat.bin" ] && [ -s "$SMART/night_window.conf" ] || { echo 'FAIL: restored learner files missing' >&2; exit 1; }

# A user may choose only documented external destinations, never an arbitrary path. The export
# remains checksummed and can be brought back into the canonical profile store safely.
run export battery-test downloads >/dev/null
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.conf" ] || { echo 'FAIL: Downloads export missing' >&2; exit 1; }
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.smart/manifest" ] || { echo 'FAIL: Downloads Smart learning copy missing' >&2; exit 1; }
run list-external downloads | grep -q '^battery-test|.*|ok|saved$' || { echo 'FAIL: exported profile not listed with Smart learning' >&2; exit 1; }
if run export battery-test ../../escape >/dev/null 2>&1; then echo 'FAIL: arbitrary export destination accepted' >&2; exit 1; fi
run delete battery-test >/dev/null
run import-external downloads battery-test >/dev/null
[ -f "$STATE/config_profiles/battery-test.conf" ] || { echo 'FAIL: exported profile did not re-import' >&2; exit 1; }
[ -f "$STATE/config_profiles/battery-test.smart/manifest" ] || { echo 'FAIL: exported Smart learning did not re-import' >&2; exit 1; }
# A corrupt sidecar is skipped, while the independently checksummed settings profile remains restorable.
printf 'tamper' >> "$STATE/config_profiles/battery-test.smart/buckets.bin"
rm -f "$SMART/buckets.bin"
run restore battery-test $KEYS | grep -q 'smart_learning=skipped_invalid' || { echo 'FAIL: corrupt Smart learning was not rejected' >&2; exit 1; }
[ ! -e "$SMART/buckets.bin" ] || { echo 'FAIL: corrupt Smart learning reached live state' >&2; exit 1; }

# Invalid names cannot escape the profile store and checksum corruption blocks restore.
if run create '../escape' $KEYS >/dev/null 2>&1; then echo 'FAIL: traversal profile name accepted' >&2; exit 1; fi
printf '%s\n' '# tamper' >> "$STATE/config_profiles/battery-test.conf"
if run restore battery-test $KEYS >/dev/null 2>&1; then echo 'FAIL: checksum mismatch accepted' >&2; exit 1; fi
run delete battery-test >/dev/null
[ ! -e "$STATE/config_profiles/battery-test.conf" ] || { echo 'FAIL: profile not deleted' >&2; exit 1; }

echo 'PASS named config profiles contract'
