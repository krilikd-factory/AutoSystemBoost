#!/bin/sh
# Config writer lease contract: no blind lock deletion, no orphan timeout without evidence.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WRITER="$ROOT_DIR/runtime/asb_config_safe.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
STATE="$TMP/state"
mkdir -p "$MOD/config" "$STATE"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf.shipped" "$MOD/config/governor.conf.shipped"

run_writer() {
  MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" sh "$WRITER" "$@"
}
need() { grep -Fqx "$2" "$1" >/dev/null || { echo "FAIL: missing [$2] in $1" >&2; exit 1; }; }

# A dead owner whose lease is older than the conservative stale threshold may be reclaimed.
mkdir "$STATE/config.lock"
printf '%s\n' '999999' > "$STATE/config.lock/pid"
touch -d '90 seconds ago' "$STATE/config.lock"
run_writer set gnss_trim 0 >/dev/null
need "$MOD/config/governor.conf" 'gnss_trim=0'
need "$STATE/config_last_txn" 'result_class=success'
grep -q '^lock_recovered=stale_owner=999999,owner_state=pid_present,age=' "$STATE/config_last_txn" || {
  echo 'FAIL: stale PID reclaim provenance absent' >&2; exit 1;
}
[ ! -d "$STATE/config.lock" ] || { echo 'FAIL: successful writer left lock behind' >&2; exit 1; }

# A V63/interrupted legacy lock can have no pid at all. It is safe to reclaim only after the
# exact same conservative age threshold: fresh metadata-less acquisition is still protected.
mkdir "$STATE/config.lock"
touch -d '90 seconds ago' "$STATE/config.lock"
run_writer set gnss_trim 1 >/dev/null
need "$MOD/config/governor.conf" 'gnss_trim=1'
grep -q '^lock_recovered=stale_owner=missing,owner_state=missing_metadata,age=' "$STATE/config_last_txn" || {
  echo 'FAIL: stale pid-less reclaim provenance absent' >&2; exit 1;
}
[ ! -d "$STATE/config.lock" ] || { echo 'FAIL: pid-less stale reclaim left lock behind' >&2; exit 1; }

# Malformed historical pid metadata also has no trustworthy owner identity, but may only be
# reclaimed after the stale threshold.
mkdir "$STATE/config.lock"
printf '%s\n' 'not-a-pid' > "$STATE/config.lock/pid"
touch -d '90 seconds ago' "$STATE/config.lock"
run_writer set gnss_trim 0 >/dev/null
grep -q '^lock_recovered=stale_owner=missing,owner_state=invalid_metadata,age=' "$STATE/config_last_txn" || {
  echo 'FAIL: invalid pid reclaim provenance absent' >&2; exit 1;
}
[ ! -d "$STATE/config.lock" ] || { echo 'FAIL: invalid-pid stale reclaim left lock behind' >&2; exit 1; }

# Fresh pid-less metadata can be in the post-mkdir acquisition window and must not be stolen.
mkdir "$STATE/config.lock"
if MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_CONFIG_LOCK_WAIT_TICKS=2 \
  sh "$WRITER" set gnss_trim 1 >/dev/null 2>&1; then
  echo 'FAIL: writer stole fresh pid-less lock' >&2; exit 1
fi
need "$STATE/config_last_txn" 'result_class=lock_live'
need "$STATE/config_last_txn" 'lock_owner=missing'
need "$STATE/config_last_txn" 'lock_owner_state=missing_metadata'
rm -f "$STATE/config.lock/pid" "$STATE/config.lock/started"
rmdir "$STATE/config.lock"

# A live owner must never be stolen, even if directory mtime is old. Shorten only test wait.
mkdir "$STATE/config.lock"
printf '%s\n' "$$" > "$STATE/config.lock/pid"
touch -d '90 seconds ago' "$STATE/config.lock"
if MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" ASB_CONFIG_LOCK_WAIT_TICKS=2 \
  sh "$WRITER" set gnss_trim 1 >/dev/null 2>&1; then
  echo 'FAIL: writer stole live lock' >&2; exit 1
fi
need "$STATE/config_last_txn" 'result_class=lock_live'
need "$STATE/config_last_txn" "lock_owner=$$"
need "$STATE/config_last_txn" 'lock_owner_state=pid_present'
grep -q '^lock_age=' "$STATE/config_last_txn" || { echo 'FAIL: live lock age absent' >&2; exit 1; }
need "$STATE/config_last_txn" 'lock_path=config.lock'
POLICY_JSON="$TMP/effective_policy.json"
MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" sh "$ROOT_DIR/tools/asb_effective_policy.sh" > "$POLICY_JSON" 2>/dev/null
python3 - "$POLICY_JSON" "$$" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    txn = json.load(fh)['config_last_txn']
assert txn['lock_owner'] == sys.argv[2], txn
assert txn['lock_owner_state'] == 'pid_present', txn
assert isinstance(txn['lock_age'], int) and txn['lock_age'] >= 0, txn
PY
rm -f "$STATE/config.lock/pid" "$STATE/config.lock/started"
rmdir "$STATE/config.lock"

echo 'PASS config lock lease contract'
