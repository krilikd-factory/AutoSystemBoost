#!/usr/bin/env bash
# Uevent accounting contract: every drained uevent is bucketed by subsystem and exposed
# in the metrics file, so a 14258-event capture names its own source instead of leaving
# a 40x wake-rate anomaly unexplained (CPH2745 one-hour capture, V65).
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/src/asb_governor.c"
fail() { echo "FAIL uevent accounting contract: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail 'src/asb_governor.c missing'

# --- source pins ---
grep -qF 'uevent_by_subsys=\"' "$SRC" || fail 'metrics line uevent_by_subsys missing'
grep -qF 'uevent_events_total=' "$SRC" || fail 'metrics line uevent_events_total missing'
grep -qF 'g_uev_by_src[cur >= 0 ? ASB_UEV_DISPLAY : uevent_bucket(ubuf, un)]++' "$SRC" \
  || fail 'drain loop does not bucket by the parser verdict'
grep -qF 'drained < 64' "$SRC" || fail 'drain cap changed'
grep -qF '"display", "power_supply", "net", "sound", "usb", "thermal", "wakeup", "other"' "$SRC" \
  || fail 'bucket name table changed'
# The old recv-inside-parser shape must not come back: it discarded the source.
if grep -q 'parse_uevent_screen(' "$SRC"; then
  fail 'old parse_uevent_screen() is back - it threw the event source away'
fi

# --- executable C fixture: the REAL parser and bucket against synthetic uevents ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
{
  echo '#include <stdio.h>'
  echo '#include <string.h>'
  sed -n '/^\/\* Uevent bookkeeping: the epoll wake counter/,/^static unsigned long g_uev_events_total = 0;$/p' "$SRC"
  sed -n '/^static int parse_uevent_screen_buf(char \*buf, int n) {$/,/^}$/p' "$SRC"
  sed -n '/^static asb_uev_src_t uevent_bucket(const char \*buf, int n) {$/,/^}$/p' "$SRC"
} > "$TMP/extracted.c"
grep -q 'ASB_UEV_COUNT' "$TMP/extracted.c" || fail 'enum block not extracted'
grep -q 'parse_uevent_screen_buf' "$TMP/extracted.c" || fail 'parser not extracted'
grep -q 'uevent_bucket' "$TMP/extracted.c" || fail 'bucket not extracted'

cat >> "$TMP/extracted.c" <<'EOF'
static int fails = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } } while (0)
int main(void) {
    /* The suspected storm source: fuel-gauge chatter. Not a screen event. */
    char e1[] = "change@/devices/platform/soc/power_supply\0ACTION=change\0SUBSYSTEM=power_supply\0POWER_SUPPLY_STATUS=Discharging\0";
    int n1 = sizeof(e1) - 1;
    CHECK(parse_uevent_screen_buf(e1, n1) < 0, "power_supply must not be a screen event");
    CHECK(uevent_bucket(e1, n1) == ASB_UEV_POWER, "power_supply bucket");

    /* Display on via drm. */
    char e2[] = "change@/devices/platform/soc/drm\0ACTION=change\0SUBSYSTEM=drm\0BLANK=0\0";
    int n2 = sizeof(e2) - 1;
    CHECK(parse_uevent_screen_buf(e2, n2) == 1, "drm BLANK=0 must be screen ON");
    CHECK(uevent_bucket(e2, n2) == ASB_UEV_DISPLAY, "drm bucket");

    /* Display off via backlight brightness. */
    char e3[] = "change@/x\0SUBSYSTEM=backlight\0brightness=0\0";
    int n3 = sizeof(e3) - 1;
    CHECK(parse_uevent_screen_buf(e3, n3) == 0, "backlight brightness=0 must be screen OFF");
    CHECK(uevent_bucket(e3, n3) == ASB_UEV_DISPLAY, "backlight bucket");

    /* A modem link appearing - the rmnet_data3 case from the field log. */
    char e4[] = "add@/devices/virtual/net/rmnet_data3\0ACTION=add\0SUBSYSTEM=net\0INTERFACE=rmnet_data3\0";
    CHECK(uevent_bucket(e4, sizeof(e4) - 1) == ASB_UEV_NET, "net bucket");
    CHECK(parse_uevent_screen_buf(e4, sizeof(e4) - 1) < 0, "net must not be a screen event");

    /* Unknown and missing subsystems land in OTHER, never crash, never display. */
    char e5[] = "add@/x\0SUBSYSTEM=rfkill\0";
    CHECK(uevent_bucket(e5, sizeof(e5) - 1) == ASB_UEV_OTHER, "rfkill -> other");
    char e6[] = "add@/x\0ACTION=add\0DEVPATH=/devices/foo\0";
    CHECK(uevent_bucket(e6, sizeof(e6) - 1) == ASB_UEV_OTHER, "no SUBSYSTEM -> other");
    CHECK(parse_uevent_screen_buf(e6, sizeof(e6) - 1) < 0, "no display marker -> not screen");

    /* The accounting shape itself: counters increment the way the drain loop does. */
    g_uev_by_src[uevent_bucket(e1, n1)]++;
    g_uev_events_total++;
    CHECK(g_uev_by_src[ASB_UEV_POWER] == 1, "bucket counter increments");
    CHECK(g_uev_events_total == 1, "total counter increments");

    for (int i = 0; i < ASB_UEV_COUNT; i++)
        CHECK(g_uev_src_name[i][0] != '\0', "every bucket has a name");

    if (fails) return 1;
    printf("uevent accounting fixture: OK\n");
    return 0;
}
EOF

CC="${CC:-}"
[ -n "$CC" ] || CC="$(command -v gcc || command -v clang)" || fail 'no host compiler'
"$CC" -O2 -Wall -Wextra -Werror -o "$TMP/uevfix" "$TMP/extracted.c" || fail 'fixture build failed'
"$TMP/uevfix" || fail 'fixture run failed'

echo 'uevent accounting contract: OK'
