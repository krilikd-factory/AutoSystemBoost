#!/bin/sh
# Runtime (fix142): applying a saved configuration reports what it did - how many settings the
# file carries and how many it changed - and the WebUI turns save/apply into an outcome panel
# in the window instead of a two-second toast and a dialog left as it was.
#
# A user: "it is not clear whether the backup was saved or applied - the window does not
# close until I close it myself". Saving to a folder left the dialog unchanged; opening a
# file only selected it (a toast said "press Apply") and the user read it as applied.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT_DIR/tools/asb_config_backup.sh"
W="$ROOT_DIR/webroot/index.html"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL config restore outcome: $*" >&2; exit 1; }
MOD="$TMP/module"; STATE="$TMP/state"; SMART="$TMP/smart"
mkdir -p "$MOD/config" "$MOD/runtime" "$STATE" "$SMART"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
run() { MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_SMART_STATE="$SMART" ASB_SMART_RESTORE_SKIP_DAEMON=1 TMPDIR="$TMP" sh "$HELPER" "$@"; }
KEYS='gnss_trim night_modem_idle doze_level wifi_country'
run create daily $KEYS >/dev/null
# Change two of the four settings, then apply the saved copy: 4 in the file, 2 changed back.
sed -i -e 's/^gnss_trim=.*/gnss_trim=9/' -e 's/^doze_level=.*/doze_level=9/' "$MOD/config/governor.conf"
grep -q '^gnss_trim=9' "$MOD/config/governor.conf" || fail "fixture edit did not take"
out="$(run restore daily $KEYS)" || fail "restore failed: $out"
printf '%s\n' "$out" | grep -qx 'restored=daily' || fail "no restored= line: $out"
printf '%s\n' "$out" | grep -qx 'keys=4' || fail "settings in the file not reported: $out"
printf '%s\n' "$out" | grep -qx 'changed=2' || fail "changed count wrong: $out"
out="$(run restore daily $KEYS)"
printf '%s\n' "$out" | grep -qx 'changed=0' || fail "a second apply reports changes: $out"
[ -z "$(ls "$TMP" | grep asb_restore_before)" ] || fail "temporary copy left behind"

# WebUI wiring (the flow itself was driven in Chromium for this change).
grep -q 'function cfgProfileShowResult(res)' "$W" || fail "no outcome panel"
grep -q "if (_cfgProfile.result) { cfgProfilePaintResult(body); return; }" "$W" || fail "outcome not painted in the window"
grep -q "cfg_res_saved_file_title" "$W" || fail "saving to a folder still leaves the dialog unchanged"
grep -q "const settingsDone = /(^|\\\\n)restored=/.test(detail);" "$W" || fail "a Smart-only failure still reads as nothing restored"
grep -q "cfg_res_opened_banner" "$W" || fail "an opened file is not marked as not applied"
grep -q "if (_cfgProfile.resultLeft <= 0) { cfgProfileResultStop(); cfgProfileClose(); return; }" "$W" || fail "a clean success does not close itself"
for f in "$ROOT_DIR"/webroot/i18n/*.json; do
  grep -q '"cfg_res_opened_banner"' "$f" && grep -q '"cfg_res_applied_title"' "$f" || fail "outcome strings missing in ${f##*/}"
done
echo "PASS config restore outcome: keys/changed reported; save and apply answer in the window"
