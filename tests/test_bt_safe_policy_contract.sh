#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APPLY="$ROOT/runtime/asb_apply_managed_props.sh"
REC="$ROOT/tools/logkit/_asb_logkit_common.sh"
AUDIO="$ROOT/runtime/asb_audio_apply.sh"
fail() { echo "FAIL BT safe policy contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
need "$APPLY" 'enable_bt_policy'
need "$APPLY" 'disabled_default'
need "$APPLY" 'bt_policy=$_bt_policy_state'
need "$APPLY" 'resetprop --delete "$_key"'
need "$AUDIO" 'settings put global bluetooth_a2dp_offload_enabled'
need "$AUDIO" 'bluetooth_disable_absolute_volume'
need "$REC" 'LK_BT_RECONNECT_RAW'
need "$REC" 'bt_lifecycle_stack_evidence.tsv'
need "$REC" 'lk_bt_redact_addr'
need "$REC" 'reason/status/transport'
echo 'PASS BT safe policy contract'
