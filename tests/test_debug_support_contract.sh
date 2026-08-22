#!/bin/bash
# Contract: debug WebUI support actions stay debug-gated, bounded and non-overlapping.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT/runtime/asb_debug_support.sh"
UI="$ROOT/webroot/index.html"
TMP="$(mktemp -d)"
trap 'if [ -n "${REC_PID:-}" ]; then kill "$REC_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT

need() { grep -Fq -- "$2" "$1" || { echo "FAIL debug support: missing [$2]" >&2; exit 1; }; }
count_exact() {
  _actual="$(grep -Foc -- "$2" "$1" 2>/dev/null || true)"
  [ "$_actual" -eq "$3" ] || { echo "FAIL debug support: expected $3 [$2], found $_actual" >&2; exit 1; }
}
[ -f "$HELPER" ] || { echo "FAIL debug support: helper missing" >&2; exit 1; }
sh -n "$HELPER"

# A release module must refuse both mutations even if someone manufactures a DOM click.
REL="$TMP/release"; mkdir -p "$REL"
printf 'id=AutoSystemBoost\nversion=V64\n' > "$REL/module.prop"
REL_OUT="$(ASB_DEBUG_SUPPORT_MODDIR="$REL" ASB_DEBUG_SUPPORT_STATE_DIR="$TMP/state" sh "$HELPER" full-day || true)"
printf '%s\n' "$REL_OUT" | grep -Fq 'error=debug_only' || {
  echo 'FAIL debug support: release gate did not refuse recorder' >&2; exit 1
}

# A debug module gets a mocked diagnostic and recorder. The recorder reproduces the real
# ownership protocol: it claims the tokenized directory with ITS OWN PID and only removes
# a guard that still names that PID. This catches launcher-PID and cleanup races on host.
DBG="$TMP/debug"; mkdir -p "$DBG/system/bin" "$DBG/tools/logkit" "$TMP/out"
printf 'id=AutoSystemBoost\nversion=V64-debug3\n' > "$DBG/module.prop"
printf '#!/bin/sh\necho diagnostic-ok\n' > "$DBG/system/bin/asbdiag"; chmod 0755 "$DBG/system/bin/asbdiag"
cat > "$DBG/tools/logkit/asb_log_full_day.sh" <<'EOF_RECORDER'
#!/bin/sh
set -u
_lock="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"
_token="${ASB_DEBUG_SUPPORT_LOCK_TOKEN:-}"
[ -n "$_lock" ] && [ -d "$_lock" ] || exit 91
[ "$(cat "$_lock/token" 2>/dev/null || true)" = "$_token" ] || exit 92
printf '%s\n' "$$" > "$_lock/pid.tmp.$$" || exit 93
mv -f "$_lock/pid.tmp.$$" "$_lock/pid" || exit 94
cleanup() {
  _pid="$(tr -dc '0-9' < "$_lock/pid" 2>/dev/null || true)"
  [ "$_pid" = "$$" ] && rm -rf "$_lock" 2>/dev/null || true
}
trap 'cleanup; exit 0' TERM INT HUP
sleep 30
cleanup
EOF_RECORDER
chmod 0755 "$DBG/tools/logkit/asb_log_full_day.sh"
ENV=(ASB_DEBUG_SUPPORT_MODDIR="$DBG" ASB_DEBUG_SUPPORT_STATE_DIR="$TMP/state" ASB_DEBUG_SUPPORT_RUNLOG="$TMP/full_day.out" ASB_DEBUG_SUPPORT_DIAG_OUTDIR="$TMP/out")
DIAG_OUT="$(env "${ENV[@]}" sh "$HELPER" diag)"
echo "$DIAG_OUT" | grep -Fq 'status=saved'
DIAG_PATH="$(printf '%s\n' "$DIAG_OUT" | sed -n 's/^path=//p')"
[ -f "$DIAG_PATH" ] && grep -Fq 'diagnostic-ok' "$DIAG_PATH" || { echo 'FAIL debug support: diag export' >&2; exit 1; }
START1="$(env "${ENV[@]}" sh "$HELPER" full-day)"
echo "$START1" | grep -Fq 'status=started'
REC_PID="$(printf '%s\n' "$START1" | sed -n 's/^pid=//p')"
[ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null || { echo 'FAIL debug support: recorder did not stay alive' >&2; exit 1; }
START2="$(env "${ENV[@]}" sh "$HELPER" full-day)"
echo "$START2" | grep -Fq 'status=already_running'
echo "$START2" | grep -Fq "pid=$REC_PID"

# Repeat simultaneous starts from a clean state. One and only one recorder may be created in
# every round; the losing request must publish the winner PID rather than relying on a
# short-lived helper process or a removable empty PID file.
for round in $(seq 1 12); do
  kill -KILL "$REC_PID" 2>/dev/null || true
  wait "$REC_PID" 2>/dev/null || true
  REC_PID=""
  rm -rf "$TMP/state/full_day_webui.lock"
  rm -f "$TMP/state/full_day_webui.pid"
  env "${ENV[@]}" sh "$HELPER" full-day > "$TMP/concurrent_${round}_a.out" & C1=$!
  env "${ENV[@]}" sh "$HELPER" full-day > "$TMP/concurrent_${round}_b.out" & C2=$!
  wait "$C1"; wait "$C2"
  CONCURRENT="$(cat "$TMP/concurrent_${round}_a.out" "$TMP/concurrent_${round}_b.out")"
  [ "$(printf '%s\n' "$CONCURRENT" | grep -c '^status=started$')" -eq 1 ] || { echo "FAIL debug support: concurrent start count round=$round" >&2; exit 1; }
  printf '%s\n' "$CONCURRENT" | grep -Fq 'status=already_running' || { echo "FAIL debug support: concurrent guard did not report running round=$round" >&2; exit 1; }
  REC_PID="$(printf '%s\n' "$CONCURRENT" | sed -n 's/^pid=//p' | grep -E '^[0-9]+$' | head -n 1)"
  [ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null || { echo "FAIL debug support: concurrent recorder missing round=$round" >&2; exit 1; }
  printf '%s\n' "$CONCURRENT" | grep -Fq "pid=$REC_PID" || { echo "FAIL debug support: loser did not observe winner PID round=$round" >&2; exit 1; }
done

# A killed recorder leaves a known-dead PID. The next action may reclaim only that stale lock.
kill -KILL "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
STALE="$(env "${ENV[@]}" sh "$HELPER" full-day)"
echo "$STALE" | grep -Fq 'status=started' || { echo 'FAIL debug support: known-dead lock not reclaimed' >&2; exit 1; }
REC_PID="$(printf '%s\n' "$STALE" | sed -n 's/^pid=//p')"

# The helper accepts a fixed enum only; it has no eval/source/untrusted command interpolation.
need "$HELPER" "case \"\${1:-status}\" in"
need "$HELPER" 'mkdir "$LOCKDIR"'
need "$HELPER" 'lock_known_dead()'
need "$HELPER" 'lock_wait_live_pid()'
need "$HELPER" 'ASB_DEBUG_SUPPORT_LOCKDIR="$LOCKDIR"'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'LK_WEBUI_LOCKDIR="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_claim()'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_claim || { echo '\''[debug-webui] guard claim failed'\''; exit 2; }'
need "$ROOT/tools/logkit/asb_log_full_day.sh" "trap 'lk_finalize; lk_webui_guard_release; exit 0' TERM INT HUP"
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_release'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'FULL-DAY capture complete. Output: $LK_OUT_DIR'
# Debug capture must expose a resolvable AudioMix owner and the evidence that made
# a media-like workload game-like, without putting any package-manager polling in
# the native governor. The logkit helpers are passive and use one capture-start map.
COMMON="$ROOT/tools/logkit/_asb_logkit_common.sh"
need "$COMMON" 'lk_audio_wakelock_attribution_init()'
need "$COMMON" 'audio_wakelock_attribution.tsv'
need "$COMMON" 'lk_fsm_media_trace_header()'
need "$COMMON" 'fsm_media_trace.tsv'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_audio_wakelock_attribution_init'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_capture_fsm_media_trace_row "$_phase"'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'rmnetMiB'
need "$ROOT/src/asb_governor.c" 'asb_smart_media_guard_observe'
need "$ROOT/src/asb_governor.c" 'no_fresh_known_media_pkg'
need "$ROOT/src/asb_governor.c" 'ASB_SMART_MEDIA_GUARD_GPU_MAX_PCT = 70'
need "$ROOT/src/asb_smart.h" 'asb_smart_pkg_is_media_candidate'
if grep -nE '\beval\b|\bsource\b|/system/bin/sh -c|sh -c' "$HELPER" >/dev/null; then
  echo 'FAIL debug support: helper accepts unsafe shell execution' >&2; exit 1
fi
# Every one of Profile, Monitor and Settings gets one support wrapper. A debug build
# swaps its single release Telegram link for exactly one no-wrap, three-control rail.
count_exact "$UI" '<div class="footer-support-row" data-debug-support-row hidden>' 3
count_exact "$UI" '<a class="tg-link" data-release-telegram' 3
count_exact "$UI" '<a class="tg-link" data-debug-telegram' 3
count_exact "$UI" "asbDebugAction('diag')" 3
count_exact "$UI" "asbDebugAction('full-day')" 3
count_exact "$UI" '<span class="tg-link-ico">✉️</span>' 6
need "$UI" '.footer-support-row .tg-link-ico { font-size: 14px; }'
need "$UI" 'background: linear-gradient(135deg, rgba(0,240,180,0.08), rgba(0,212,255,0.05));'
need "$UI" 'height: 40px;'
need "$UI" 'flex-wrap: nowrap;'
need "$UI" '[data-release-telegram][hidden] { display: none !important; }'
need "$UI" 'runtime/asb_debug_support.sh'
need "$UI" 'loadDebugSupport()'
need "$UI" '/-debug[1-9][0-9]*$/i'
# asbdiag can spend seconds writing its export. A persistent modal must open before
# the root bridge await, stay while the pulse is active, and close only in finally.
need "$UI" 'id="debugActionWait"'
need "$UI" 'debug-action-wait-sheet'
need "$UI" 'debugDiagPulse .38s'
need "$UI" 'debugActionWaitOpen(action);'
need "$UI" 'debugActionWaitClose();'
awk '
  /async function asbDebugAction\(action\)/ { in_fn=1 }
  in_fn && /debugActionWaitOpen\(action\)/ { opened=NR }
  in_fn && /await run\(/ && !awaited { awaited=NR }
  in_fn && /finally \{/ { in_final=1 }
  in_final && /debugActionWaitClose\(\)/ { closed=1 }
  in_fn && /^}/ { if (opened && awaited && opened < awaited && closed) ok=1; in_fn=0 }
  END { if (!ok) { print "FAIL debug support: wait modal lifecycle is not open-before-await / close-in-finally" > "/dev/stderr"; exit 1 } }
' "$UI"
awk '
  /<div class="footer-support-row" data-debug-support-row hidden>/ { inrow=1; seq=""; next }
  inrow && /asbDebugAction\('\''diag'\''\)/ { seq=seq "D" }
  inrow && /data-debug-telegram/ { seq=seq "T" }
  inrow && /asbDebugAction\('\''full-day'\''\)/ { seq=seq "L" }
  inrow && /<\/div>/ { if (seq != "DTL") { printf "FAIL debug support: expected DTL rail order, got %s\\n", seq > "/dev/stderr"; exit 1 }; rails++; inrow=0 }
  END { if (rails != 3) { printf "FAIL debug support: checked %d central rails\\n", rails > "/dev/stderr"; exit 1 } }
' "$UI"
for locale in "$ROOT"/webroot/i18n/*.json; do
  need "$locale" '"dbg_diag_btn": "asbdiag"'
  need "$locale" '"dbg_log_btn": "24h log"'
  need "$locale" '"dbg_log_failed"'
done

echo 'PASS debug support WebUI/helper contract'
