#!/usr/bin/env bash
# Multimedia-telemetry-off contract: the patch is device-local and fail-closed, the
# toggle defaults off, and every lifecycle owner (install, boot, late boot, uninstall,
# WebUI) reaches the one runtime script that owns the bind. Same shape as the
# force-LTPO contract, for the XML sibling.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_mmfeed_apply.sh"
WEB="$ROOT/webroot/index.html"
INSTALL="$ROOT/common/install.sh"
fail() { echo "FAIL mmfeed contract: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail 'runtime/asb_mmfeed_apply.sh missing'
sh -n "$SRC"

# --- WebUI wiring: card, default-off, system group, own icon, honest reboot label ---
grep -q "key:'mmfeed_off', type:'bool', def:'0'" "$WEB" || fail 'mmfeed_off card missing or default not off'
grep -q "mmfeed_off:'ui'" "$WEB" || fail 'mmfeed_off not in the System category group'
grep -q "mmfeed_off:'system'" "$WEB" || fail 'mmfeed_off missing category colour mapping'
grep -q "mmfeed_off:'mmfeed'" "$WEB" || fail 'mmfeed_off missing its icon mapping'
grep -q "mmfeed: '<path" "$WEB" || fail 'mmfeed icon glyph missing from TECH_ICON_PATHS'
grep -q "mmfeed_off:APPLY_REBOOT" "$WEB" || fail 'mmfeed_off must honestly label as reboot-to-apply'
grep -q "'mmfeed_off'," "$WEB" || fail 'mmfeed_off missing from SNAP_KEYS (export/restore)'
grep -q "runtime/asb_mmfeed_apply.sh apply" "$WEB" || fail 'cfgSet never calls the apply script'

# --- i18n: every shipped locale carries name + desc + the OEM-closed badge string ---
for f in "$ROOT"/webroot/i18n/*.json; do
  python3 -c "
import json,sys
d=json.load(open('$f'))
c=d.get('cfg',{}).get('mmfeed_off')
ok = c and c.get('name') and c.get('desc') and d.get('st_mmfeed_oem')
sys.exit(0 if ok else 1)
" || fail "mmfeed i18n missing in $(basename "$f")"
done

# --- install-time staging ---
grep -q 'asb_prepare_mmfeed_patch()' "$INSTALL" || fail 'install staging function missing'
grep -q '^asb_prepare_mmfeed_patch$' "$INSTALL" || fail 'staging function never called'
grep -q 'mmfeed_patched' "$INSTALL" || fail 'payload staging path missing'
grep -q 'mmfeed_bind_manifest.txt' "$INSTALL" || fail 'manifest write missing'
grep -q 'ASB_L_MMFEED_READY' "$ROOT/common/englishtext.sh" || fail 'English install string missing'
grep -q 'ASB_L_MMFEED_READY' "$ROOT/common/russiantext.sh" || fail 'Russian install string missing'
# The payload must NOT live under a magic-mountable module path: that would be always-on.
if grep -q 'MODPATH/my_product' "$INSTALL"; then
  fail 'payload staged under a magic-mount path - that bypasses the toggle'
fi

# --- lifecycle owners ---
grep -q 'asb_mmfeed_apply.sh" apply' "$ROOT/post-fs-data.sh" || fail 'post-fs-data never applies'
grep -q 'asb_mmfeed_apply.sh" apply' "$ROOT/service.sh" || fail 'service.sh never rebinds late'
grep -q 'asb_mmfeed_apply.sh" remove' "$ROOT/uninstall.sh" || fail 'uninstall never drops the bind'
grep -q 'mmfeed_bind_manifest.txt' "$ROOT/post-fs-data.sh" || fail 'bootloop fuse does not clear the mmfeed manifest'

# --- runtime guard pins: fail-closed allowlist, payload prefix, XML sanity ---
grep -q '/my_product/etc/Multimedia_Feedback_List.xml|' "$SRC" || fail 'target allowlist missing'
grep -q '"\$STATE_DIR/mmfeed_patched/"\*)' "$SRC" || fail 'payload prefix check missing'
grep -q '<isOpen>false</isOpen>' "$SRC" || fail 'isOpen sanity check missing'
grep -q '_cfg mmfeed_off)' "$SRC" || fail 'toggle gate missing'
grep -q 'nsenter -t 1 -m -- mount --bind' "$SRC" || fail 'global-namespace bind missing'
grep -q 'ASB_MMFEED_PROC_MOUNTS:-/proc/mounts' "$SRC" || fail 'mounts table not injectable for fixtures'

# --- runtime fixture: mocked mount/umount/nsenter, no real radio or mount ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mod/config" "$TMP/bin" "$TMP/state" "$TMP/live/my_product/etc"
printf 'name=AutoSystemBoost\n' > "$TMP/mod/module.prop"

# A stock feedback list with the collector OPEN, like the field device shipped.
cat > "$TMP/live/my_product/etc/Multimedia_Feedback_List.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" ?>
<filter-conf>
  <version>20240507</version>
  <isOpen>true</isOpen>
  <totalAudioLogs>20</totalAudioLogs>
  <filter-name>Multimedia_Feedback_List</filter-name>
</filter-conf>
EOF

cat > "$TMP/bin/mount" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ASB_MMFEED_LOG"
EOF
cat > "$TMP/bin/umount" <<'EOF'
#!/bin/sh
printf 'umount %s\n' "$*" >> "$ASB_MMFEED_LOG"
EOF
chmod 0755 "$TMP/bin/mount" "$TMP/bin/umount"
export PATH="$TMP/bin:$PATH"
export ASB_MMFEED_LOG="$TMP/mount.log"
export ASB_MMFEED_STATE_DIR="$TMP/state"
export ASB_MMFEED_PROC_MOUNTS="$TMP/mounts"
export ASB_MMFEED_LIVE_ROOT="$TMP/live"
: > "$TMP/mounts"

LIVE="$TMP/live/my_product/etc/Multimedia_Feedback_List.xml"
# The manifest/payload live under the injected state dir, so build the payload there.
mkdir -p "$TMP/state/mmfeed_patched$TMP/live/my_product/etc"
PAYLOAD="$TMP/state/mmfeed_patched${LIVE}"
sed 's|<isOpen>true</isOpen>|<isOpen>false</isOpen>|' "$LIVE" > "$PAYLOAD"
printf '%s|%s\n' "$LIVE" "$PAYLOAD" > "$TMP/state/mmfeed_bind_manifest.txt"

run() { MODDIR="$TMP/mod" sh "$SRC" "$@"; }

# Toggle off: nothing mounts, even with a valid manifest.
printf 'mmfeed_off=0\n' > "$TMP/mod/config/governor.conf"
run apply
[ ! -s "$ASB_MMFEED_LOG" ] || fail 'mounted while the toggle was off'

# Toggle on + valid manifest: bind happens and ownership is recorded.
printf 'mmfeed_off=1\n' > "$TMP/mod/config/governor.conf"
run apply
grep -q -- "--bind $PAYLOAD $LIVE" "$ASB_MMFEED_LOG" || fail 'valid manifest was not bound'
[ -f "$TMP/state/mmfeed_bind.active" ] || fail 'active marker not written'

# Toggle off with an active bind: it is removed (simulate the kernel view of the bind).
printf "%s %s ext4 rw 0 0\n" "$PAYLOAD" "$LIVE" > "$TMP/mounts"
printf 'mmfeed_off=0\n' > "$TMP/mod/config/governor.conf"
run apply
grep -q "umount $LIVE" "$ASB_MMFEED_LOG" || fail 'toggle-off did not unbind'
[ ! -f "$TMP/state/mmfeed_bind.active" ] || fail 'active marker not cleared'

# Fail-closed: a malformed manifest line must never mount.
printf '%s|%s|extra\n' "$LIVE" "$PAYLOAD" > "$TMP/state/mmfeed_bind_manifest.txt"
: > "$ASB_MMFEED_LOG"
printf 'mmfeed_off=1\n' > "$TMP/mod/config/governor.conf"
run apply
[ ! -s "$ASB_MMFEED_LOG" ] || fail 'malformed manifest was mounted'

# Fail-closed: a payload outside the state dir must never mount.
printf '%s|%s\n' "$LIVE" "/etc/passwd" > "$TMP/state/mmfeed_bind_manifest.txt"
: > "$ASB_MMFEED_LOG"
run apply
[ ! -s "$ASB_MMFEED_LOG" ] || fail 'out-of-bounds payload was mounted'

# Fail-closed: a target outside the allowlist must never mount.
printf '%s|%s\n' "/system/etc/hosts" "$PAYLOAD" > "$TMP/state/mmfeed_bind_manifest.txt"
: > "$ASB_MMFEED_LOG"
run apply
[ ! -s "$ASB_MMFEED_LOG" ] || fail 'out-of-allowlist target was mounted'

# Fail-closed: a payload that still says isOpen=true must never mount (it would be a
# no-op mount at best, and it means the patch step silently failed).
printf '%s|%s\n' "$LIVE" "$PAYLOAD" > "$TMP/state/mmfeed_bind_manifest.txt"
cp "$LIVE" "$PAYLOAD"
: > "$ASB_MMFEED_LOG"
run apply
[ ! -s "$ASB_MMFEED_LOG" ] || fail 'unpatched (isOpen=true) payload was mounted'

# remove: unbinds regardless of the toggle state.
sed 's|<isOpen>true</isOpen>|<isOpen>false</isOpen>|' "$LIVE" > "$PAYLOAD"
printf "%s %s ext4 rw 0 0\n" "$PAYLOAD" "$LIVE" > "$TMP/mounts"
: > "$TMP/state/mmfeed_bind.active"
: > "$ASB_MMFEED_LOG"
run remove
grep -q "umount $LIVE" "$ASB_MMFEED_LOG" || fail 'remove did not unbind'
[ ! -f "$TMP/state/mmfeed_bind.active" ] || fail 'remove kept the active marker'

# status vocabulary stays stable for the WebUI/diag readers.
printf 'mmfeed_off=0\n' > "$TMP/mod/config/governor.conf"
[ "$(run status)" = 'mmfeed_off' ] || fail 'status off vocabulary changed'

# --- executable install-patcher fixture: the REAL staging function against fixture
# files, with only the state root and live path rewritten to the sandbox ---
MF_DIR="$TMP/installer"
mkdir -p "$MF_DIR/asb" "$MF_DIR/live"
sed -n '/^asb_prepare_mmfeed_patch()/,/^}/p' "$INSTALL" |
  sed "s|/data/adb/asb|$MF_DIR/asb|g; s|/my_product/etc/Multimedia_Feedback_List.xml|$MF_DIR/live/Multimedia_Feedback_List.xml|" \
  > "$MF_DIR/func.sh"
mf_patch() { # $1 = fixture file (or 'MISSING'); prints the resulting mmfeed_state
  rm -rf "$MF_DIR/asb"; mkdir -p "$MF_DIR/asb"
  if [ "$1" != 'MISSING' ]; then cp "$1" "$MF_DIR/live/Multimedia_Feedback_List.xml";
  else rm -f "$MF_DIR/live/Multimedia_Feedback_List.xml"; fi
  ( ui_print() { :; }; . "$MF_DIR/func.sh"; asb_prepare_mmfeed_patch >/dev/null )
  cat "$MF_DIR/asb/mmfeed_state" 2>/dev/null || echo missing
}
MF_PAY="$MF_DIR/asb/mmfeed_patched$MF_DIR/live/Multimedia_Feedback_List.xml"

# OP15-style: collector open -> ready, payload closed, root element intact.
cat > "$MF_DIR/caseA.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" ?>
<filter-conf>
  <version>20240507</version>
  <isOpen>true</isOpen>
  <event id="10001" diagid="090001" ison="11" desc="audio adsp crash"/>
</filter-conf>
XML
[ "$(mf_patch "$MF_DIR/caseA.xml")" = 'ready' ] || fail 'open collector not patched'
grep -q '<isOpen>false</isOpen>' "$MF_PAY" || fail 'payload did not close the collector'
grep -q '</filter-conf>' "$MF_PAY" || fail 'payload lost the root element'
grep -q 'id="10001"' "$MF_PAY" || fail 'payload lost the event table'

# Already closed -> honestly "already", no manifest.
sed 's|<isOpen>true</isOpen>|<isOpen>false</isOpen>|' "$MF_DIR/caseA.xml" > "$MF_DIR/caseB.xml"
[ "$(mf_patch "$MF_DIR/caseB.xml")" = 'already' ] || fail 'closed list not reported as already'
[ ! -f "$MF_DIR/asb/mmfeed_bind_manifest.txt" ] || fail 'closed list still wrote a manifest'

# No isOpen tag at all -> unknown format, fail-closed "invalid".
cat > "$MF_DIR/caseC.xml" <<'XML'
<filter-conf><version>1</version></filter-conf>
XML
[ "$(mf_patch "$MF_DIR/caseC.xml")" = 'invalid' ] || fail 'formatless file not reported invalid'
[ ! -f "$MF_DIR/asb/mmfeed_bind_manifest.txt" ] || fail 'invalid file still wrote a manifest'

# No file at all -> "unsupported".
[ "$(mf_patch MISSING)" = 'unsupported' ] || fail 'missing file not reported unsupported'

echo 'PASS: multimedia-telemetry contract'
