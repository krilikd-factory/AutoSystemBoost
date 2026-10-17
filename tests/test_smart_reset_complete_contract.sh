#!/bin/sh
# Contract: "reset Smart learning" clears every persisted policy input, not only buckets.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RESET="$ROOT/runtime/asb_smart_reset.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"; STATE="$TMP/state"; RUNTIME="$TMP/runtime"; VOL="$TMP/volatile/learner_state.json"
mkdir -p "$MOD/runtime" "$STATE" "$RUNTIME" "$(dirname "$VOL")"
printf 'user-config-must-survive\n' > "$MOD/config.keep"
printf 'baseline-must-survive\n' > "$STATE/baseline.txt"
for f in buckets.bin buckets.bin.bak smart_appheat.bin smart_prev_profile night_window.conf session_history.jsonl; do
  printf 'learned:%s\n' "$f" > "$STATE/$f"
done
for f in session_stats.json pstats_battery.json pstats_balanced.json pstats_performance.json session_history.jsonl; do
  printf 'aggregate:%s\n' "$f" > "$RUNTIME/$f"
done
printf 'volatile learning\n' > "$VOL"

OUT="$(MODDIR="$MOD" ASB_SMART_STATE="$STATE" ASB_RUNTIME_STATE="$RUNTIME" ASB_SMART_VOLATILE_STATE="$VOL" sh "$RESET")"
printf '%s\n' "$OUT" | grep -Fq 'session history and learned stats are cleared' || { echo 'FAIL smart reset: outcome message missing' >&2; exit 1; }
for f in buckets.bin buckets.bin.bak smart_appheat.bin smart_prev_profile night_window.conf session_history.jsonl; do
  [ ! -e "$STATE/$f" ] || { echo "FAIL smart reset: retained state/$f" >&2; exit 1; }
done
for f in session_stats.json pstats_battery.json pstats_balanced.json pstats_performance.json session_history.jsonl; do
  [ ! -e "$RUNTIME/$f" ] || { echo "FAIL smart reset: retained runtime/$f" >&2; exit 1; }
done
[ ! -e "$VOL" ] || { echo 'FAIL smart reset: retained volatile learner state' >&2; exit 1; }
grep -Fqx 'user-config-must-survive' "$MOD/config.keep" || { echo 'FAIL smart reset: changed user config' >&2; exit 1; }
grep -Fqx 'baseline-must-survive' "$STATE/baseline.txt" || { echo 'FAIL smart reset: changed baseline' >&2; exit 1; }
echo 'PASS complete Smart reset contract'
