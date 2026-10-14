#!/bin/sh
# Runtime (fix148): the hour-of-week learner takes no drain from a charging hour.
#
# The governor passed the battery current's magnitude whatever its direction, so an hour on
# the charger was learned as drain: CPH2769's log read "learner updated: drain=2317.0mA
# screen=0%" for an hour of 3.4 A charging. A charging tick now carries no drain; an hour of
# them still teaches the screen share and leaves the drain as it was. The REAL header runs.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CC="${CC:-}"; [ -n "$CC" ] || CC="$(command -v gcc || command -v clang || true)"
[ -n "$CC" ] || { echo "SKIP learner charging: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/t.c" <<'C'
#include <stdint.h>
#include <unistd.h>
#include "asb_learner.h"
#include <stdio.h>
static int roll(asb_accum_t *a, float *d, float *s) {   /* force the hour to change */
  a->last_hour = (a->last_hour + 1) % 24;
  return accum_tick(a, -1, 0, d, s);
}
int main(void) {
  asb_accum_t a; asb_learn_db_t db; float d, s; int bad = 0;
  memset(&db, 0, sizeof db); accum_init(&a);
  int slot = learner_slot();
  db.slots[slot].samples = 5; db.slots[slot].drain_ma_ema = 300.0f; db.slots[slot].screen_on_ema = 0.5f;
  /* An hour on the charger: 10 ticks, screen on in 4, no drain sample. */
  for (int i = 0; i < 10; i++) accum_tick(&a, -1, i < 4, &d, &s);
  if (!roll(&a, &d, &s)) { puts("no rollover"); return 1; }
  if (d >= 0) { printf("charging hour produced a drain of %.1f\n", d); bad = 1; }
  if (s < 0.35f || s > 0.37f) { printf("screen share %.3f (want 4 of 11 ticks)\n", s); bad = 1; }
  learner_update(&db, d, s);
  if (db.slots[slot].drain_ma_ema != 300.0f) { printf("drain moved to %.1f by a charging hour\n", db.slots[slot].drain_ma_ema); bad = 1; }
  if (db.slots[slot].screen_on_ema >= 0.5f) { printf("screen share not learned (%.3f)\n", db.slots[slot].screen_on_ema); bad = 1; }
  /* A battery hour still moves the drain. */
  for (int i = 0; i < 10; i++) accum_tick(&a, 400, 1, &d, &s);
  roll(&a, &d, &s);
  if (d < 399.0f || d > 401.0f) { printf("battery hour drain %.1f (want 400)\n", d); bad = 1; }
  learner_update(&db, d, s);
  if (db.slots[slot].drain_ma_ema <= 300.0f) { puts("battery hour did not move the drain"); bad = 1; }
  return bad;
}
C
"$CC" -I"$ROOT/src" -o "$T/t" "$T/t.c" -lm 2>"$T/err" || { echo "FAIL learner charging: does not compile: $(head -3 "$T/err")" >&2; exit 1; }
"$T/t" || { echo "FAIL learner charging" >&2; exit 1; }
grep -q 'metrics.bat.charging ? -1 : metrics.bat.current_ma' "$ROOT/src/asb_governor.c" || { echo "FAIL learner charging: governor still feeds charging current" >&2; exit 1; }
echo "PASS learner charging: an hour on the charger teaches the screen share and no drain"
