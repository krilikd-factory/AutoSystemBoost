#!/system/bin/sh

set -u
LK_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
. "$LK_SCRIPT_DIR/_asb_logkit_common.sh"

LK_SCENARIO="bgtrim_snapshot"
LK_OUT_DIR="$(lk_resolve_outbase)/asb_log_${LK_SCENARIO}_$$"

trap 'lk_finalize; exit 0' INT TERM HUP EXIT

lk_init
echo "[$(date '+%H:%M:%S')] capturing BG_TRIM state snapshot..."
lk_snapshot_state "bgtrim"
echo "[$(date '+%H:%M:%S')] copying runtime artifacts..."
lk_copy_runtime_artifacts
echo "[$(date '+%H:%M:%S')] done. Output: $LK_OUT_DIR"
