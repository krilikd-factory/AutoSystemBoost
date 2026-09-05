#!/bin/bash
# Contract: debug WebUI support actions stay debug-gated, bounded and non-overlapping.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT/runtime/asb_debug_support.sh"
TIMELINE="$ROOT/runtime/asb_boot_timeline.sh"
DIAG="$ROOT/tools/asb_diag.sh"
INSTALLED_DIAG="$ROOT/system/bin/asbdiag"
UI="$ROOT/webroot/index.html"
TMP="$(mktemp -d)"
trap 'if [ -n "${REC_PID:-}" ]; then kill "$REC_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT

need() { grep -Fq -- "$2" "$1" || { echo "FAIL debug support: missing [$2]" >&2; exit 1; }; }
count_exact() {
  _actual="$(grep -Foc -- "$2" "$1" 2>/dev/null || true)"
  [ "$_actual" -eq "$3" ] || { echo "FAIL debug support: expected $3 [$2], found $_actual" >&2; exit 1; }
}
[ -f "$HELPER" ] || { echo "FAIL debug support: helper missing" >&2; exit 1; }
[ -f "$TIMELINE" ] || { echo "FAIL debug support: boot timeline helper missing" >&2; exit 1; }
[ -f "$DIAG" ] && [ -f "$INSTALLED_DIAG" ] || { echo "FAIL debug support: asbdiag copy missing" >&2; exit 1; }
sh -n "$HELPER"
sh -n "$TIMELINE"
cmp -s "$DIAG" "$INSTALLED_DIAG" || { echo "FAIL debug support: asbdiag copies diverged" >&2; exit 1; }
need "$DIAG" 'BOOT TIMELINE'
need "$DIAG" 'boot_timeline.tsv'

# Execute the actual asbdiag version gate fragment. A prior shell glob used
# [1-9][0-9]*, which requires two digits and therefore hid timeline evidence on
# V64-debug4 even though the recorder had correctly created it.
awk '
  /^_boot_debug=0$/ { capture=1 }
  capture && /^if \[ "\$_boot_debug" = "1" \]; then$/ { exit }
  capture { print }
' "$DIAG" > "$TMP/asbdiag_boot_gate.sh"
[ -s "$TMP/asbdiag_boot_gate.sh" ] || { echo 'FAIL debug support: cannot extract asbdiag boot gate' >&2; exit 1; }
diag_boot_gate() (
  _boot_version="$1"
  . "$TMP/asbdiag_boot_gate.sh"
  printf '%s' "$_boot_debug"
)
for _gate_case in \
  'V64-debug1:1' \
  'V64-debug4:1' \
  'V64-debug10:1' \
  'V64-debug42:1' \
  'V64-debug999999999:1' \
  'V64:0' \
  'V64-debug:0' \
  'V64-debug0:0' \
  'V64-debug4x:0'; do
  _gate_version="${_gate_case%:*}"; _gate_want="${_gate_case##*:}"
  _gate_live="$(diag_boot_gate "$_gate_version")"
  [ "$_gate_live" = "$_gate_want" ] || {
    echo "FAIL debug support: asbdiag boot gate version=$_gate_version want=$_gate_want live=$_gate_live" >&2; exit 1
  }
done

# A release module must refuse both mutations even if someone manufactures a DOM click.
REL="$TMP/release"; mkdir -p "$REL"
printf 'id=AutoSystemBoost\nversion=V64\n' > "$REL/module.prop"
REL_OUT="$(ASB_DEBUG_SUPPORT_MODDIR="$REL" ASB_DEBUG_SUPPORT_STATE_DIR="$TMP/state" sh "$HELPER" full-day || true)"
printf '%s\n' "$REL_OUT" | grep -Fq 'error=debug_only' || {
  echo 'FAIL debug support: release gate did not refuse recorder' >&2; exit 1
}
REL_TL="$(ASB_BOOT_TIMELINE_MODDIR="$REL" ASB_BOOT_TIMELINE_STATE_DIR="$TMP/timeline-release" sh "$TIMELINE" begin postfs_begin || true)"
printf '%s\n' "$REL_TL" | grep -Fq 'status=debug_only' || {
  echo 'FAIL debug support: release gate did not refuse boot timeline' >&2; exit 1
}
[ ! -e "$TMP/timeline-release/boot_timeline.tsv" ] || { echo 'FAIL debug support: release timeline wrote state' >&2; exit 1; }

# A debug module gets a mocked diagnostic and recorder. The recorder reproduces the real
# ownership protocol: it claims the tokenized directory with ITS OWN PID and only removes
# a guard that still names that PID. This catches launcher-PID and cleanup races on host.
DBG="$TMP/debug"; mkdir -p "$DBG/system/bin" "$DBG/tools/logkit" "$TMP/out"
printf 'id=AutoSystemBoost\nversion=V64-debug10\n' > "$DBG/module.prop"
TL_STATE="$TMP/timeline-debug"
ASB_BOOT_TIMELINE_MODDIR="$DBG" ASB_BOOT_TIMELINE_STATE_DIR="$TL_STATE" sh "$TIMELINE" begin postfs_begin >/dev/null
ASB_BOOT_TIMELINE_MODDIR="$DBG" ASB_BOOT_TIMELINE_STATE_DIR="$TL_STATE" sh "$TIMELINE" mark service_enter >/dev/null
grep -Fq $'\tpostfs_begin\t' "$TL_STATE/boot_timeline.tsv" || { echo 'FAIL debug support: postfs boot marker missing' >&2; exit 1; }
grep -Fq $'\tservice_enter\t' "$TL_STATE/boot_timeline.tsv" || { echo 'FAIL debug support: service boot marker missing' >&2; exit 1; }
printf '#!/bin/sh\n[ "${ASB_DEBUG_SUPPORT_TEST_DIAG_DELAY:-0}" = 1 ] && sleep 1\nif [ "${ASB_DEBUG_SUPPORT_TEST_DIAG_FAIL:-0}" = 1 ]; then echo diagnostic-failed; exit 9; fi\necho diagnostic-ok\n' > "$DBG/system/bin/asbdiag"; chmod 0755 "$DBG/system/bin/asbdiag"
cat > "$DBG/tools/logkit/asb_log_full_day.sh" <<'EOF_RECORDER'
#!/bin/sh
set -u
_lock="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"
_token="${ASB_DEBUG_SUPPORT_LOCK_TOKEN:-}"
[ -n "$_lock" ] && [ -d "$_lock" ] || exit 91
[ "$(cat "$_lock/token" 2>/dev/null || true)" = "$_token" ] || exit 92
printf '%s\n' "$$" > "$_lock/pid.tmp.$$" || exit 93
mv -f "$_lock/pid.tmp.$$" "$_lock/pid" || exit 94
_out="$_lock/capture_output"; mkdir -p "$_out" || exit 95
printf '%s\n' "$_out" > "$_lock/output_dir" || exit 96
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
# Capture the output AND the status separately.
#
# Under `set -e` a non-zero exit from the helper aborts the test at this line, before any
# assertion runs - so the whole regression reported "exit code 8" with no failing check
# named, and the real problem was invisible. The helper legitimately returns non-zero for
# conditions this test is meant to observe, so its status is data here, not an error.
DIAG_OUT="$(env "${ENV[@]}" sh "$HELPER" diag || true)"
echo "$DIAG_OUT" | grep -Fq 'status=saved'
DIAG_PATH="$(printf '%s\n' "$DIAG_OUT" | sed -n 's/^path=//p')"
[ -f "$DIAG_PATH" ] && grep -Fq 'diagnostic-ok' "$DIAG_PATH" || { echo 'FAIL debug support: diag export' >&2; exit 1; }

# WebUI cannot paint while a KSU bridge waits for a synchronous diagnostic export.
# The async action must acknowledge a delayed worker immediately, remain observable via
# fixed status command, and publish a complete saved record after the worker exits.
ASYNC_DIAG="$(ASB_DEBUG_SUPPORT_TEST_DIAG_DELAY=1 env "${ENV[@]}" sh "$HELPER" diag-start || true)"
printf '%s\n' "$ASYNC_DIAG" | grep -Fqx 'status=started' || { echo 'FAIL debug support: async diag did not return started' >&2; exit 1; }
ASYNC_PID="$(printf '%s\n' "$ASYNC_DIAG" | sed -n 's/^pid=//p')"
[ -n "$ASYNC_PID" ] && kill -0 "$ASYNC_PID" 2>/dev/null || { echo 'FAIL debug support: async diag worker missing' >&2; exit 1; }
ASYNC_STATUS="$(env "${ENV[@]}" sh "$HELPER" diag-status || true)"
printf '%s\n' "$ASYNC_STATUS" | grep -Eq '^status=(starting|running)$' || { echo 'FAIL debug support: async diag status not live' >&2; exit 1; }
for _diag_try in $(seq 1 30); do
  sleep 0.1
  ASYNC_STATUS="$(env "${ENV[@]}" sh "$HELPER" diag-status || true)"
  printf '%s\n' "$ASYNC_STATUS" | grep -Fqx 'status=saved' && break
done
printf '%s\n' "$ASYNC_STATUS" | grep -Fqx 'status=saved' || { echo 'FAIL debug support: async diag never reached saved' >&2; exit 1; }
ASYNC_PATH="$(printf '%s\n' "$ASYNC_STATUS" | sed -n 's/^path=//p')"
[ -f "$ASYNC_PATH" ] && grep -Fq 'diagnostic-ok' "$ASYNC_PATH" || { echo 'FAIL debug support: async diag saved output missing' >&2; exit 1; }

# A dead diagnostic worker must not leave a permanent `already_running` lock, and a nonzero
# asbdiag exit must become an explicit failed status rather than a misleading saved toast.
mkdir -p "$TMP/state/asbdiag_webui.lock"
printf '999999\n' > "$TMP/state/asbdiag_webui.lock/pid"
STALE_DIAG="$(env "${ENV[@]}" sh "$HELPER" diag-start || true)"
printf '%s\n' "$STALE_DIAG" | grep -Fqx 'status=started' || { echo 'FAIL debug support: known-dead diag lock not reclaimed' >&2; exit 1; }
for _diag_try in $(seq 1 30); do sleep 0.1; env "${ENV[@]}" sh "$HELPER" diag-status | grep -Fqx 'status=saved' && break; done
FAIL_DIAG="$(ASB_DEBUG_SUPPORT_TEST_DIAG_FAIL=1 env "${ENV[@]}" sh "$HELPER" diag-start || true)"
printf '%s\n' "$FAIL_DIAG" | grep -Fqx 'status=started' || { echo 'FAIL debug support: failing diag did not launch' >&2; exit 1; }
for _diag_try in $(seq 1 30); do
  sleep 0.1
  FAIL_DIAG_STATUS="$(env "${ENV[@]}" sh "$HELPER" diag-status || true)"
  printf '%s\n' "$FAIL_DIAG_STATUS" | grep -Fqx 'status=failed' && break
done
printf '%s\n' "$FAIL_DIAG_STATUS" | grep -Fqx 'status=failed' || { echo 'FAIL debug support: nonzero diag did not reach failed state' >&2; exit 1; }
printf '%s\n' "$FAIL_DIAG_STATUS" | grep -Fqx 'error=asbdiag_exit_9' || { echo 'FAIL debug support: nonzero diag exit was not surfaced' >&2; exit 1; }
START1="$(env "${ENV[@]}" sh "$HELPER" full-day || true)"
echo "$START1" | grep -Fq 'status=started'
REC_PID="$(printf '%s\n' "$START1" | sed -n 's/^pid=//p')"
[ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null || { echo 'FAIL debug support: recorder did not stay alive' >&2; exit 1; }
START2="$(env "${ENV[@]}" sh "$HELPER" full-day || true)"
echo "$START2" | grep -Fq 'status=already_running'
echo "$START2" | grep -Fq "pid=$REC_PID"

# Deleting the exact directory published by the live recorder is an explicit cancellation.
# The helper may stop ONLY that recorder, clear its lock and launch a new single capture.
# Simulate a common Android toybox limitation: both ps formats expose only a shortened command
# line. The recovery still needs the script basename, but remains gated by a live lock PID and
# an explicitly removed recorder-owned output directory.
mkdir -p "$TMP/ps-truncated"
cat > "$TMP/ps-truncated/ps" <<'EOF_PS'
#!/bin/sh
printf '%s\n' 'sh asb_log_full_day.sh 24'
EOF_PS
chmod 0755 "$TMP/ps-truncated/ps"
ORPHAN_OUT="$(cat "$TMP/state/full_day_webui.lock/output_dir")"
[ -d "$ORPHAN_OUT" ] || { echo 'FAIL debug support: recorder did not publish output dir' >&2; exit 1; }
rm -rf "$ORPHAN_OUT"
RECOVERED="$(PATH="$TMP/ps-truncated:$PATH" env "${ENV[@]}" sh "$HELPER" full-day || true)"
printf '%s\n' "$RECOVERED" | grep -Fq 'status=started' || { echo 'FAIL debug support: removed output dir did not recover capture slot' >&2; exit 1; }
grep -Fq 'recovered=output_removed' "$TMP/state/full_day_webui.recovery.log" || { echo 'FAIL debug support: orphan recovery evidence missing' >&2; exit 1; }
REC_PID="$(printf '%s\n' "$RECOVERED" | sed -n 's/^pid=//p')"
[ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null || { echo 'FAIL debug support: recovered recorder missing' >&2; exit 1; }

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
  # wait propagates the child status, and under set -e that aborts the test before the
  # assertion that is meant to inspect it. The helper legitimately returns non-zero for
  # the losing side of this race - that is the behaviour being measured.
  wait "$C1" || true; wait "$C2" || true
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
STALE="$(env "${ENV[@]}" sh "$HELPER" full-day || true)"
echo "$STALE" | grep -Fq 'status=started' || { echo 'FAIL debug support: known-dead lock not reclaimed' >&2; exit 1; }
REC_PID="$(printf '%s\n' "$STALE" | sed -n 's/^pid=//p')"

# The helper accepts a fixed enum only; it has no eval/source/untrusted command interpolation.
need "$HELPER" "case \"\${1:-status}\" in"
need "$HELPER" 'mkdir "$LOCKDIR"'
need "$HELPER" 'lock_known_dead()'
need "$HELPER" 'full_day_output_missing()'
need "$HELPER" 'full_day_cancel_orphan()'
need "$HELPER" 'full_day_pid_matches_recorder()'
need "$HELPER" 'asb_log_full_day.sh*) return 0'
need "$HELPER" 'full_day_recovery_note()'
need "$HELPER" 'RECOVERY_LOG='
need "$HELPER" 'PROC_ROOT='
need "$HELPER" 'diag_lock_known_dead()'
need "$HELPER" 'asbdiag_exit_${_rc}'
need "$HELPER" 'lock_wait_live_pid()'
need "$HELPER" 'ASB_DEBUG_SUPPORT_LOCKDIR="$LOCKDIR"'
need "$HELPER" 'diag-start) diag_start'
need "$HELPER" 'diag-status) diag_status'
need "$HELPER" 'full-day-start) start_full_day 1'
need "$HELPER" 'DIAG_LOCKDIR="$STATE_DIR/asbdiag_webui.lock"'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'LK_WEBUI_LOCKDIR="${ASB_DEBUG_SUPPORT_LOCKDIR:-}"'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_claim()'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_claim || { echo '\''[debug-webui] guard claim failed'\''; exit 2; }'
need "$ROOT/tools/logkit/asb_log_full_day.sh" "trap 'lk_finalize; lk_webui_guard_release; exit 0' TERM INT HUP"
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_release'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'lk_webui_guard_publish_output()'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'LK_WEBUI_OUTPUTFILE'
need "$ROOT/tools/logkit/asb_log_full_day.sh" 'FULL-DAY capture complete. Output: $LK_OUT_DIR'
# Debug capture must expose a resolvable AudioMix owner and the evidence that made
# a media-like workload game-like, without putting any package-manager polling in
# the native governor. The logkit helpers are passive and use one capture-start map.
COMMON="$ROOT/tools/logkit/_asb_logkit_common.sh"
need "$COMMON" 'lk_audio_wakelock_attribution_init()'
need "$COMMON" 'audio_wakelock_attribution.tsv'
need "$COMMON" 'lk_fsm_media_trace_header()'
need "$COMMON" 'fsm_media_trace.tsv'
# Android 16 emits a chained WorkSource for AudioMix. Test both that real form and
# the compact legacy form; raw UID attribution is useless if the recorder prints '-'.
sed -n '/^lk_audio_wakelock_live_row() {/,/^}/p' "$COMMON" > "$TMP/audio_wakelock_fn.sh"
[ -s "$TMP/audio_wakelock_fn.sh" ] || { echo 'FAIL debug support: cannot extract AudioMix attribution helper' >&2; exit 1; }
lk_audio_wakelock_package_for_uid() { printf 'pkg.uid.%s\n' "$1"; }
LK_OUT_DIR="$TMP/audio_attr"; mkdir -p "$LK_OUT_DIR"
. "$TMP/audio_wakelock_fn.sh"
lk_audio_wakelock_live_row "PARTIAL_WAKE_LOCK 'AudioMix' (uid=1041 ws=WorkSource{ chains=WorkChain{(10658), (1041)}})" 123
lk_audio_wakelock_live_row "PARTIAL_WAKE_LOCK 'AudioMix' WorkSource{10652}" 124
grep -Fq '123|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" || { echo 'FAIL debug support: chained AudioMix row absent' >&2; exit 1; }
grep -Fq '|10658|pkg.uid.10658|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" || { echo 'FAIL debug support: chained WorkSource UID unresolved' >&2; exit 1; }
grep -Fq '|10652|pkg.uid.10652|' "${LK_OUT_DIR}/audio_wakelock_attribution.tsv" || { echo 'FAIL debug support: compact WorkSource UID unresolved' >&2; exit 1; }
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
count_exact "$UI" '<span class="tg-link-ico" data-tech-icon="telegram"></span>' 6
need "$UI" '.tg-link-ico .tech-icon { width: 18px; height: 18px; }'
need "$UI" '.footer-support-row .tg-link-ico { width: 16px; height: 16px; flex-basis: 16px; }'
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
need "$UI" 'background:#000;'
need "$UI" 'stockRestoreToastOpen();'
need "$UI" 'stockRestoreToastClose();'
need "$UI" 'toast.stock-restoring'
need "$UI" 'stockRestoreToastPulse'
need "$UI" 'debugDiagPulse .38s'
need "$UI" 'debugActionWaitOpen(action);'
need "$UI" 'debugActionWaitClose();'
need "$UI" 'await debugFrame();'
need "$UI" "'diag-start' : 'full-day-start'"
need "$UI" 'runtime/asb_debug_support.sh diag-status'
need "$UI" 'async function debugDiagPoll()'
need "$UI" 'async function debugFullDayPoll()'
need "$UI" 'runtime/asb_debug_support.sh status'
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
  # Check the VALUE, not the byte sequence.
  #
  # These matched '"key": "value"' with the space that json.dump's indent mode happens to
  # emit. Compacting the locale files to save 43 KB changed no data at all and broke both
  # lines, because a grep for punctuation is not a test of content.
  #
  # Matching the key and value with optional whitespace between them holds for either
  # formatting, and still fails if the string is actually missing or renamed - which is
  # what the contract is about.
  grep -Eq '"dbg_diag_btn"[[:space:]]*:[[:space:]]*"asbdiag"' "$locale" \
    || fail "missing dbg_diag_btn=asbdiag in $locale"
  grep -Eq '"dbg_log_btn"[[:space:]]*:[[:space:]]*"24h log"' "$locale" \
    || fail "missing dbg_log_btn=24h log in $locale"
  need "$locale" '"dbg_log_failed"'
done

echo 'PASS debug support WebUI/helper contract'
