#!/usr/bin/env sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Device-pack producer must make absence explicit without authorizing broad
# properties by device model/fingerprint guesswork.
mkdir -p "$TMP/bin" "$TMP/state"
cat > "$TMP/bin/getprop" <<'EOF'
#!/usr/bin/env sh
[ "${1:-}" = "ro.build.fingerprint" ] && printf '%s\n' 'test/vendor/device:16/TEST/1:user/release-keys'
EOF
chmod 0755 "$TMP/bin/getprop"
PATH="$TMP/bin:$PATH" ASB_CONFIG_STATE="$TMP/state" MODDIR="$ROOT" \
  sh "$ROOT/runtime/asb_device_pack_manifest.sh"
grep -qx 'status=blocked' "$TMP/state/device_pack.state"
grep -qx 'reason=no_certified_domain_manifest' "$TMP/state/device_pack.state"
test ! -e "$TMP/state/device_pack_verified"

# A stale validated manifest must be invalidated rather than authorizing another OTA.
cat > "$TMP/state/device_pack_verified" <<'EOF'
fingerprint=other/vendor/device:16/OLD/1:user/release-keys
tier=validated
domain=properties
EOF
PATH="$TMP/bin:$PATH" ASB_CONFIG_STATE="$TMP/state" MODDIR="$ROOT" \
  sh "$ROOT/runtime/asb_device_pack_manifest.sh"
test ! -e "$TMP/state/device_pack_verified"

# Profile switches are transactional: each request obtains an epoch and workers
# serialise through a module lock while observing supersession between passes.
grep -q '^profile_next_epoch()' "$ROOT/apply_profile.sh"
grep -q '^profile_worker_lock()' "$ROOT/apply_profile.sh"
grep -q 'worker superseded' "$ROOT/apply_profile.sh"
grep -q 'WORKER_EPOCH="${4:-}"' "$ROOT/apply_profile.sh"

# Device evidence showed an invalid WALT sentinel and external CPU policy
# disagreement. Both must be classified and bounded, not retried aggressively.
grep -q 'unsupported_readback' "$ROOT/src/asb_writer.h"
grep -q 'external_policy_holddown' "$ROOT/src/asb_writer.h"
grep -q 'consecutive_failures' "$ROOT/src/asb_writer.h"
grep -q 'retry_at = now + 86400' "$ROOT/src/asb_writer.h"
grep -q 'retry_at = now + 900' "$ROOT/src/asb_writer.h"
! grep -q 'asb_settings_put global google_core_control 0' "$ROOT/runtime/profile_core.sh"

# Diagnostics must expose the safely blocked property state and the DSP clamp.
grep -q 'device-pack state' "$ROOT/tools/asb_diag.sh"
grep -q 'managed properties' "$ROOT/tools/asb_diag.sh"
grep -q 'DSP gain applied' "$ROOT/tools/asb_diag.sh"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag"
printf '%s\n' 'PASS device safety contract'
