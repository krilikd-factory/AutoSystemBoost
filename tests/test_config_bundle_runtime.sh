#!/bin/sh
# Runtime (fix125): a configuration saved to a folder is ONE file, NAME.asb - settings, their
# checksum and the whole Smart learning payload - and opens back through the same checks.
# Anything else inside the archive (extra names, traversal, two profiles, a link) is refused;
# older three-part copies still open.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HELPER="$ROOT_DIR/tools/asb_config_backup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL config bundle: $*" >&2; exit 1; }
MOD="$TMP/module"; STATE="$TMP/state"; SMART="$TMP/smart"; OUT="$TMP/storage/Backups"
mkdir -p "$MOD/config" "$MOD/runtime" "$STATE" "$SMART" "$OUT"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"
cp "$ROOT_DIR/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
run() { MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_SMART_STATE="$SMART" ASB_SMART_RESTORE_SKIP_DAEMON=1 sh "$HELPER" "$@"; }
KEYS='gnss_trim night_modem_idle doze_level wifi_country'
printf 'bucket-learning-fixture\n' > "$SMART/buckets.bin"
printf 'bucket-fallback-fixture\n' > "$SMART/buckets.bin.bak"
printf 'appheat-learning-fixture\n' > "$SMART/smart_appheat.bin"
printf 'sleep_min=1380\nwake_min=420\nsamples=12\n' > "$SMART/night_window.conf"
printf '1\n' > "$SMART/smart_mode_enabled"
i=0; : > "$SMART/session_history.jsonl"
while [ $i -lt 400 ]; do printf '{"v":9,"profile":"smart","dur":360,"bat_ttd":75,"n":%d}\n' $i >> "$SMART/session_history.jsonl"; i=$((i+1)); done
printf '{"count":4,"t2s":20}\n' > "$MOD/runtime/pstats_battery.json"

run create daily $KEYS >/dev/null

# 1. Save to a folder: exactly one file.
# An older three-part copy of the same name sits there and is superseded.
printf '# ASB_PROFILE_SCHEMA=1\ngnss_trim=1\n' > "$OUT/daily.conf"; printf 'x\n' > "$OUT/daily.conf.sha256"; mkdir -p "$OUT/daily.smart"
# ...while a user's own unrelated file of another name is left alone.
printf 'mine\n' > "$OUT/notes.conf"
out="$(run export-path daily "$OUT")"
printf '%s\n' "$out" | grep -qx "exported=$OUT/daily.asb" || fail "export did not report the .asb file: $out"
printf '%s\n' "$out" | grep -qx 'smart_learning=saved' || fail "Smart learning not in the file: $out"
[ "$(ls -A "$OUT" | grep -c '^daily')" = 1 ] || fail "more than one entry for one configuration: $(ls -A "$OUT")"
[ -f "$OUT/notes.conf" ] || fail "a user file was removed"
[ "$(head -c 2 "$OUT/daily.asb" | od -An -tx1 | tr -d ' \n')" = 1f8b ] || fail "not compressed"
tar -tzf "$OUT/daily.asb" | grep -qx 'daily.smart/session_history.jsonl' || fail "session history missing inside"

# 2. Opens back - the name comes from inside, whatever the file is called now.
run delete daily >/dev/null
cp "$OUT/daily.asb" "$OUT/renamed copy.asb"
imp="$(run import-path "$OUT/renamed copy.asb")"
printf '%s\n' "$imp" | grep -qx 'imported=daily' || fail "import did not restore the name: $imp"
printf '%s\n' "$imp" | grep -qx 'smart_learning=saved' || fail "Smart learning not imported: $imp"
run list | grep -q '^daily|.*|ok|saved$' || fail "imported profile not listed with Smart learning"
rm -f "$SMART/buckets.bin"
run restore daily $KEYS | grep -qx 'smart_learning=restored' || fail "restore from an imported file failed"
[ -s "$SMART/buckets.bin" ] || fail "learning not restored from the file"

# 3. Refused: tampered content, an extra entry, traversal, two profiles, a link.
mk() {   # $1 = name of a staging dir already filled; $2 = output
  ( cd "$TMP/$1" && tar -czf "$2" * ) 2>/dev/null
}
rm -rf "$TMP/x" && mkdir -p "$TMP/x" && tar -xzf "$OUT/daily.asb" -C "$TMP/x"
printf 'tamper' >> "$TMP/x/daily.conf"; mk x "$TMP/bad1.asb"
if run import-path "$TMP/bad1.asb" >/dev/null 2>&1; then fail "tampered settings accepted"; fi
rm -rf "$TMP/x" && mkdir -p "$TMP/x" && tar -xzf "$OUT/daily.asb" -C "$TMP/x"
printf 'evil\n' > "$TMP/x/payload.sh"; mk x "$TMP/bad2.asb"
if run import-path "$TMP/bad2.asb" >/dev/null 2>&1; then fail "an extra file inside accepted"; fi
rm -rf "$TMP/x" && mkdir -p "$TMP/x" && tar -xzf "$OUT/daily.asb" -C "$TMP/x"
cp "$TMP/x/daily.conf" "$TMP/x/other.conf"; mk x "$TMP/bad3.asb"
if run import-path "$TMP/bad3.asb" >/dev/null 2>&1; then fail "two profiles in one file accepted"; fi
rm -rf "$TMP/x" && mkdir -p "$TMP/x" && tar -xzf "$OUT/daily.asb" -C "$TMP/x"
ln -s /etc/passwd "$TMP/x/daily.smart/buckets.bin.bak" 2>/dev/null || true
rm -f "$TMP/x/daily.smart/buckets.bin.bak"; ln -s /etc/passwd "$TMP/x/daily.smart/buckets.bin.bak"; mk x "$TMP/bad4.asb"
if run import-path "$TMP/bad4.asb" >/dev/null 2>&1; then fail "a link inside accepted"; fi
( cd "$TMP" && tar -czf "$TMP/bad5.asb" --transform 's|^x/|../|' x/ASB_BUNDLE ) 2>/dev/null || true
if [ -s "$TMP/bad5.asb" ] && run import-path "$TMP/bad5.asb" >/dev/null 2>&1; then fail "a traversal entry accepted"; fi
printf 'not an archive' > "$TMP/bad6.asb"
if run import-path "$TMP/bad6.asb" >/dev/null 2>&1; then fail "garbage accepted"; fi
[ -z "$(ls -A "$STATE/config_profiles" | grep '^\.unpack')" ] || fail "an unpack folder was left behind"

# 4. Older three-part copies still open.
run delete daily >/dev/null 2>&1 || true
run create legacy $KEYS >/dev/null
run export legacy downloads >/dev/null 2>&1 || true
LEG="$STATE/config_profiles"
mkdir -p "$TMP/old" && cp "$LEG/legacy.conf" "$LEG/legacy.conf.sha256" "$TMP/old/" && cp -R "$LEG/legacy.smart" "$TMP/old/"
run delete legacy >/dev/null
run import-path "$TMP/old/legacy.conf" | grep -qx 'imported=legacy' || fail "an older .conf copy no longer opens"

# 5. The WebUI browser lists .asb files and shows the file the helper wrote.
UI="$ROOT_DIR/webroot/index.html"
grep -q 'const conf = !dir && /\\.(asb|conf)$/i.test(name);' "$UI" || fail "file browser does not list .asb"
grep -q "const outFile = exm ? exm\[2\].replace" "$UI" || fail "save toast does not name the written file"

echo "PASS config bundle: one .asb file per saved configuration, verified import, old copies still open"
