#!/bin/sh
# Runtime (fix115): an always-on display is a screen that is OFF.
#
# Every OnePlus capture answered "is the screen on" from panel0-backlight, and an always-on
# display keeps it lit: an OnePlus 13R ran the governor screen-ON for 43 minutes of a night
# (LIGHT_IDLE, active tick, no quiet night) while Android said "Dozing". The governor now
# reads Android's display state (debug.tracing.screen_state = Display.STATE_*) and treats
# DOZE / DOZE_SUSPEND as off; anything else falls through to the panel nodes as before.
# Executable fixture: the REAL metrics_screen_on() and property parser cut out of
# asb_metrics.h, against a fake sysfs and a fake property store.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/src/asb_metrics.h"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL aod screen: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP aod screen: no C compiler"; exit 0; }

awk '/^static int g_screen_src = 0;/{on=1} on{print} on&&/^static int metrics_screen_on\(/{f=1} f&&/^}/{exit}' "$M" > "$T/scr.c"
grep -q 'debug.tracing.screen_state' "$T/scr.c" || fail "screen detection does not read Android's display state"
grep -q 'if (ds == 3 || ds == 4)' "$T/scr.c" || fail "doze is not the veto"

cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define PATH_SCREEN_STATUS  "oplus1"
#define PATH_SCREEN_STATUS2 "oplus2"
#define PATH_BACKLIGHT      "panel0"
/* fake sysfs: oplus nodes absent (-1) as on every captured OnePlus; backlight settable */
static int g_bl = -1;
static int sysfs_read_int(const char *p, int def) {
    if (!strcmp(p, "panel0")) return g_bl;
    return def;
}
/* fake property store for the Android branch */
#define PROP_VALUE_MAX 92
static const char *g_prop = NULL;
static int __system_property_get(const char *n, char *v) {
    if (strcmp(n, "debug.tracing.screen_state") || !g_prop) { v[0] = 0; return 0; }
    strcpy(v, g_prop); return (int)strlen(v);
}
#define __ANDROID__ 1
#include "scr.c"
int main(void) {
    int bad = 0;
    #define CHECK(c, msg) do { if (!(c)) { printf("%s\n", msg); bad = 1; } } while (0)
    /* AOD: backlight lit, Android dozing -> off, source 6 */
    g_bl = 493; g_prop = "3";
    CHECK(metrics_screen_on() == 0, "doze with a lit backlight read as on");
    CHECK(metrics_screen_src() == 6, "doze not tagged source 6");
    CHECK(g_display_state == 3, "display state not recorded");
    g_prop = "4";
    CHECK(metrics_screen_on() == 0, "doze-suspend read as on");
    /* really on */
    g_prop = "2";
    CHECK(metrics_screen_on() == 1, "on read as off");
    CHECK(metrics_screen_src() == 3, "on did not fall through to the backlight");
    /* property OFF does not override the panel by itself (only doze decides) */
    g_prop = "1"; g_bl = 0;
    CHECK(metrics_screen_on() == 0, "off with backlight 0 read as on");
    /* no property: exactly the old behaviour */
    g_prop = NULL; g_bl = 300;
    CHECK(metrics_screen_on() == 1, "no property: lit backlight not on");
    CHECK(g_display_state == -1, "missing property not -1");
    g_bl = 0;
    CHECK(metrics_screen_on() == 0, "no property: dark backlight not off");
    /* garbage never decides */
    g_bl = 300; g_prop = "3x";
    CHECK(metrics_screen_on() == 1, "garbage property vetoed a lit screen");
    g_prop = "";
    CHECK(metrics_screen_on() == 1, "empty property vetoed a lit screen");
    /* fix116: a fresh ON from the display-state waiter is trusted for 3 s while the
     * backlight is still dark; afterwards (or without the stamp) the backlight decides */
    g_prop = "2"; g_bl = 0; g_disp_prop_on_ts = time(NULL);
    CHECK(metrics_screen_on() == 1, "fresh ON with a dark backlight not trusted");
    CHECK(metrics_screen_src() == 7, "fresh ON not tagged source 7");
    g_disp_prop_on_ts = time(NULL) - 4;
    CHECK(metrics_screen_on() == 0, "a stale ON stamp kept the screen on");
    g_disp_prop_on_ts = 0;
    CHECK(metrics_screen_on() == 0, "ON without a waiter stamp overrode a dark backlight");
    g_prop = "3"; g_disp_prop_on_ts = time(NULL);
    CHECK(metrics_screen_on() == 0, "doze lost to an ON stamp");
    g_disp_prop_on_ts = 0;
    /* AOD seconds accumulate across reads, a gap over 5 min does not count */
    g_prop = "3"; g_scr_aod_s = 0; g_scr_aod_last = time(NULL) - 40;
    metrics_screen_on();
    CHECK(g_scr_aod_s >= 39 && g_scr_aod_s <= 41, "AOD seconds not accumulated");
    g_scr_aod_last = time(NULL) - 4000; metrics_screen_on();
    CHECK(g_scr_aod_s <= 41, "a long gap was counted as AOD time");
    g_prop = "2"; metrics_screen_on();
    CHECK(g_scr_aod_last == 0, "leaving doze did not reset the AOD clock");
    return bad;
}
X
"$CC" -std=gnu99 -Wall -Wno-unused-function -o "$T/t" "$T/t.c" -I"$T" 2>"$T/cc.err" || { cat "$T/cc.err" >&2; fail "fixture does not compile"; }
out="$("$T/t")" || fail "$out"

# Host build: no property -> -1, old behaviour.
cat > "$T/h.c" <<'X'
#include <stdio.h>
#include <string.h>
#include <time.h>
#define PATH_SCREEN_STATUS  "oplus1"
#define PATH_SCREEN_STATUS2 "oplus2"
#define PATH_BACKLIGHT      "panel0"
static int sysfs_read_int(const char *p, int def) { return strcmp(p, "panel0") ? def : 200; }
#include "scr.c"
int main(void) { return !(metrics_screen_on() == 1 && g_display_state == -1); }
X
"$CC" -std=gnu99 -Wall -Wno-unused-function -o "$T/h" "$T/h.c" -I"$T" 2>"$T/cc.err" || { cat "$T/cc.err" >&2; fail "host variant does not compile"; }
"$T/h" || fail "host build without the property changed the screen answer"

# The governor publishes it; asbdiag explains it; the shell check follows the same rule.
grep -q 'display_state=%d' "$ROOT/src/asb_governor.c" || fail "state file lacks display_state"
grep -q "screen source: Android display state" "$ROOT/tools/asb_diag.sh" || fail "asbdiag does not name source 6"
sed -n '/^asb_screen_on() {/,/^}/p' "$ROOT/service.sh" > "$T/s.sh"
grep -q 'debug.tracing.screen_state' "$T/s.sh" || fail "service.sh screen check ignores doze"
grep -v '^[[:space:]]*#' "$T/s.sh" | grep -q 'card0-DSI' && fail "service.sh still trusts DRM 'connected' as screen on"
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$PROPV"\n' > "$T/bin/getprop"; chmod +x "$T/bin/getprop"
PATH="$T/bin:$PATH" PROPV=3 sh -c '. "$1"; asb_screen_on' _ "$T/s.sh" && fail "shell: doze read as on"
echo "PASS always-on display counts as screen-off (governor, shell, diag)"
