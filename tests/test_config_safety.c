#include <stdio.h>
#include <string.h>
#include "../src/asb_config.h"

static int load_text(const char *path, const char *text, asb_runtime_config_t *cfg) {
    FILE *f = fopen(path, "w");
    if (!f) return -99;
    fputs(text, f);
    fclose(f);
    asb_config_defaults(cfg);
    return asb_config_load_file(path, cfg);
}

int main(void) {
    const char *path = "/tmp/asb_config_safety_test.conf";
    asb_runtime_config_t cfg;

    const char *valid =
        "sustained_temp_enter=65\n"
        "sustained_temp_exit=55\n"
        "quiet_tick_s=30\n"
        "quiet_entry_ticks=60\n"
        "quiet_exit_grace=3\n"
        "night_quiet_hour_start=23\n"
        "night_quiet_hour_end=6\n"
        "heavy_min_dwell_s=8\n"
        "sustained_min_dwell_s=24\n"
        "gaming_min_dwell_s=25\n"
        "reassert_heavy_s=12\n"
        "reassert_gaming_s=6\n"
        "perf_hot_guard_ticks=0\n"
        "camera_hold_max_s=180\n"
        "auto_battery_low_pct=20\n"
        "auto_battery_high_pct=30\n"
        "auto_battery_min_gap_s=300\n";

    if (load_text(path, valid, &cfg) != 0) return 1;
    if (load_text(path, "sustained_temp_enter=65\nsustained_temp_enter=64\n", &cfg) != -3) return 2;
    if (load_text(path, "quiet_tick_s=0\n", &cfg) == 0) return 3;
    if (load_text(path, "sustained_temp_enter=40\nsustained_temp_exit=75\n", &cfg) == 0) return 4;
    if (load_text(path, "night_quiet_hour_start=99\n", &cfg) == 0) return 5;

    asb_config_defaults(&cfg);
    cfg.sustained_level = 0.62f;
    cfg.sustained_level_user_set = 1;
    asb_config_apply_burst_override(&cfg);
    if (cfg.sustained_level != 0.62f) return 6;
    asb_config_apply_stable_override(&cfg);
    if (cfg.sustained_level != 0.62f) return 7;

    remove(path);
    puts("PASS config safety");
    return 0;
}
