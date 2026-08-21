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
grep -q '^lock_recovered=stale_owner=999999,age=' "$STATE/config_last_txn" || {
  echo 'FAIL: stale reclaim provenance absent' >&2; exit 1;
}
[ ! -d "$STATE/config.lock" ] || { echo 'FAIL: successful writer left lock behind' >&2; exit 1; }

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
grep -q '^lock_age=' "$STATE/config_last_txn" || { echo 'FAIL: live lock age absent' >&2; exit 1; }
need "$STATE/config_last_txn" 'lock_path=config.lock'
rm -f "$STATE/config.lock/pid" "$STATE/config.lock/started"
rmdir "$STATE/config.lock"

echo 'PASS config lock lease contract'
