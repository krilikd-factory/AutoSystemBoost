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
# Minimal non-empty artifacts: helper hashes and bounds bytes while native validates its own
# binary magic/version at boot. Six files make a clean-install restore operational, not merely
# a copy of the aggregate buckets.
printf 'bucket-learning-fixture\n' > "$SMART/buckets.bin"
printf 'bucket-fallback-fixture\n' > "$SMART/buckets.bin.bak"
printf 'appheat-learning-fixture\n' > "$SMART/smart_appheat.bin"
printf 'sleep_min=1380\nwake_min=420\nsamples=12\n' > "$SMART/night_window.conf"
printf '1\n' > "$SMART/smart_mode_enabled"
printf 'balanced\n' > "$SMART/smart_prev_profile"

_create_out="$(run create battery-test $KEYS)"
printf '%s\n' "$_create_out" | grep -q '^smart_learning=saved$' || { echo 'FAIL: Smart learning was not saved' >&2; exit 1; }
printf '%s\n' "$_create_out" | grep -q '^smart_learning_files=6$' || { echo 'FAIL: complete Smart payload count missing' >&2; exit 1; }
printf '%s\n' "$_create_out" | grep -q '^smart_learning_bytes=[1-9][0-9]*$' || { echo 'FAIL: Smart payload byte count missing' >&2; exit 1; }
run list | grep -q '^battery-test|.*|ok|saved$' || { echo 'FAIL: profile not listed with saved Smart learning' >&2; exit 1; }
[ -f "$STATE/config_profiles/battery-test.conf" ] || { echo 'FAIL: profile missing' >&2; exit 1; }
[ -f "$STATE/config_profiles/battery-test.smart/manifest" ] || { echo 'FAIL: Smart learning manifest missing' >&2; exit 1; }
grep -Fqx '# ASB_SMART_PROFILE_SCHEMA=2' "$STATE/config_profiles/battery-test.smart/manifest" || { echo 'FAIL: Smart schema 2 manifest missing' >&2; exit 1; }
run preview battery-test $KEYS | grep -q 'Smart learning' || { echo 'FAIL: preview did not disclose Smart learning payload' >&2; exit 1; }

# Restore must be one writer transaction and restore every learning artifact atomically.
sed -i 's/^gnss_trim=.*/gnss_trim=1/' "$MOD/config/governor.conf"
rm -f "$SMART/buckets.bin" "$SMART/buckets.bin.bak" "$SMART/smart_appheat.bin" "$SMART/night_window.conf" "$SMART/smart_mode_enabled" "$SMART/smart_prev_profile"
_restore_out="$(run restore battery-test $KEYS)"
printf '%s\n' "$_restore_out" | grep -q '^smart_learning=restored$' || { echo 'FAIL: Smart learning did not restore' >&2; exit 1; }
printf '%s\n' "$_restore_out" | grep -q '^smart_learning_files=6$' || { echo 'FAIL: Smart restore count missing' >&2; exit 1; }
printf '%s\n' "$_restore_out" | grep -q '^smart_learning_bytes=[1-9][0-9]*$' || { echo 'FAIL: Smart restore byte count missing' >&2; exit 1; }
need "$MOD/config/governor.conf" 'gnss_trim=0'
[ -s "$SMART/buckets.bin" ] && [ -s "$SMART/buckets.bin.bak" ] && [ -s "$SMART/smart_appheat.bin" ] && [ -s "$SMART/night_window.conf" ] && [ "$(cat "$SMART/smart_mode_enabled")" = 1 ] && [ "$(cat "$SMART/smart_prev_profile")" = balanced ] || { echo 'FAIL: restored complete learner state missing' >&2; exit 1; }

# External copies are atomic and carry the full Smart sidecar. Arbitrary paths remain forbidden.
run export battery-test downloads >/dev/null
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.conf" ] || { echo 'FAIL: Downloads export missing' >&2; exit 1; }
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.smart/manifest" ] || { echo 'FAIL: Downloads Smart learning copy missing' >&2; exit 1; }
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.smart/buckets.bin.bak" ] || { echo 'FAIL: Downloads Smart fallback copy missing' >&2; exit 1; }
[ -f "$EXPORT_ROOT/Download/ASB-Profiles/battery-test.smart/smart_mode_enabled" ] || { echo 'FAIL: Downloads Smart mode state missing' >&2; exit 1; }
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

# Screenshot path compatibility: the manager recognises only the exact legacy backup name,
# validates its ASB header, computes a checksum and exposes it as a bounded profile row.
mkdir -p "$EXPORT_ROOT/Documents"
printf '# ASB_BACKUP_SCHEMA=2\ngnss_trim=1\n' > "$EXPORT_ROOT/Documents/asb_settings_backup.conf"
run list-external documents | grep -q '^asb-settings-backup|1|ok|empty$' || { echo 'FAIL: legacy Documents backup was not migrated' >&2; exit 1; }
[ -f "$EXPORT_ROOT/Documents/ASB-Profiles/asb-settings-backup.conf.sha256" ] || { echo 'FAIL: migrated backup lacks checksum' >&2; exit 1; }
run import-external documents asb-settings-backup >/dev/null
run restore asb-settings-backup $KEYS >/dev/null
need "$MOD/config/governor.conf" 'gnss_trim=1'

echo 'PASS named config profiles contract'
