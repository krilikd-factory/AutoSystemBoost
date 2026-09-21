#!/usr/bin/env bash
# Force-LTPO contract: the patch is device-local and fail-closed, the toggle defaults
# off, and every lifecycle owner (install, boot, late boot, uninstall, WebUI) reaches
# the one runtime script that owns the bind.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_ltpo_apply.sh"
WEB="$ROOT/webroot/index.html"
INSTALL="$ROOT/common/install.sh"
fail() { echo "FAIL ltpo contract: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail 'runtime/asb_ltpo_apply.sh missing'
sh -n "$SRC"

# --- WebUI wiring: card, default-off, system group, own icon, honest reboot label ---
grep -q "key:'ltpo_force', type:'bool', def:'0'" "$WEB" || fail 'ltpo_force card missing or default not off'
grep -q "ltpo_force:'ui'" "$WEB" || fail 'ltpo_force not in the System category group'
grep -q "ltpo_force:'system'" "$WEB" || fail 'ltpo_force missing category colour mapping'
grep -q "ltpo_force:'ltpo'" "$WEB" || fail 'ltpo_force missing its icon mapping'
grep -q "ltpo: '<rect" "$WEB" || fail 'ltpo icon glyph missing from TECH_ICON_PATHS'
grep -q "ltpo_force:APPLY_REBOOT" "$WEB" || fail 'ltpo_force must honestly label as reboot-to-apply'
grep -q "'ltpo_force'," "$WEB" || fail 'ltpo_force missing from SNAP_KEYS (export/restore)'
grep -q "runtime/asb_ltpo_apply.sh apply" "$WEB" || fail 'cfgSet never calls the apply script'

# --- i18n: every shipped locale carries name + desc ---
for f in "$ROOT"/webroot/i18n/*.json; do
  python3 -c "
import json,sys
d=json.load(open('$f'))
c=d.get('cfg',{}).get('ltpo_force')
sys.exit(0 if (c and c.get('name') and c.get('desc')) else 1)
" || fail "ltpo_force i18n missing in $(basename "$f")"
done

# --- install-time staging ---
grep -q 'asb_prepare_ltpo_patch()' "$INSTALL" || fail 'install staging function missing'
grep -q '^asb_prepare_ltpo_patch$' "$INSTALL" || fail 'staging function never called'
grep -q 'ltpo_patched' "$INSTALL" || fail 'payload staging path missing'
grep -q 'ltpo_bind_manifest.txt' "$INSTALL" || fail 'manifest write missing'
grep -q 'ASB_L_LTPO_READY' "$ROOT/common/englishtext.sh" || fail 'English install string missing'
grep -q 'ASB_L_LTPO_READY' "$ROOT/common/russiantext.sh" || fail 'Russian install string missing'
# The payload must NOT live under a magic-mountable module path: that would be always-on.
if grep -q 'MODPATH/my_product' "$INSTALL"; then
  fail 'payload staged under a magic-mount path - that bypasses the toggle'
fi

# --- lifecycle owners ---
grep -q 'asb_ltpo_apply.sh" apply' "$ROOT/post-fs-data.sh" || fail 'post-fs-data never applies'
grep -q 'asb_ltpo_apply.sh" apply' "$ROOT/service.sh" || fail 'service.sh never rebinds late'
grep -q 'asb_ltpo_apply.sh" remove' "$ROOT/uninstall.sh" || fail 'uninstall never drops the bind'
grep -q 'ltpo_bind_manifest.txt' "$ROOT/post-fs-data.sh" || fail 'bootloop fuse does not clear the ltpo manifest'

# --- runtime guard pins: fail-closed allowlist, payload prefix, JSON balance ---
grep -q '/my_product/etc/oplus_vrr_config.json|' "$SRC" || fail 'target allowlist missing'
grep -q '"\$STATE_DIR/ltpo_patched/"\*)' "$SRC" || fail 'payload prefix check missing'
grep -q "tr -cd '{'" "$SRC" || fail 'JSON brace balance check missing'
grep -q '_cfg ltpo_force)' "$SRC" || fail 'toggle gate missing'
grep -q 'nsenter -t 1 -m -- mount --bind' "$SRC" || fail 'global-namespace bind missing'
grep -q 'ASB_LTPO_PROC_MOUNTS:-/proc/mounts' "$SRC" || fail 'mounts table not injectable for fixtures'

# --- runtime fixture: mocked mount/umount/nsenter, no real radio or mount ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mod/config" "$TMP/bin" "$TMP/state" "$TMP/live/my_product/etc"
printf 'name=AutoSystemBoost\n' > "$TMP/mod/module.prop"

# A stock table with the OEM switches OFF, like the field device shipped.
cat > "$TMP/live/my_product/etc/oplus_vrr_config.json" <<'EOF'
[
    {
        "filter_name": "oplus_adfr_config"
    },
    {
        "touch_idle": true, "hw_enable": false, "sw_enable": false, "adfr_enable": false,
        "timeout": 2500, "darkmode_enable": true
    },
    {
        "cvt": true
    }
]
EOF

cat > "$TMP/bin/mount" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ASB_LTPO_LOG"
EOF
cat > "$TMP/bin/umount" <<'EOF'
#!/bin/sh
printf 'umount %s\n' "$*" >> "$ASB_LTPO_LOG"
EOF
chmod 0755 "$TMP/bin/mount" "$TMP/bin/umount"
export PATH="$TMP/bin:$PATH"
export ASB_LTPO_LOG="$TMP/mount.log"
export ASB_LTPO_STATE_DIR="$TMP/state"
export ASB_LTPO_PROC_MOUNTS="$TMP/mounts"
export ASB_LTPO_LIVE_ROOT="$TMP/live"
: > "$TMP/mounts"

LIVE="$TMP/live/my_product/etc/oplus_vrr_config.json"
# The manifest/payload live under the injected state dir, so build the payload there.
mkdir -p "$TMP/state/ltpo_patched$TMP/live/my_product/etc"
PAYLOAD="$TMP/state/ltpo_patched${LIVE}"
sed 's/"hw_enable": false/"hw_enable": true/; s/"sw_enable": false/"sw_enable": true/' \
    "$LIVE" > "$PAYLOAD"
printf '%s|%s\n' "$LIVE" "$PAYLOAD" > "$TMP/state/ltpo_bind_manifest.txt"

run() { MODDIR="$TMP/mod" sh "$SRC" "$@"; }

# Toggle off: nothing mounts, even with a valid manifest.
printf 'ltpo_force=0\n' > "$TMP/mod/config/governor.conf"
run apply
[ ! -s "$ASB_LTPO_LOG" ] || fail 'mounted while the toggle was off'

# Toggle on + valid manifest: bind happens and ownership is recorded.
printf 'ltpo_force=1\n' > "$TMP/mod/config/governor.conf"
run apply
grep -q -- "--bind $PAYLOAD $LIVE" "$ASB_LTPO_LOG" || fail 'valid manifest was not bound'
[ -f "$TMP/state/ltpo_bind.active" ] || fail 'active marker not written'

# Toggle off with an active bind: it is removed (simulate the kernel view of the bind).
printf "%s %s ext4 rw 0 0\n" "$PAYLOAD" "$LIVE" > "$TMP/mounts"
printf 'ltpo_force=0\n' > "$TMP/mod/config/governor.conf"
run apply
grep -q "umount $LIVE" "$ASB_LTPO_LOG" || fail 'toggle-off did not unbind'
[ ! -f "$TMP/state/ltpo_bind.active" ] || fail 'active marker not cleared'

# Fail-closed: a malformed manifest line must never mount.
printf '%s|%s|extra\n' "$LIVE" "$PAYLOAD" > "$TMP/state/ltpo_bind_manifest.txt"
: > "$ASB_LTPO_LOG"
printf 'ltpo_force=1\n' > "$TMP/mod/config/governor.conf"
run apply
[ ! -s "$ASB_LTPO_LOG" ] || fail 'malformed manifest was mounted'

# Fail-closed: a payload outside the state dir must never mount.
printf '%s|%s\n' "$LIVE" "/etc/passwd" > "$TMP/state/ltpo_bind_manifest.txt"
: > "$ASB_LTPO_LOG"
run apply
[ ! -s "$ASB_LTPO_LOG" ] || fail 'out-of-bounds payload was mounted'

# Fail-closed: a target outside the allowlist must never mount.
printf '%s|%s\n' "/system/etc/hosts" "$PAYLOAD" > "$TMP/state/ltpo_bind_manifest.txt"
: > "$ASB_LTPO_LOG"
run apply
[ ! -s "$ASB_LTPO_LOG" ] || fail 'out-of-allowlist target was mounted'

# Fail-closed: a brace-unbalanced payload must never mount.
printf '%s|%s\n' "$LIVE" "$PAYLOAD" > "$TMP/state/ltpo_bind_manifest.txt"
printf '{ "broken": ' > "$PAYLOAD"
: > "$ASB_LTPO_LOG"
run apply
[ ! -s "$ASB_LTPO_LOG" ] || fail 'unbalanced JSON payload was mounted'

# remove: unbinds regardless of the toggle state.
sed 's/{ "broken": /{ "fixed": true }/' "$PAYLOAD" > "$PAYLOAD.fixed"
mv "$PAYLOAD.fixed" "$PAYLOAD"
# Rebuild a valid payload.
sed 's/"hw_enable": false/"hw_enable": true/' "$LIVE" > "$PAYLOAD"
printf "%s %s ext4 rw 0 0\n" "$PAYLOAD" "$LIVE" > "$TMP/mounts"
: > "$TMP/state/ltpo_bind.active"
: > "$ASB_LTPO_LOG"
printf 'ltpo_force=1\n' > "$TMP/mod/config/governor.conf"
run remove
grep -q "umount $LIVE" "$ASB_LTPO_LOG" || fail 'remove did not unbind'
[ ! -f "$TMP/state/ltpo_bind.active" ] || fail 'remove kept the active marker'

# status vocabulary stays stable for the WebUI/diag readers.
printf 'ltpo_force=0\n' > "$TMP/mod/config/governor.conf"
[ "$(run status)" = 'ltpo_off' ] || fail 'status off vocabulary changed'

echo 'PASS: force-LTPO contract'
