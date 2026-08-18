#!/system/bin/sh
# Print the policy that ASB can actually justify, not just the values selected
# in the WebUI. This is deliberately read-only and safe to run while gaming.

MODID="AutoSystemBoost"
MODDIR="${MODDIR:-/data/adb/modules/$MODID}"
for _d in "$MODDIR" /data/adb/modules/$MODID /data/adb/modules_update/$MODID; do
  [ -f "$_d/module.prop" ] && { MODDIR="$_d"; break; }
done
CONF="$MODDIR/config/governor.conf"
[ -r "$MODDIR/runtime/asb_device_tier.sh" ] && . "$MODDIR/runtime/asb_device_tier.sh"

_cfg() { grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d ' \r'; }
_feat() { grep -E "^[[:space:]]*$1=" "$MODDIR/features.conf" 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d ' \r'; }
_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

[ -r "$CONF" ] || { echo '{"error":"governor.conf unavailable"}'; exit 1; }
_dups="$(awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {p=index($0,"="); if(!p)next; k=substr($0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",k); if(++seen[k]>1)n++} END{print n+0}' "$CONF")"
if [ "$_dups" = "0" ]; then _cfg_health="valid"; else _cfg_health="duplicate_keys"; fi
_prof="$(cat "$MODDIR/current_profile" 2>/dev/null)"; _prof="${_prof:-balanced}"
_sm="$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)"; _sm="${_sm:-$(_cfg smart_mode_enabled)}"
if [ "$_sm" = "1" ] || [ "$_prof" = "smart" ]; then _owner="governor_fsm"; else _owner="service_manual"; fi
_floor="$(cat /data/adb/asb/thermal_floor 2>/dev/null | tr -d ' \r')"; _floor="${_floor:-none}"
_camera_tier="generic"; _audio_tier="generic"; _net_tier="generic"; _overlay_tier="generic"; _properties_tier="generic"
command -v asb_device_tier_name >/dev/null 2>&1 && {
  _camera_tier="$(asb_device_tier_name camera)"; _audio_tier="$(asb_device_tier_name audio)";
  _net_tier="$(asb_device_tier_name network)"; _overlay_tier="$(asb_device_tier_name overlay)";
  _properties_tier="$(asb_device_tier_name properties)";
}
_mp_state="/data/adb/asb/managed_props.state"
_mp_status="not_run"; _mp_reason="state_unavailable"; _mp_applied="0"; _mp_skipped="0"
if [ -r "$_mp_state" ]; then
  _mp_status="$(grep -E '^status=' "$_mp_state" 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d ' \r')"
  _mp_reason="$(grep -E '^reason=' "$_mp_state" 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d ' \r')"
  _mp_applied="$(grep -E '^applied=' "$_mp_state" 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d ' \r')"
  _mp_skipped="$(grep -E '^skipped=' "$_mp_state" 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d ' \r')"
fi
printf '{'
printf '"config_health":"%s","duplicate_key_count":%s,' "$(_json "$_cfg_health")" "$_dups"
printf '"profile":{"requested":"%s","smart_enabled":"%s","cap_owner":"%s"},' "$(_json "$_prof")" "$(_json "$_sm")" "$(_json "$_owner")"
printf '"thermal":{"sustained_enter_requested":"%s","runtime_floor":"%s"},' "$(_json "$(_cfg sustained_temp_enter)")" "$(_json "$_floor")"
printf '"features":{"camera":"%s","bt":"%s","net":"%s","kernel":"%s","log":"%s","vendor_overlay":"%s"},' \
  "$(_json "$(_feat CAMERA)")" "$(_json "$(_feat BT)")" "$(_json "$(_feat NET)")" "$(_json "$(_feat KERNEL)")" "$(_json "$(_feat LOG)")" "$(_json "$(_feat VENDOR_OVERLAY)")"
printf '"tiers":{"camera":"%s","audio":"%s","network":"%s","overlay":"%s","properties":"%s"},' \
  "$(_json "$_camera_tier")" "$(_json "$_audio_tier")" "$(_json "$_net_tier")" "$(_json "$_overlay_tier")" "$(_json "$_properties_tier")"
printf '"managed_properties":{"status":"%s","reason":"%s","applied":"%s","skipped":"%s"}' \
  "$(_json "$_mp_status")" "$(_json "$_mp_reason")" "$(_json "$_mp_applied")" "$(_json "$_mp_skipped")"
printf '}\n'
