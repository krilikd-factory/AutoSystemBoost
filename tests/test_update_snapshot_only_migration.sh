#!/usr/bin/env bash
# Contract: some root managers remove modules/<id> before customize.sh runs. The ASB-owned
# durable snapshot must then preserve user governor settings without touching learner/profile data.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL snapshot-only update: $*" >&2; exit 1; }
need_line() { grep -Fqx -- "$2" "$1" >/dev/null || fail "missing [$2] in ${1##*/}"; }

MODID=AutoSystemBoost
NVBASE="$TMP/nv"
MODPATH="$TMP/new_module"
STATE="$TMP/state"
mkdir -p "$NVBASE/modules_update" "$MODPATH/config" "$STATE/config_profiles/user.smart"
cp "$ROOT/config/governor.conf.shipped" "$MODPATH/config/governor.conf"

# This represents ASB's prior atomic snapshot. There is deliberately no NVBASE/modules/<id>.
cat > "$STATE/governor.conf.snapshot" <<'EOF'
# ASB WebUI settings snapshot — survives module update/reinstall
radio_policy_enable=1
net_handover_active=1
net_handover_fast=1
audio_profile=eq_friendly
sustained_temp_enter=63
EOF
printf 'smart\n' > "$STATE/current_profile.bak"
printf 'smart-session-payload\n' > "$STATE/config_profiles/user.smart/manifest"
printf 'smart-history\n' > "$STATE/session_history.jsonl"
printf 'module_id=AutoSystemBoost\n' > "$STATE/update_snapshot_state"
printf '3\n' > "$STATE/config_schema"

# Extract the exact production function and redirect only its durable path for test isolation.
sed -n '/^asb_preserve_user_config() {/,/^}/p' "$ROOT/common/install.sh" | \
  sed "s|/data/adb/asb|$STATE|g" > "$TMP/preserve_fn.sh"
[ -s "$TMP/preserve_fn.sh" ] || fail 'could not extract production preserve function'
ui_print() { :; }
asb_neutralise_fresh_install() { fail 'snapshot-only update was incorrectly treated as fresh'; }
# shellcheck disable=SC1090
source "$TMP/preserve_fn.sh"
# The installer itself does not set errexit: grep returning 1 for an untouched optional key is
# normal inside its migration loop. Retain strict assertions before/after, but invoke the exact
# production function under the same semantics.
set +e
asb_preserve_user_config
_preserve_rc=$?
set -e
[ "$_preserve_rc" -eq 0 ] || fail "preserve function returned $_preserve_rc"

[ "$ASB_CONFIG_MIGRATION_MODE" = preserved ] || fail "migration mode is $ASB_CONFIG_MIGRATION_MODE"
[ "$ASB_CONFIG_MIGRATION_SOURCE" = snapshot ] || fail "migration source is $ASB_CONFIG_MIGRATION_SOURCE"
[ "$ASB_CONFIG_MIGRATED_COUNT" -ge 5 ] || fail 'snapshot values were not migrated'
need_line "$MODPATH/config/governor.conf" 'radio_policy_enable=1'
need_line "$MODPATH/config/governor.conf" 'net_handover_active=1'
need_line "$MODPATH/config/governor.conf" 'net_handover_fast=1'
need_line "$MODPATH/config/governor.conf" 'audio_profile=eq_friendly'
need_line "$MODPATH/config/governor.conf" 'sustained_temp_enter=63'
need_line "$MODPATH/current_profile" 'smart'
need_line "$STATE/config_profiles/user.smart/manifest" 'smart-session-payload'
need_line "$STATE/session_history.jsonl" 'smart-history'
[ -f "$STATE/governor.conf.snapshot" ] || fail 'migration removed its own durable snapshot'

echo 'PASS snapshot-only update migration contract'
