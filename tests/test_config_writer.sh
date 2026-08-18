#!/usr/bin/env sh
# tests/test_config_writer.sh — regression tests for the only runtime writer.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
WRITER="$ROOT_DIR/runtime/asb_config_safe.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/asb_cfg_writer.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
STATE="$TMP/state"
SNAP="$TMP/governor.conf.snapshot"
BACKUP="$TMP/backup.conf"

fail() { echo "FAIL: $*" >&2; exit 1; }
need_line() { grep -qx "$2" "$1" || fail "missing '$2' in $1"; }

mkdir -p "$MOD/config"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT_DIR/config/governor.conf" "$MOD/config/governor.conf.shipped"

# Source checkout must not ship a stale writer whitelist.
current_keys="$TMP/current.keys"
shipped_keys="$TMP/shipped.keys"
sed -n -E 's/^[[:space:]]*([A-Za-z0-9_]+)=.*/\1/p' "$ROOT_DIR/config/governor.conf" | sort -u > "$current_keys"
sed -n -E 's/^[[:space:]]*([A-Za-z0-9_]+)=.*/\1/p' "$ROOT_DIR/config/governor.conf.shipped" | sort -u > "$shipped_keys"
diff -u "$current_keys" "$shipped_keys" >/dev/null || fail "governor.conf.shipped key set is stale"

run_writer() {
  MODDIR="$MOD" ASB_CONFIG_STATE="$STATE" sh "$WRITER" "$@"
}

# F-02: a thermal overlay above 100 used to become a negative multiplier and
# make the writer silently skip the safety cap. Both values must be rejected.
if run_writer set thermal_overlay_pct 999 >/dev/null 2>&1; then
  fail "unsafe thermal_overlay_pct was accepted"
fi
if run_writer set thermal_junction_hard_c 0 >/dev/null 2>&1; then
  fail "unsafe thermal_junction_hard_c was accepted"
fi
need_line "$MOD/config/governor.conf" "thermal_overlay_pct=18"
need_line "$MOD/config/governor.conf" "thermal_junction_hard_c=95"

# A linked slider update must commit both keys and its snapshot under one lock.
run_writer set-many --snapshot "$SNAP" \
  sustained_temp_enter 60 sustained_temp_mode manual >/dev/null
need_line "$MOD/config/governor.conf" "sustained_temp_enter=60"
need_line "$MOD/config/governor.conf" "sustained_temp_mode=manual"
need_line "$SNAP" "sustained_temp_enter=60"
need_line "$SNAP" "sustained_temp_mode=manual"

# F-03: malformed imports must leave the active configuration untouched.
printf 'sustained_temp_enter=999\n' > "$BACKUP"
if run_writer import "$BACKUP" "$SNAP" sustained_temp_enter sustained_temp_mode >/dev/null 2>&1; then
  fail "invalid import was accepted"
fi
need_line "$MOD/config/governor.conf" "sustained_temp_enter=60"

# A valid import is applied as one validated transaction and updates the snapshot.
printf 'sustained_temp_enter=62\nsustained_temp_mode=manual\n' > "$BACKUP"
run_writer import "$BACKUP" "$SNAP" sustained_temp_enter sustained_temp_mode >/dev/null
need_line "$MOD/config/governor.conf" "sustained_temp_enter=62"
need_line "$MOD/config/governor.conf" "sustained_temp_mode=manual"
need_line "$SNAP" "sustained_temp_enter=62"
need_line "$SNAP" "sustained_temp_mode=manual"

echo "PASS config writer"
