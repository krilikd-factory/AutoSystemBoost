#!/system/bin/sh
# Capability tier gate for model-specific ASB packs.
#
# Unknown devices are deliberately Tier 0: generic governor telemetry is safe,
# but vendor property mutations (domain=properties), camera/audio overlays and
# carrier changes are not applied until a pack was verified for the exact current
# build fingerprint. A validated pack may list more than one domain, one per line.

asb_device_tier_file="/data/adb/asb/device_pack_verified"

asb_device_pack_allows() {
  _domain="$1"
  [ -r "$asb_device_tier_file" ] || return 1
  _fp="$(getprop ro.build.fingerprint 2>/dev/null)"
  [ -n "$_fp" ] || return 1
  grep -Fqx "fingerprint=$_fp" "$asb_device_tier_file" 2>/dev/null || return 1
  grep -Fqx "tier=validated" "$asb_device_tier_file" 2>/dev/null || return 1
  grep -Fqx "domain=$_domain" "$asb_device_tier_file" 2>/dev/null
}

asb_device_tier_name() {
  if asb_device_pack_allows "$1"; then
    echo "validated"
  else
    echo "generic"
  fi
}
