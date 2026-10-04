#!/bin/bash
# Regression: the WebUI must be able to start a daily log again after a previous one ended or
# its folder was deleted. Three cases:
#   1. stale lock whose PID now belongs to an UNRELATED live process (PID reuse within a boot)
#      -> the lock is not ours: start must succeed, the unrelated process must be left alive;
#   2. our recorder alive, folder present -> still "already running" (no second recorder);
#   3. our recorder alive, folder deleted -> recorder AND its sampler child stopped, new start.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/runtime/asb_debug_support.sh"
TMP="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; pkill -f "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { echo "FAIL debug stale-lock: $*" >&2; exit 1; }
# Alive and not a zombie: a killed process stays visible to kill -0 until it is reaped.
alive() { [ -r "/proc/$1/stat" ] || return 1; case "$(sed 's/^.*) //' "/proc/$1/stat" | cut -c1)" in Z|X) return 1 ;; esac; return 0; }
DBG="$TMP/mod"; mkdir -p "$DBG/tools/logkit" "$DBG/runtime"
printf 'id=AutoSystemBoost\nversion=V65-debug10\nversionCode=650\n' > "$DBG/module.prop"
cat > "$DBG/tools/logkit/asb_log_full_day.sh" << 'EOF_REC'
set -u
_lock="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"; _token="${ASB_DEBUG_SUPPORT_LOCK_TOKEN:-}"
[ -d "$_lock" ] && [ "$(cat "$_lock/token")" = "$_token" ] || exit 91
printf '%s\n' "$$" > "$_lock/pid"
_out="$_lock/../capture_$$"; mkdir -p "$_out"; printf '%s\n' "$_out" > "$_lock/output_dir"
( while :; do sleep 1; done ) &          # a sampler child, as the real recorder has
echo $! > "$_lock/../child_$$"
sleep 60
EOF_REC
ENV=(ASB_DEBUG_SUPPORT_MODDIR="$DBG" ASB_DEBUG_SUPPORT_STATE_DIR="$TMP/state" ASB_DEBUG_SUPPORT_RUNLOG="$TMP/run.out")
H() { env "${ENV[@]}" sh "$HELPER" "$@" 2>/dev/null || true; }
LOCK="$TMP/state/full_day_webui.lock"
boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo boot)"

# ---- case 1: stale lock, PID reused by an unrelated live process
mkdir -p "$LOCK"; sleep 300 & OTHER=$!
printf '%s\n' "$boot" > "$LOCK/boot_id"; printf 'tok\n' > "$LOCK/token"
printf '%s\n' "$OTHER" > "$LOCK/pid"; printf '%s\n' "$OTHER" > "$LOCK/launcher"
printf '%s\n' "$TMP/deleted_capture" > "$LOCK/output_dir"
OUT="$(H full-day-start)"
echo "$OUT" | grep -q 'status=started' || fail "case 1: stale lock blocked the start: $OUT"
kill -0 "$OTHER" 2>/dev/null || fail "case 1: an unrelated process was killed"
sleep 0.6
P1="$(tr -dc 0-9 < "$LOCK/pid" 2>/dev/null)"; [ -n "$P1" ] && kill -0 "$P1" || fail "case 1: recorder not running"

# ---- case 2: our recorder alive, folder present -> already running
OUT="$(H full-day-start)"
echo "$OUT" | grep -q 'status=already_running' || fail "case 2: a second recorder was allowed: $OUT"

# ---- case 3: folder deleted -> recorder and child stopped, new recorder started
CHILD="$(cat "$TMP/state/child_$P1" 2>/dev/null)"
rm -rf "$(cat "$LOCK/output_dir")"
OUT="$(H full-day-start)"
echo "$OUT" | grep -q 'orphan_recovered=output_dir_removed' || fail "case 3: orphan not recovered: $OUT"
echo "$OUT" | grep -q 'status=started' || fail "case 3: no new start: $OUT"
sleep 0.4
alive "$P1" && fail "case 3: old recorder still alive"
[ -n "$CHILD" ] && alive "$CHILD" && fail "case 3: old sampler child still alive"
kill "$OTHER" 2>/dev/null
echo "PASS debug support stale-lock and deleted-folder recovery"
