/* P0 thermal source selection fixture.
 *
 * This includes the production selector directly and overrides only THERMAL_BASE before
 * that include. The fixture consequently exercises thermal_discover() and
 * metrics_read_thermal(), rather than a look-alike threshold implementation. No Android
 * runtime node is written: all synthetic zones live below /tmp and are removed on exit.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define THERMAL_BASE "/tmp/asb_p0_thermal_fixture"
#include "../src/asb_metrics.h"

/* asb_metrics.h references this governor-owned config from other static helpers. */
asb_runtime_config_t g_asb_cfg;

static int g_failures;

static void check_i(const char *name, int got, int want) {
    if (got != want) {
        printf("  FAIL %-48s got=%d want=%d\n", name, got, want);
        g_failures++;
    } else {
        printf("  ok   %-48s %d\n", name, got);
    }
}

static void check_s(const char *name, const char *got, const char *want) {
    if (strcmp(got, want) != 0) {
        printf("  FAIL %-48s got=%s want=%s\n", name, got, want);
        g_failures++;
    } else {
        printf("  ok   %-48s %s\n", name, got);
    }
}

static void ensure_dir(const char *path) {
    if (mkdir(path, 0700) != 0 && errno != EEXIST) {
        perror(path);
        exit(2);
    }
}

static void write_text(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (!f) {
        perror(path);
        exit(2);
    }
    fputs(text, f);
    fclose(f);
}

static void fixture_reset(void) {
    char path[256];
    for (int z = 0; z < THERMAL_MAX_ZONES; z++) {
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/type", z);
        unlink(path);
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/temp", z);
        unlink(path);
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d", z);
        rmdir(path);
    }
    rmdir(THERMAL_BASE);
    ensure_dir(THERMAL_BASE);

    g_thermal_source_confidence = 0;
    g_thermal_cpu_zone = -1;
    g_thermal_skin_zone = -1;
    g_thermal_surface_zone = -1;
    g_thermal_board_zone = -1;
    g_thermal_cpu_fallback_zone = -1;
    g_thermal_cpu_fallback_type[0] = '\0';
    g_thermal_cpu_type[0] = '\0';
    g_thermal_cpu_reason[0] = '\0';
    g_thermal_rejected_type[0] = '\0';
    g_thermal_rejected_raw = 0;
    g_last_thermal_rescan = 0;
}

static void add_zone(int zone, const char *type, int raw) {
    char dir[256], path[256], raw_text[32];
    snprintf(dir, sizeof(dir), THERMAL_BASE "/thermal_zone%d", zone);
    ensure_dir(dir);
    snprintf(path, sizeof(path), "%s/type", dir);
    write_text(path, type);
    snprintf(raw_text, sizeof(raw_text), "%d\n", raw);
    snprintf(path, sizeof(path), "%s/temp", dir);
    write_text(path, raw_text);
}

static void write_temp(int zone, int raw) {
    char path[256], raw_text[32];
    snprintf(raw_text, sizeof(raw_text), "%d\n", raw);
    snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/temp", zone);
    write_text(path, raw_text);
}

static void add_three_cpu_peers(int a, int b, int c) {
    add_zone(1, "cpu-1-1-0\n", a);
    add_zone(2, "cpu-0-5-0\n", b);
    add_zone(3, "cpullc-0-0\n", c);
}

static void case_high_socd_rebinds_to_live_peer(void) {
    fixture_reset();
    add_zone(0, "socd\n", 70000);
    add_three_cpu_peers(35000, 36000, 39000);
    thermal_discover();

    check_i("high socd selects real fallback zone", g_thermal_cpu_zone, 1);
    check_s("high socd selects prime peer type", g_thermal_cpu_type, "cpu-1-1-0");
    check_i("high socd confidence is fallback", g_thermal_source_confidence, 1);
    check_s("high socd rejection provenance", g_thermal_rejected_type, "socd");
    check_i("high socd retains raw evidence", g_thermal_rejected_raw, 70000);
    check_i("selected fallback clears runtime fallback zone", g_thermal_cpu_fallback_zone, -1);
}

static void case_valid_socd_is_retained(void) {
    fixture_reset();
    add_zone(0, "socd\n", 58000);
    add_three_cpu_peers(53000, 54000, 56000);
    thermal_discover();

    check_i("valid socd remains control zone", g_thermal_cpu_zone, 0);
    check_s("valid socd remains source", g_thermal_cpu_type, "socd");
    check_i("valid socd is peer-validated", g_thermal_source_confidence, 2);
    check_s("valid socd has no rejection", g_thermal_rejected_type, "");
}

static void case_low_socd_rebinds_symmetrically(void) {
    fixture_reset();
    add_zone(0, "socd\n", 24000);
    add_three_cpu_peers(38000, 39000, 40000);
    thermal_discover();

    check_i("low socd selects real fallback zone", g_thermal_cpu_zone, 1);
    check_i("low socd confidence is fallback", g_thermal_source_confidence, 1);
    check_s("low socd rejection provenance", g_thermal_rejected_type, "socd");
    check_i("low socd retains raw evidence", g_thermal_rejected_raw, 24000);
    check_i("low selected fallback clears runtime fallback zone", g_thermal_cpu_fallback_zone, -1);
}

static void case_rejected_socd_without_valid_fallback_stays_conservative(void) {
    fixture_reset();
    add_zone(0, "socd\n", 50000);
    /* These participate in the peer median but are static extremes, so basic validation
     * must not promote any as a usable control fallback. */
    add_three_cpu_peers(93000, 94000, 95000);
    thermal_discover();

    check_i("no-fallback retains socd control source", g_thermal_cpu_zone, 0);
    check_s("no-fallback keeps socd type", g_thermal_cpu_type, "socd");
    check_i("no-fallback is low confidence", g_thermal_source_confidence, 1);
    check_s("no-fallback publishes rejection", g_thermal_rejected_type, "socd");
    check_i("no-fallback has no runtime peer fallback", g_thermal_cpu_fallback_zone, -1);
}

static void case_no_fallback_recovery_revalidates_socd(void) {
    asb_thermal_t t;
    fixture_reset();
    add_zone(0, "socd\n", 50000);
    add_three_cpu_peers(93000, 94000, 95000);
    thermal_discover();
    check_i("recovery setup retains conservative socd", g_thermal_cpu_zone, 0);
    check_i("recovery setup starts low-confidence", g_thermal_source_confidence, 1);

    write_temp(0, 58000);
    write_temp(1, 53000);
    write_temp(2, 54000);
    write_temp(3, 56000);
    g_last_thermal_rescan = time(NULL) - 61;
    metrics_read_thermal(&t, 0);

    check_i("recovery keeps validated socd control zone", g_thermal_cpu_zone, 0);
    check_i("recovery restores peer-validated confidence", g_thermal_source_confidence, 2);
    check_s("recovery clears stale rejected type", g_thermal_rejected_type, "");
    check_i("recovery clears stale rejected raw", g_thermal_rejected_raw, 0);
    check_i("recovery reports current socd temp", t.cpu_max_c, 58);
}

static void case_non_cpu_peer_never_replaces_cpu_control(void) {
    asb_thermal_t t;
    fixture_reset();
    add_zone(0, "socd\n", 40000);
    add_three_cpu_peers(39000, 40000, 41000);
    add_zone(4, "shell_frame\n", 70000);
    add_zone(5, "sys-therm-6\n", 69000);
    add_zone(6, "board_temp\n", 71000);
    thermal_discover();
    metrics_read_thermal(&t, 0);

    check_i("non-CPU peer leaves CPU control temperature intact", t.cpu_max_c, 40);
    check_i("non-CPU peer captures current board temperature", t.board_temp_c, 71);
    check_i("non-CPU peer consensus has current peers", g_thermal_peer_n, 3);
    check_i("non-CPU peer consensus records hottest evidence", g_thermal_peer_hi, 71);
}

static void case_consensus_clears_when_peers_disappear(void) {
    asb_thermal_t t;
    char path[256];
    fixture_reset();
    add_zone(0, "socd\n", 45000);
    add_three_cpu_peers(44000, 45000, 46000);
    add_zone(4, "shell_frame\n", 42000);
    add_zone(5, "sys-therm-6\n", 43000);
    add_zone(6, "board_temp\n", 44000);
    thermal_discover();
    metrics_read_thermal(&t, 0);
    check_i("consensus setup has peer evidence", g_thermal_peer_n, 3);

    for (int z = 4; z <= 6; z++) {
        snprintf(path, sizeof(path), THERMAL_BASE "/thermal_zone%d/temp", z);
        unlink(path);
    }
    metrics_read_thermal(&t, 0);
    check_i("missing peer sensors clear consensus count", g_thermal_peer_n, 0);
    check_i("missing peer sensors clear consensus high", g_thermal_peer_hi, 0);
    check_i("missing peer sensors clear consensus low", g_thermal_peer_lo, 0);
    check_s("missing peer sensors clear consensus note", g_thermal_consensus_note, "");
}

static void case_periodic_socd_revalidation_recovers(void) {
    asb_thermal_t t;
    fixture_reset();
    add_zone(0, "socd\n", 58000);
    add_three_cpu_peers(53000, 54000, 56000);
    thermal_discover();
    check_i("revalidation setup starts on valid socd", g_thermal_cpu_zone, 0);

    write_temp(0, 70000);
    write_temp(1, 35000);
    write_temp(2, 36000);
    write_temp(3, 39000);
    g_last_thermal_rescan = time(NULL) - 61;
    metrics_read_thermal(&t, 0);

    check_i("periodic rescan rebinds divergent socd", g_thermal_cpu_zone, 1);
    check_i("periodic rescan stays fallback confidence", g_thermal_source_confidence, 1);
    check_s("periodic rescan publishes rejection", g_thermal_rejected_type, "socd");
    check_i("periodic rescan reports live fallback temp", t.cpu_max_c, 35);
}

int main(void) {
    puts("P0 thermal socd validation fixtures");
    case_high_socd_rebinds_to_live_peer();
    case_valid_socd_is_retained();
    case_low_socd_rebinds_symmetrically();
    case_rejected_socd_without_valid_fallback_stays_conservative();
    case_no_fallback_recovery_revalidates_socd();
    case_non_cpu_peer_never_replaces_cpu_control();
    case_consensus_clears_when_peers_disappear();
    case_periodic_socd_revalidation_recovers();

    fixture_reset();
    if (g_failures) {
        printf("failed: %d\n", g_failures);
        return 1;
    }
    puts("passed: thermal socd P0 fixture suite");
    return 0;
}
