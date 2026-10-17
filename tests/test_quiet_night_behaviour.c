/* Quiet Night skip decision, exercised as behaviour rather than as source text.
 *
 * The source-level test next to this one checks WHERE the reset lives, which is what the
 * original bug was about. But a placement test can only ever prove placement: it would
 * pass on a rewrite that moved the reset correctly and still got the sequence wrong.
 *
 * This isolates the decision itself - given "is the mode active" and a tick counter, may
 * this tick skip its battery reads - and walks the transition that actually broke:
 * a skipping tick, then the mode ending. The flag must be clear on that next tick, because
 * everything downstream (auto-battery, charge awareness, the learner's drain, the
 * time-to-empty estimate) reads values that would otherwise be hours old.
 */
#include <stdio.h>

static int g_flag;
static int g_counter;

/* Mirrors the governor: clear unconditionally, then let an active skipping tick set it. */
static void quiet_night_tick(int active) {
    g_flag = 0;
    if (active) {
        g_counter++;
        if (g_counter % 2 != 0) g_flag = 1;
    }
}

static int fails;

static void check(const char *what, int got, int want) {
    if (got != want) {
        printf("  FAIL %-44s got %d want %d\n", what, got, want);
        fails++;
    } else {
        printf("  ok   %-44s %d\n", what, got);
    }
}

int main(void) {
    g_flag = 0; g_counter = 0;

    quiet_night_tick(1);  check("night tick 1 skips", g_flag, 1);
    quiet_night_tick(1);  check("night tick 2 reads", g_flag, 0);
    quiet_night_tick(1);  check("night tick 3 skips", g_flag, 1);

    /* The transition the bug lived in: mode ends immediately after a skipping tick. */
    quiet_night_tick(0);  check("first tick after mode ends reads", g_flag, 0);
    quiet_night_tick(0);  check("and keeps reading", g_flag, 0);
    quiet_night_tick(0);  check("and still keeps reading", g_flag, 0);

    /* Re-entry must not carry state that makes the first tick back skip unexpectedly. */
    quiet_night_tick(1);  check("re-entry alternates from where it left off", g_flag, 0);
    quiet_night_tick(1);  check("next night tick skips", g_flag, 1);
    quiet_night_tick(0);  check("exit again reads", g_flag, 0);

    if (fails) { printf("\n  failed: %d\n", fails); return 1; }
    printf("\n  passed: 9\n  failed: 0\n");
    return 0;
}
