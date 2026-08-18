#!/system/bin/sh
# Device-pack verification state producer.
#
# Vendor properties remain blocked by default. This producer exists to make the
# decision explicit, invalidate stale fingerprints, and preserve a separately
# provisioned validated manifest only when it exactly matches the active ROM.
MODID="AutoSystemBoost"
MODDIR="${MODDIR:-/data/adb/modules/$MODID}"
STATE_DIR="${ASB_CONFIG_STATE:-/data/adb/asb}"
MANIFEST="$STATE_DIR/device_pack_verified"
STATE="$STATE_DIR/device_pack.state"

_asb_atomic_state() {
  _target="$1"; shift
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  _tmp="${_target}.tmp.$$"
  {
    printf '%s\n' "$@"
  } > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_target" 2>/dev/null
}

_asb_fp="$(getprop ro.build.fingerprint 2>/dev/null)"
[ -n "$_asb_fp" ] || _asb_fp="unavailable"
_asb_existing_fp="$(grep -E '^fingerprint=' "$MANIFEST" 2>/dev/null | head -1 | sed 's/^fingerprint=//')"
_asb_existing_tier="$(grep -E '^tier=' "$MANIFEST" 2>/dev/null | head -1 | sed 's/^tier=//')"

# A manifest from another OTA must never authorize the current build.
if [ -n "$_asb_existing_fp" ] && [ "$_asb_existing_fp" != "$_asb_fp" ]; then
  rm -f "$MANIFEST" 2>/dev/null
  _asb_existing_tier=""
fi

if [ "$_asb_existing_tier" = "validated" ] \
   && grep -Fqx "fingerprint=$_asb_fp" "$MANIFEST" 2>/dev/null; then
  _asb_atomic_state "$STATE" \
    "status=validated" \
    "reason=exact_fingerprint_manifest" \
    "fingerprint=$_asb_fp" \
    "timestamp=$(date +%s 2>/dev/null || echo 0)"
  exit 0
fi

# Do not manufacture a validated properties domain from model/codename alone.
# Compatibility has to be explicitly certified per fingerprint and per domain.
_asb_atomic_state "$STATE" \
  "status=blocked" \
  "reason=no_certified_domain_manifest" \
  "fingerprint=$_asb_fp" \
  "timestamp=$(date +%s 2>/dev/null || echo 0)"
exit 0
