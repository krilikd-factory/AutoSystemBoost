#!/usr/bin/env bash
# Contract: ASB never pretends to accelerate a full reboot. Quick restart must choose only
# a ROM-supported userspace reboot; it must not kill processes directly, persist boot
# properties, restart Zygote as an unsupported shortcut, or turn a refused request into a generic reboot.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT/runtime/asb_quick_restart.sh"
UI="$ROOT/webroot/index.html"
INSTALL="$ROOT/common/install.sh"
SERVICE="$ROOT/service.sh"
fail() { echo "FAIL quick restart contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
absent() { ! grep -Fq "$2" "$1" || fail "unexpected [$2] in $1"; }
[ -f "$HELPER" ] || fail 'quick restart helper missing'

need "$HELPER" 'init.userspace_reboot.is_supported'
need "$HELPER" 'svc power reboot userspace'
need "$HELPER" 'sys.boot_completed'
absent "$HELPER" 'killall'
absent "$HELPER" 'ctl.restart zygote'
absent "$HELPER" 'sys.powerctl'
absent "$HELPER" 'persist.'
need "$UI" "const ASB_QUICK_RESTART = MD + '/runtime/asb_quick_restart.sh';"
need "$UI" "sh ' + shQuote(ASB_QUICK_RESTART) + ' status'"
need "$UI" "sh ' + shQuote(ASB_QUICK_RESTART) + ' restart'"
absent "$UI" 'setprop ctl.restart zygote 2>/dev/null || killall zygote'
need "$UI" 't_quick_explain'
need "$UI" 't_quick_unavailable'
need "$INSTALL" 'asb_quick_restart.sh'

# Applied user tweaks may use PackageManager/framework or cmd -w networking. They must not
# synchronously occupy the userspace-reboot startup path: service returns first, then a bounded
# post-boot worker reapplies them after boot_complete plus a settle window.
need "$SERVICE" 'post_boot_tweaks: begin'
need "$SERVICE" 'post_boot_tweaks: complete'
need "$SERVICE" 'post_boot_tweaks: skipped (boot completion timeout)'
need "$SERVICE" 'sleep 2'
_pb_line="$(grep -nF 'post_boot_tweaks: begin' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_pb_line" ] || fail 'post-boot stage marker missing'
for _helper in asb_gms_freeze.sh asb_gms_trim.sh asb_system_tweaks.sh asb_athena_apply.sh asb_net_offload.sh asb_doze_apply.sh asb_net_apply.sh; do
  _call_line="$(grep -nF "sh \"\$MODDIR/runtime/$_helper\"" "$SERVICE" | head -1 | cut -d: -f1)"
  [ -n "$_call_line" ] && [ "$_call_line" -gt "$_pb_line" ] || fail "$_helper is not deferred after boot completion"
done

# Aggressive BG_TRIM reaches PackageManager, app-standby buckets, cgroup UID lookups and
# vendor services. It previously ran before boot-completed and is therefore a plausible
# contributor to the measured 48-second OP15 service interval. Preserve its policy but run it
# only from the detached worker, after the same lifecycle gate as other framework work.
absent "$SERVICE" 'asb_feature_enabled BG_TRIM && apply_bg_trim_runtime'
_bg_line="$(grep -nF '    apply_bg_trim_runtime' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_bg_line" ] && [ "$_bg_line" -gt "$_pb_line" ] || fail 'BG_TRIM is not deferred after boot completion'
need "$SERVICE" 'asb_timeline_mark service_maintenance_complete'
need "$SERVICE" 'asb_timeline_mark service_cpu_deferred'
need "$SERVICE" 'asb_timeline_mark service_vm_deferred'
need "$SERVICE" 'asb_timeline_mark service_network_complete'
need "$SERVICE" 'asb_timeline_mark service_connectivity_complete'
need "$SERVICE" 'asb_timeline_mark service_media_kernel_deferred'
need "$SERVICE" 'asb_timeline_mark service_runtime_kernel_memory_deferred'
need "$SERVICE" 'asb_timeline_mark service_runtime_core_deferred'
need "$SERVICE" 'asb_timeline_mark service_dispatched'
# The first UI must not wait for cgroup readiness/retries, direct profile caps,
# VM/kernel/DSP/ZRAM writes or WALT delayed reassertion. Stock/vendor policy is
# retained until the lifecycle-gated core worker applies the same ASB policy.
absent "$SERVICE" 'wait_path /dev/cpuset/background/cpus 8'
absent "$SERVICE" 'wait_path /dev/cpuctl/top-app 8'
absent "$SERVICE" '( sleep 5; asb_load_profile; apply_walt_boost; apply_walt_live )'
need "$SERVICE" 'asb_timeline_mark post_boot_core_policy_begin'
need "$SERVICE" 'asb_timeline_mark post_boot_core_policy_complete'
need "$SERVICE" 'asb_apply_deferred_core_boot() {'
_core_def_line="$(grep -nF 'asb_apply_deferred_core_boot() {' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_core_def_line" ] || fail 'deferred core definition missing'
# `apply_runtime_profile_now` remains a callable manual profile-switch helper and is
# intentionally defined before this function. Its body is not an initial boot call.
# Guard actual initial-path scheduling by requiring the explicit deferred markers and
# forbidding the previous direct early invocations/settle task below.
absent "$SERVICE" 'asb_feature_enabled CPU && apply_cpugov_hints'
absent "$SERVICE" 'asb_timeline_mark service_cpu_complete'
absent "$SERVICE" 'asb_timeline_mark service_vm_complete'
absent "$SERVICE" 'asb_timeline_mark service_media_kernel_complete'
absent "$SERVICE" 'asb_timeline_mark service_runtime_kernel_memory_complete'
_core_line="$(grep -nF 'asb_timeline_mark post_boot_core_policy_begin' "$SERVICE" | head -1 | cut -d: -f1)"
_core_call_line="$(grep -nF '  asb_apply_deferred_core_boot' "$SERVICE" | tail -1 | cut -d: -f1)"
[ -n "$_core_line" ] && [ -n "$_core_call_line" ] && [ "$_core_call_line" -gt "$_core_line" ] && [ "$_core_line" -gt "$_pb_line" ] || fail 'deferred core policy is not boot-complete gated'
need "$SERVICE" 'asb_timeline_mark post_boot_bgtrim_begin'
need "$SERVICE" 'asb_timeline_mark post_boot_bgtrim_complete'
need "$SERVICE" 'ASB_TIMELINE_DEBUG=0'
need "$SERVICE" 'case "$_asb_timeline_seq" in *[!0-9]*) ;; *) ASB_TIMELINE_DEBUG=1 ;; esac'

# Wi-Fi readiness can wait for wlan0/operstate (10 + 15 seconds), with a separate link
# reassertion that can wait longer. The OP15 timeline measured 19 seconds in that stage before
# boot completion, so all initial Wi-Fi/GPS/qdisc actions must be owned by post-boot worker.
need "$SERVICE" 'asb_timeline_mark post_boot_connectivity_begin'
need "$SERVICE" 'asb_timeline_mark post_boot_connectivity_complete'
_conn_line="$(grep -nF 'asb_timeline_mark post_boot_connectivity_begin' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_conn_line" ] && [ "$_conn_line" -gt "$_pb_line" ] || fail 'post-boot connectivity marker is not lifecycle-gated'
for _connect_call in \
  '    asb_wifi_cc_heal' \
  '    apply_wifi_settings' \
  '    apply_wifi_country' \
  '    apply_wlan0_txqlen' \
  '    apply_wlan0_qdisc' \
  '    apply_wifi_pm' \
  '    apply_wifi_dtim' \
  '    apply_mobile_qdisc' \
  '    apply_net_steering' \
  '  asb_feature_enabled GPS && apply_gps_hygiene' \
  '    ( asb_wifi_link_reassert ) >/dev/null 2>&1 &'; do
  _connect_line="$(grep -nF "$_connect_call" "$SERVICE" | head -1 | cut -d: -f1)"
  [ -n "$_connect_line" ] && [ "$_connect_line" -gt "$_conn_line" ] || fail "connectivity call not deferred: $_connect_call"
done
need "$SERVICE" 'asb_wifi_link_reassert() {'
need "$SERVICE" 'never launched during the init/service startup path'

# Runtime framework operations are distinct from early kernel/ZRAM writes. On the OP15 they
# occupied the residual 11-second runtime segment, so settings, DeviceIdle, tracking and
# nonessential-service operations must execute only in the post-boot worker.
need "$SERVICE" 'asb_timeline_mark service_runtime_kernel_memory_deferred'
need "$SERVICE" 'asb_timeline_mark service_runtime_framework_deferred'
need "$SERVICE" 'asb_timeline_mark post_boot_runtime_framework_begin'
need "$SERVICE" 'asb_timeline_mark post_boot_runtime_framework_complete'
_runtime_line="$(grep -nF 'asb_timeline_mark post_boot_runtime_framework_begin' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_runtime_line" ] && [ "$_runtime_line" -gt "$_conn_line" ] || fail 'runtime framework marker is not post-boot'
for _runtime_call in \
  '    apply_bt_settings' \
  '    apply_bt_codec_policy' \
  '    apply_bt_volume_behavior' \
  '    apply_bt_audio_hygiene' \
  '  asb_feature_enabled LOG && apply_tracking_block' \
  '  asb_feature_enabled VM && apply_doze' \
  '  asb_feature_enabled VM && apply_network_stats_poll' \
  '  apply_extra_settings' \
  '  asb_stop_nonessential_services'; do
  # `apply_runtime_profile_now` deliberately retains a callable runtime Doze apply for
  # manual profile changes after boot. Select the last occurrence, which is the boot worker
  # invocation guarded by post_boot_runtime_framework_begin.
  _runtime_call_line="$(grep -nF "$_runtime_call" "$SERVICE" | tail -1 | cut -d: -f1)"
  [ -n "$_runtime_call_line" ] && [ "$_runtime_call_line" -gt "$_runtime_line" ] || fail "runtime framework call not deferred: $_runtime_call"
done
absent "$SERVICE" 'asb_feature_enabled BT && apply_bt_settings'
absent "$SERVICE" 'asb_feature_enabled BT && apply_bt_codec_policy'
absent "$SERVICE" 'asb_feature_enabled BT && apply_bt_volume_behavior'
absent "$SERVICE" 'asb_feature_enabled BT && apply_bt_audio_hygiene'
need "$SERVICE" 'asb_stop_nonessential_services() {'

python3 - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
keys = {'t_quick_explain','t_quick_confirm','t_quick_going','t_quick_unavailable'}
root = Path(sys.argv[1]) / 'webroot' / 'i18n'
files = sorted(root.glob('*.json'))
assert len(files) == 13, f'expected 13 locale files, got {len(files)}'
for path in files:
    data = json.loads(path.read_text(encoding='utf-8'))
    missing = sorted(k for k in keys if not isinstance(data.get(k), str) or not data[k].strip())
    assert not missing, f'{path.name}: missing {missing}'
print('PASS quick restart locale keys: 13 locales')
PY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin"
cat > "$TMP/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  sys.boot_completed) printf '%s\n' "${ASB_TEST_BOOT:-1}" ;;
  init.userspace_reboot.is_supported) printf '%s\n' "${ASB_TEST_USERSPACE:-0}" ;;
  *) printf '\n' ;;
esac
EOF
cat > "$TMP/bin/svc" <<'EOF'
#!/bin/sh
printf 'svc:%s\n' "$*" >> "$ASB_TEST_LOG"
exit "${ASB_TEST_SVC_RC:-0}"
EOF
cat > "$TMP/bin/setprop" <<'EOF'
#!/bin/sh
printf 'setprop:%s\n' "$*" >> "$ASB_TEST_LOG"
exit "${ASB_TEST_SETPROP_RC:-0}"
EOF
chmod 0755 "$TMP/bin/getprop" "$TMP/bin/svc" "$TMP/bin/setprop"

run_helper() {
  PATH="$TMP/bin:$PATH" \
  ASB_TEST_LOG="$TMP/calls.log" \
  ASB_TEST_BOOT="${1:-1}" \
  ASB_TEST_USERSPACE="${2:-0}" \
  sh "$HELPER" "${3:-status}"
}

out="$(run_helper 1 1 status)"
[ "$out" = 'mode=userspace reason=init_supported' ] || fail "userspace status: $out"
: > "$TMP/calls.log"
out="$(run_helper 1 1 restart)"
[ "$out" = $'mode=userspace reason=init_supported\nrequested=userspace' ] || fail "userspace restart: $out"
grep -qx 'svc:power reboot userspace' "$TMP/calls.log" || fail 'userspace request not issued exactly once'
! grep -q '^setprop:' "$TMP/calls.log" || fail 'userspace path must not restart zygote'

: > "$TMP/calls.log"
if run_helper 1 0 status >/tmp/asb_quick_restart_nosupport.out 2>&1; then
  fail 'quick restart accepted without init userspace capability'
else
  rc=$?
  [ "$rc" -eq 3 ] || fail "userspace-not-supported exit=$rc"
fi
grep -qx 'mode=unavailable reason=userspace_not_supported' /tmp/asb_quick_restart_nosupport.out || fail 'userspace-not-supported verdict missing'
[ ! -s "$TMP/calls.log" ] || fail 'unsupported path issued a restart command'

: > "$TMP/calls.log"
if run_helper 0 1 status >/tmp/asb_quick_restart_unavailable.out 2>&1; then
  fail 'quick restart accepted before boot complete'
else
  rc=$?
  [ "$rc" -eq 3 ] || fail "boot-not-complete exit=$rc"
fi
grep -qx 'mode=unavailable reason=boot_not_completed' /tmp/asb_quick_restart_unavailable.out || fail 'boot-not-complete verdict missing'
[ ! -s "$TMP/calls.log" ] || fail 'unavailable path issued a restart command'

rm -f /tmp/asb_quick_restart_unavailable.out /tmp/asb_quick_restart_nosupport.out

echo 'PASS quick restart capability and no-destructive-fallback contract'
