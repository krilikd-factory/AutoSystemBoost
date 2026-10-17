#!/bin/sh
# Runtime (fix134): older multi-file backups open, new saves stay one .asb file, and the save
# dialog chooses whether Smart learning goes in.
#
# The multi-file copies (NAME.conf + NAME.conf.sha256 + NAME.smart) open as before when they
# are intact. What a messenger or a second download delivers often is not: the checksum and the
# learning folder stay behind and the file is "name (1).conf". Those were refused outright.
# Now they are read line by line - known keys, plain values, the current validator - and a
# value this module rejects is left out by name instead of sinking the whole backup.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT_DIR/tools/asb_config_backup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL config legacy import: $*" >&2; exit 1; }
MOD="$TMP/module"; STATE="$TMP/state"; SMART="$TMP/smart"; OLD="$TMP/storage/Telegram"
mkdir -p "$MOD/config" "$MOD/runtime" "$STATE" "$SMART" "$OLD"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"
cp "$ROOT_DIR/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
run() { MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_SMART_STATE="$SMART" ASB_SMART_RESTORE_SKIP_DAEMON=1 sh "$HELPER" "$@"; }
KEYS='gnss_trim night_modem_idle doze_level wifi_country quiet_tick_s'
printf 'bucket-learning-fixture\n' > "$SMART/buckets.bin"
printf '1\n' > "$SMART/smart_mode_enabled"

# 0. Is there learning to offer?
run smart-available | grep -qx 'smart_learning=available' || fail "learning on the phone not reported"

# 1. Save without learning: settings only, and the .asb carries no learning folder.
out="$(run create shareable --no-smart $KEYS)"
printf '%s\n' "$out" | grep -qx 'smart_learning=skipped_by_choice' || fail "--no-smart ignored: $out"
[ ! -d "$STATE/config_profiles/shareable.smart" ] || fail "learning saved although left out"
mkdir -p "$TMP/out"
run export-path shareable "$TMP/out" | grep -qx "exported=$TMP/out/shareable.asb" || fail "not one .asb file"
if tar -tzf "$TMP/out/shareable.asb" | grep -q 'shareable.smart'; then fail "learning inside a settings-only file"; fi
# ...and replacing a profile that had learning drops the old learning.
run create both $KEYS >/dev/null
[ -d "$STATE/config_profiles/both.smart" ] || fail "learning not saved by default"
run replace both --no-smart $KEYS >/dev/null
[ ! -d "$STATE/config_profiles/both.smart" ] || fail "replaced profile kept the old learning"

# 2. An intact multi-file copy opens on the strict path, learning included.
run create daily $KEYS >/dev/null
cp "$STATE/config_profiles/daily.conf" "$STATE/config_profiles/daily.conf.sha256" "$OLD/"
cp -R "$STATE/config_profiles/daily.smart" "$OLD/"
run delete daily >/dev/null
out="$(run import-path "$OLD/daily.conf")"
printf '%s\n' "$out" | grep -qx 'imported=daily' || fail "intact copy: $out"
printf '%s\n' "$out" | grep -qx 'smart_learning=saved' || fail "intact copy lost its learning: $out"
printf '%s\n' "$out" | grep -q 'format=older' && fail "intact copy took the line-by-line path"

# 3. The same copy after a messenger: no checksum, no learning folder, renamed.
cp "$OLD/daily.conf" "$OLD/daily (1).conf"
out="$(run import-path "$OLD/daily (1).conf")"
printf '%s\n' "$out" | grep -qx 'imported=daily-1' || fail "renamed copy without checksum refused: $out"
printf '%s\n' "$out" | grep -qx 'format=older_checked_line_by_line' || fail "line-by-line path not reported"
run list | grep -q '^daily-1|.*|ok|empty$' || fail "imported copy not stored with a fresh checksum"
run restore daily-1 $KEYS | grep -qx 'restored=daily-1' || fail "imported copy does not restore"

# 4. A pre-V64 whole-config backup with an inline comment, a value the current module rejects
#    and a key that no longer exists: the rest opens, the bad one is named.
{ echo '# ASB_BACKUP_SCHEMA=2'; echo '# created_at=1'
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MOD/config/governor.conf" \
    | sed 's/^quiet_tick_s=.*/quiet_tick_s=1/; s/^gnss_trim=.*/gnss_trim=1   # mine/'
  echo 'net_handover_fast=1'; printf 'doze_level=two words\r\n'; } > "$OLD/asb_settings_backup.conf"
out="$(run import-path "$OLD/asb_settings_backup.conf")"
printf '%s\n' "$out" | grep -qx 'imported=asb_settings_backup' || fail "whole-config backup refused: $out"
printf '%s\n' "$out" | grep -qx 'skipped_keys=quiet_tick_s' || fail "rejected value not named: $out"
P="$STATE/config_profiles/asb_settings_backup.conf"
grep -qx 'gnss_trim=1' "$P" || fail "inline comment not stripped"
grep -q '^net_handover_fast=' "$P" && fail "a key this module no longer has was kept"
grep -q '^doze_level=two' "$P" && fail "a value with a space inside was kept"
grep -q '^quiet_tick_s=' "$P" && fail "the rejected value was kept"
run restore asb_settings_backup $KEYS >/dev/null || fail "whole-config backup does not restore"
grep -qx 'gnss_trim=1' "$MOD/config/governor.conf" || fail "restored value not applied"

# 5. Not ours: refused.
printf 'foo=1\nbar=2\n' > "$OLD/random.conf"
if run import-path "$OLD/random.conf" >/dev/null 2>&1; then fail "a foreign .conf accepted"; fi

# 6. WebUI: the choice, the flag and the notice, in every language.
UI="$ROOT_DIR/webroot/index.html"
grep -q "' smart-available'" "$UI" || fail "save dialog does not ask whether learning exists"
grep -q "' --no-smart'" "$UI" || fail "save does not pass the choice"
grep -q 'format=older_checked_line_by_line' "$UI" || fail "older-copy import not announced"
for f in "$ROOT_DIR"/webroot/i18n/*.json; do
  for k in cfg_profile_smart_include cfg_profile_smart_include_on cfg_profile_smart_include_off cfg_profile_imported_older cfg_profile_imported_skipped; do
    grep -q "\"$k\"" "$f" || fail "$k missing in ${f##*/}"
  done
done
echo "PASS config legacy import: old copies open (intact or not), saves stay one .asb, Smart learning optional"
