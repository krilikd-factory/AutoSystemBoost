#!/usr/bin/env sh
# tests/test_intent_backup.sh — intent transaction and backup preview regression.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_intent.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
mkdir -p "$MOD/runtime" "$MOD/tools"
cp -a "$ROOT_DIR/config" "$MOD/config"
cp "$ROOT_DIR/runtime/asb_config_safe.sh" "$MOD/runtime/asb_config_safe.sh"
chmod 0755 "$MOD/runtime/asb_config_safe.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
get() { awk -F= -v k="$1" '$1==k {print $2; exit}' "$MOD/config/governor.conf"; }
export MODDIR="$MOD"
export ASB_CONFIG_STATE="$TMP/state"
export ASB_INTENT_STATE="$TMP/intent"

sh "$ROOT_DIR/tools/asb_intent.sh" apply travel >/dev/null
[ "$(get perf_ceiling_pct)" = "75" ] || fail 'travel ceiling'
[ "$(get smart_battery_bias)" = "400" ] || fail 'travel battery bias'
sh "$ROOT_DIR/tools/asb_intent.sh" apply daily >/dev/null
[ "$(get perf_ceiling_pct)" = "90" ] || fail 'daily ceiling'
[ "$(get smart_battery_bias)" = "0" ] || fail 'daily resets travel bias'

BACKUP="$TMP/asb.backup"
sh "$ROOT_DIR/tools/asb_config_backup.sh" create "$BACKUP" >/dev/null
if ! [ -s "$BACKUP" ] || ! [ -s "$BACKUP.sha256" ]; then fail 'backup/checksum missing'; fi
sh "$ROOT_DIR/tools/asb_config_backup.sh" preview "$BACKUP" >/dev/null
printf 'thermal_overlay_pct=999\n' >> "$BACKUP"
if sh "$ROOT_DIR/tools/asb_config_backup.sh" preview "$BACKUP" >/dev/null 2>&1; then
  fail 'tampered checksum accepted'
fi

echo 'PASS intent backup'
