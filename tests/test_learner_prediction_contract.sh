#!/bin/sh
# Contract + runtime: the hour-of-week learner predicts from screen share, never slows a
# ramp-up below the FSM default, and keeps its data outside the module directory.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/src/asb_learner.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL learner prediction: $*" >&2; fail=1; }
grep -Fq '#define LEARN_FILE        "/data/adb/asb/learn.bin"' "$L" || f 'learn.bin still inside the module directory (lost on every update)'
grep -Fq 'learner_load_from(db, LEARN_FILE_LEGACY)' "$L" || f 'legacy learn.bin not carried over'
grep -Fq 'drain_ma_ema < ' "$L" && f 'prediction still uses milliamps (awake-only samples, gauge-scaled)'
grep -Fq '/data/adb/asb/learn.bin' "$ROOT/service.sh" || f 'learning reset does not clear learn.bin'
grep -Fq '#define PERSISTENT_STATS_DIR        "/data/adb/asb"' "$ROOT/src/asb_governor.c" || f 'pstats/env fingerprint still inside the module directory'
grep -Fq 'pstats_load_migrating(PERSISTENT_STATS_FILE' "$ROOT/src/asb_governor.c" || f 'legacy pstats not carried over'
CC="${CC:-}"; [ -n "$CC" ] || CC="$(command -v gcc || command -v clang || true)"
if [ -n "$CC" ]; then
  cat > "$T/t.c" <<'C'
#include <stdint.h>
#include <unistd.h>
#include "asb_learner.h"
#include <stdio.h>
int main(void) {
  asb_learn_db_t db; memset(&db, 0, sizeof db);
  int slot = learner_slot(), up, down, bad = 0;
  float shares[] = { 0.05f, 0.30f, 0.80f };
  int want[] = { LEARN_PREDICT_IDLE, LEARN_PREDICT_LIGHT, LEARN_PREDICT_ACTIVE };
  for (int i = 0; i < 3; i++) {
    db.slots[slot].samples = 5; db.slots[slot].screen_on_ema = shares[i];
    db.slots[slot].drain_ma_ema = 500.0f;   /* a real awake-sampled hour */
    if ((int)learner_predict(&db) != want[i]) { printf("share %.2f predicted %d\n", shares[i], learner_predict(&db)); bad = 1; }
    learner_adjust_windows(&db, &up, &down);
    if (up > 2) { printf("share %.2f slows ramp-up to %d ticks\n", shares[i], up); bad = 1; }
  }
  return bad;
}
C
  if "$CC" -I"$ROOT/src" -o "$T/t" "$T/t.c" -lm 2>"$T/err"; then
    "$T/t" || f 'runtime prediction check failed'
  else
    f "learner header does not compile standalone: $(head -3 "$T/err")"
  fi
fi
[ "$fail" = 0 ] && echo "PASS learner prediction contract"
exit "$fail"
