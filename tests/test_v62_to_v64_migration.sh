#!/usr/bin/env bash
# Public-release migration contract. V62 schema 17 lacked the keys below; the
# remaining V62 defaults matched the V64 shipped config. Keep this list explicit:
# a future schema change must update its own migration rather than accidentally making
# the V62 upgrade path untestable.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_v62_v63_migration.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
need_line() { grep -qx "$2" "$1" || fail "missing '$2' in $1"; }

MODDIR="$TMP/module"
STATE="$TMP/state"
mkdir -p "$MODDIR/config" "$STATE"
cp "$ROOT_DIR/config/governor.conf" "$MODDIR/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MODDIR/config/governor.conf.shipped"

# Reconstruct the shipped V62 config shape from the exact V62→V64 schema delta.
# Do not create /data/adb: this is an isolated host contract.
V62_ONLY_MISSING=(
  gnss_trim net_rps net_txqueue night_modem_idle perf_ceiling_pct shadow_mode
  thermal_budget_dwell_s thermal_budget_enable thermal_budget_light_headroom_pct
  thermal_budget_light_trim_pct thermal_budget_moderate_headroom_pct
  thermal_budget_moderate_trim_pct thermal_budget_severe_headroom_pct
  thermal_budget_severe_trim_pct wakelock_action radio_policy_enable net_handover_active
)
for key in "${V62_ONLY_MISSING[@]}"; do
  sed -i "/^[[:space:]]*${key}=/d" "$MODDIR/config/governor.conf"
done

# Representative persisted V62 user values must survive the update unchanged.
sed -i \
  -e 's/^sustained_temp_enter=.*/sustained_temp_enter=64/' \
  -e 's/^sustained_temp_ceiling=.*/sustained_temp_ceiling=66/' \
  -e 's/^sustained_temp_mode=.*/sustained_temp_mode=manual/' \
  -e 's/^smart_battery_bias=.*/smart_battery_bias=420/' \
  "$MODDIR/config/governor.conf"
printf '%s\n' 17 > "$MODDIR/config/.schema_version"
cp "$MODDIR/config/governor.conf" "$TMP/v62_before.conf"

# Extract and run the exact production migration function under test-local paths.
sed -n '/^asb_migrate_governor_conf() {/,/^}/p' "$ROOT_DIR/service.sh" > "$TMP/migrate_fn.sh"
[ -s "$TMP/migrate_fn.sh" ] || fail "cannot extract production migration function"
asb_log() { printf '%s\n' "$*" >> "$TMP/migrate.log"; }
# shellcheck disable=SC1090
source "$TMP/migrate_fn.sh"
asb_migrate_governor_conf

need_line "$MODDIR/config/.schema_version" '20'
find "$MODDIR/config" -maxdepth 1 -name 'governor.conf.bak.schema17.*' | grep -q . || fail "V62 backup missing"
for line in \
  'sustained_temp_enter=64' \
  'sustained_temp_ceiling=66' \
  'sustained_temp_mode=manual' \
  'smart_battery_bias=420'; do
  need_line "$MODDIR/config/governor.conf" "$line"
done
for key in "${V62_ONLY_MISSING[@]}"; do
  expected=$(grep -m1 "^[[:space:]]*${key}=" "$MODDIR/config/governor.conf.shipped")
  [ -n "$expected" ] || fail "missing shipped V64 default for $key"
  need_line "$MODDIR/config/governor.conf" "$expected"
done
if ! awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {p=index($0,"="); if(!p)next; k=substr($0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); if(++seen[k]>1)bad=1} END{exit bad}' "$MODDIR/config/governor.conf"; then
  fail "migration left duplicate keys"
fi

# Re-running migration must be a no-op once marker 20 is committed.
first_sum=$(sha256sum "$MODDIR/config/governor.conf" | awk '{print $1}')
asb_migrate_governor_conf
second_sum=$(sha256sum "$MODDIR/config/governor.conf" | awk '{print $1}')
[ "$first_sum" = "$second_sum" ] || fail "migration is not idempotent at schema 20"

# The V64 safe writer must accept and atomically update an added V64 key afterwards.
MODDIR="$MODDIR" ASB_CONFIG_STATE="$STATE" sh "$ROOT_DIR/runtime/asb_config_safe.sh" set gnss_trim 1 >/dev/null
need_line "$MODDIR/config/governor.conf" 'gnss_trim=1'
need_line "$STATE/config_last_txn" 'result_class=success'

echo "PASS V62-to-V64 migration contract"
