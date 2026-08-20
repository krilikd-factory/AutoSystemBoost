#!/system/bin/sh
# Print the policy that ASB can actually justify, not just the values selected
# in the WebUI. This is deliberately read-only and safe to run while gaming.

MODID="AutoSystemBoost"
MODDIR="${MODDIR:-/data/adb/modules/$MODID}"
for _d in "$MODDIR" /data/adb/modules/$MODID /data/adb/modules_update/$MODID; do
  [ -f "$_d/module.prop" ] && { MODDIR="$_d"; break; }
done
CONF="$MODDIR/config/governor.conf"
# Overrideable only for staged installs and host contracts; production stays /data/adb/asb.
STATE="${ASB_CONFIG_STATE:-/data/adb/asb}"
RUNTIME_STATE="${ASB_RUNTIME_STATE:-/dev/.asb/state}"
# shellcheck disable=SC1091
[ -r "$MODDIR/runtime/asb_device_tier.sh" ] && . "$MODDIR/runtime/asb_device_tier.sh"

_cfg() { grep -E "^[[:space:]]*$1=" "$CONF" 2>/dev/null | head -1 | sed 's/^[^=]*=//' | tr -d ' \r'; }
_feat() { grep -E "^[[:space:]]*$1=" "$MODDIR/features.conf" 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d ' \r'; }
_state() { grep -E "^[[:space:]]*$1=" "$RUNTIME_STATE" 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d ' \r'; }
_state_text() { _state "$1" | tr -d '\"'; }
_state_num() { _sn="$(_state "$1")"; printf '%s\n' "$_sn" | grep -Eq '^-?[0-9]+$' && printf '%s' "$_sn" || printf '%s' "${2:-0}"; }
_txn() { grep -E "^[[:space:]]*$1=" "$STATE/config_last_txn" 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d ' \r'; }
_txn_num() { _tn="$(_txn "$1")"; printf '%s\n' "$_tn" | grep -Eq '^-?[0-9]+$' && printf '%s' "$_tn" || printf '%s' "${2:-0}"; }
_cap() { grep -E "^[[:space:]]*$1=" /data/adb/asb/capabilities.env 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d ' \r'; }
_lease() { grep -E "^[[:space:]]*$2=" "/dev/.asb/arbiter/$1.lease" 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d ' \r'; }
_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r' ' '; }
_read() { _rv="$(cat "$1" 2>/dev/null | tr '\n\r' ' ')"; [ -n "$_rv" ] && printf '%s' "$_rv" || printf '%s' 'unavailable'; }
_prop() { _pv="$(getprop "$1" 2>/dev/null | tr -d '\r\n')"; [ -n "$_pv" ] && printf '%s' "$_pv" || printf '%s' 'unavailable'; }
_net_result() { _nv="$(grep -E "^$1=" /data/adb/asb/net_apply_result 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d ' \r')"; [ -n "$_nv" ] && printf '%s' "$_nv" || printf '%s' 'not_applied'; }
_psi_avg10() {
  _pv="$(awk -v _kind="$1" '$1 == _kind { for (i = 1; i <= NF; i++) if ($i ~ /^avg10=/) { sub(/^avg10=/, "", $i); print $i; exit } }' /proc/pressure/memory 2>/dev/null)"
  [ -n "$_pv" ] && printf '%s' "$_pv" || printf '%s' 'unavailable'
}

[ -r "$CONF" ] || { echo '{"error":"governor.conf unavailable"}'; exit 1; }
_dups="$(awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {p=index($0,"="); if(!p)next; k=substr($0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",k); if(++seen[k]>1)n++} END{print n+0}' "$CONF")"
if [ "$_dups" = "0" ]; then _cfg_health="valid"; else _cfg_health="duplicate_keys"; fi
_prof="$(cat "$MODDIR/current_profile" 2>/dev/null)"; _prof="${_prof:-balanced}"
_sm="$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)"; _sm="${_sm:-$(_cfg smart_mode_enabled)}"
if [ "$_sm" = "1" ] || [ "$_prof" = "smart" ]; then _owner="governor_fsm"; else _owner="service_manual"; fi
if [ -r /data/adb/asb/thermal_floor ]; then
  _floor="$(tr -d ' \r' < /data/adb/asb/thermal_floor)"
else
  _floor="none"
fi
_floor="${_floor:-none}"
_camera_tier="generic"; _audio_tier="generic"; _net_tier="generic"; _overlay_tier="generic"; _properties_tier="generic"
command -v asb_device_tier_name >/dev/null 2>&1 && {
  _camera_tier="$(asb_device_tier_name camera)"; _audio_tier="$(asb_device_tier_name audio)"
  _net_tier="$(asb_device_tier_name network)"; _overlay_tier="$(asb_device_tier_name overlay)"
  _properties_tier="$(asb_device_tier_name properties)"
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
printf '"managed_properties":{"status":"%s","reason":"%s","applied":"%s","skipped":"%s"},' \
  "$(_json "$_mp_status")" "$(_json "$_mp_reason")" "$(_json "$_mp_applied")" "$(_json "$_mp_skipped")"
printf '"arbitration":{"cpu_cap_owner":"%s","uclamp_owner":"%s","camera_active":"%s"},' \
  "$(_json "$(_lease cpu_cap owner)")" "$(_json "$(_lease uclamp_max owner)")" "$(_json "$(grep -c . /dev/.asb/camera_guard 2>/dev/null || true)")"
printf '"capabilities":{"cpu_policies":"%s","opp_complete":"%s","cgroup_v1":"%s","cgroup_v2":"%s","uclamp":"%s","thermal":"%s","battery_current":"%s","gpu_devfreq":"%s"},' \
  "$(_json "$(_cap cpu_policy_count)")" "$(_json "$(_cap cpu_opp_complete)")" "$(_json "$(_cap cgroup_v1)")" "$(_json "$(_cap cgroup_v2)")" "$(_json "$(_cap uclamp)")" "$(_json "$(_cap thermal_sensors)")" "$(_json "$(_cap battery_current)")" "$(_json "$(_cap gpu_devfreq)")"
printf '"writer_health":{"attempts":"%s","applied":"%s","failures":"%s","backoff_skips":"%s","next_retry":"%s"},' \
  "$(_json "$(_state writer_attempts)")" "$(_json "$(_state writer_applied)")" "$(_json "$(_state writer_failures)")" "$(_json "$(_state writer_backoff_skips)")" "$(_json "$(_state writer_next_retry)")"
printf '"energy_policy":{"shadow_mode":"%s","thermal_budget_enabled":"%s","thermal_budget_trim_pct":"%s","thermal_budget_reason":"%s","thermal_budget_dwell_s":"%s"},' \
  "$(_json "$(_state shadow_mode)")" "$(_json "$(_state thermal_budget_enabled)")" "$(_json "$(_state thermal_budget_trim_pct)")" "$(_json "$(_state thermal_budget_reason)")" "$(_json "$(_state thermal_budget_dwell_s)")"
printf '"thermal_provenance":{"control_source":"%s","control_zone":%s,"confidence":%s,"rejected_type":"%s","rejected_raw":%s,"startup_quarantined":%s},' \
  "$(_json "$(_state_text thermal_control_source)")" "$(_state_num thermal_control_zone -1)" "$(_state_num thermal_source_confidence 0)" \
  "$(_json "$(_state_text thermal_rejected_type)")" "$(_state_num thermal_rejected_raw 0)" "$(_state_num startup_quarantined 0)"
printf '"config_last_txn":{"result_class":"%s","reason":"%s","key":"%s","pre_epoch":%s,"post_epoch":%s,"reload_accepted":"%s","recovery":"%s"},' \
  "$(_json "$(_txn result_class)")" "$(_json "$(_txn reason)")" "$(_json "$(_txn key)")" \
  "$(_txn_num pre_epoch 0)" "$(_txn_num post_epoch 0)" "$(_json "$(_txn reload_accepted)")" "$(_json "$(_txn recovery)")"
# These three blocks are intentionally observation-only. They expose whether a donor-inspired
# hypothesis is true on this device before ASB changes a route, qdisc or memory policy.
printf '"audio":{"dsp_enabled":"%s","dsp_route_published":"%s","dsp_outputs":"%s","a2dp_offload_requested":"%s","a2dp_platform_disabled":"%s","a2dp_vendor_disabled":"%s"},' \
  "$(_json "$(_prop persist.asb.dsp.enable)")" "$(_json "$(_prop persist.asb.dsp.route)")" "$(_json "$(_prop persist.asb.dsp.outputs)")" "$(_json "$(_cfg bt_a2dp_offload)")" "$(_json "$(_prop persist.bluetooth.a2dp_offload.disabled)")" "$(_json "$(_prop persist.vendor.bluetooth.a2dp_offload.disabled)")"
printf '"network":{"congestion_requested":"%s","congestion_result":"%s","congestion_live":"%s","qdisc_requested":"%s","qdisc_result":"%s","qdisc_live":"%s"},' \
  "$(_json "$(_cfg net_congestion)")" "$(_json "$(_net_result net_congestion)")" "$(_json "$(_read /proc/sys/net/ipv4/tcp_congestion_control)")" "$(_json "$(_cfg net_qdisc)")" "$(_json "$(_net_result net_qdisc)")" "$(_json "$(_read /proc/sys/net/core/default_qdisc)")"
printf '"memory":{"psi_some_avg10":"%s","psi_full_avg10":"%s","zram_algorithm":"%s","zram_disksize":"%s","zram_mm_stat":"%s"},' \
  "$(_json "$(_psi_avg10 some)")" "$(_json "$(_psi_avg10 full)")" "$(_json "$(_read /sys/block/zram0/comp_algorithm)")" "$(_json "$(_read /sys/block/zram0/disksize)")" "$(_json "$(_read /sys/block/zram0/mm_stat)")"
printf '"asb_overhead":{"event_wakeups":"%s","timer_wakeups":"%s","cpu_ms":"%s"}' \
  "$(_json "$(_state governor_event_wakeups)")" "$(_json "$(_state governor_timer_wakeups)")" "$(_json "$(_state governor_cpu_ms)")"
printf '}\n'
