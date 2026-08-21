#!/bin/bash
# Contract: debug WebUI support actions stay debug-gated, bounded and non-overlapping.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT/runtime/asb_debug_support.sh"
UI="$ROOT/webroot/index.html"
TMP="$(mktemp -d)"
trap 'if [ -n "${REC_PID:-}" ]; then kill "$REC_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT

need() { grep -Fq -- "$2" "$1" || { echo "FAIL debug support: missing [$2]" >&2; exit 1; }; }
[ -f "$HELPER" ] || { echo "FAIL debug support: helper missing" >&2; exit 1; }
sh -n "$HELPER"

# A release module must refuse both mutations even if someone manufactures a DOM click.
REL="$TMP/release"; mkdir -p "$REL"
printf 'id=AutoSystemBoost\nversion=V64\n' > "$REL/module.prop"
REL_OUT="$(ASB_DEBUG_SUPPORT_MODDIR="$REL" ASB_DEBUG_SUPPORT_STATE_DIR="$TMP/state" sh "$HELPER" full-day || true)"
printf '%s\n' "$REL_OUT" | grep -Fq 'error=debug_only' || {
  echo 'FAIL debug support: release gate did not refuse recorder' >&2; exit 1
}

# A debug module gets a mocked diagnostic and a sleeping recorder. The second start must be
# idempotent and must return the same protected PID instead of creating a parallel capture.
DBG="$TMP/debug"; mkdir -p "$DBG/system/bin" "$DBG/tools/logkit" "$TMP/out"
printf 'id=AutoSystemBoost\nversion=V64-debug3\n' > "$DBG/module.prop"
printf '#!/bin/sh\necho diagnostic-ok\n' > "$DBG/system/bin/asbdiag"; chmod 0755 "$DBG/system/bin/asbdiag"
printf '#!/bin/sh\nsleep 30\n' > "$DBG/tools/logkit/asb_log_full_day.sh"; chmod 0755 "$DBG/tools/logkit/asb_log_full_day.sh"
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

# Start two requests from a clean state at once. Exactly one may create the recorder; the
# other must observe its atomic guard rather than launching a second full-day process.
kill "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
REC_PID=""
rm -f "$TMP/state/full_day_webui.pid"
env "${ENV[@]}" sh "$HELPER" full-day > "$TMP/concurrent_a.out" & C1=$!
env "${ENV[@]}" sh "$HELPER" full-day > "$TMP/concurrent_b.out" & C2=$!
wait "$C1"; wait "$C2"
CONCURRENT="$(cat "$TMP/concurrent_a.out" "$TMP/concurrent_b.out")"
[ "$(printf '%s\n' "$CONCURRENT" | grep -c '^status=started$')" -eq 1 ] || { echo 'FAIL debug support: concurrent start count' >&2; exit 1; }
printf '%s\n' "$CONCURRENT" | grep -Fq 'status=already_running' || { echo 'FAIL debug support: concurrent guard did not report running' >&2; exit 1; }
REC_PID="$(printf '%s\n' "$CONCURRENT" | sed -n 's/^pid=//p' | head -n 1)"
[ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null || { echo 'FAIL debug support: concurrent recorder missing' >&2; exit 1; }

# The helper accepts a fixed enum only; it has no eval/source/untrusted command interpolation.
need "$HELPER" "case \"\${1:-status}\" in"
need "$HELPER" 'set -C'
need "$HELPER" 'pid_guard_busy'
if grep -nE '\beval\b|\bsource\b|/system/bin/sh -c|sh -c' "$HELPER" >/dev/null; then
  echo 'FAIL debug support: helper accepts unsafe shell execution' >&2; exit 1
fi
need "$UI" 'data-debug-support-row'
need "$UI" "asbDebugAction('diag')"
need "$UI" "asbDebugAction('full-day')"
need "$UI" 'runtime/asb_debug_support.sh'
need "$UI" 'loadDebugSupport()'
need "$UI" '/-debug[1-9][0-9]*$/i'
need "$UI" 'data-release-telegram'
for locale in "$ROOT"/webroot/i18n/*.json; do
  need "$locale" '"dbg_diag_btn"'
  need "$locale" '"dbg_log_failed"'
done

echo 'PASS debug support WebUI/helper contract'
