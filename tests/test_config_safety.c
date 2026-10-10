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
    /* asb_config.h declares this static app-heat flag for the production
     * governor. This standalone parser test does not otherwise consume it;
     * mark it used so GCC -Wall -Wextra -Werror in CI checks the test logic,
     * rather than rejecting an unrelated header-local symbol. */
    (void)g_asb_appheat_hot;

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
    /* The writer has matching shell validation, but the native parser remains
     * the final trust boundary for manual edits and malformed imports. */
    if (load_text(path, "thermal_overlay_pct=999\n", &cfg) == 0) return 6;
    if (load_text(path, "thermal_junction_hard_c=0\n", &cfg) == 0) return 7;
    if (load_text(path, "thermal_skin_c=66\n", &cfg) == 0) return 8;
    if (load_text(path, "camera_busy_pct=0\n", &cfg) == 0) return 9;
    if (load_text(path, "smart_conf_low=700\nsmart_conf_high=650\n", &cfg) == 0) return 10;
    if (load_text(path, "thermal_budget_light_headroom_pct=40\nthermal_budget_moderate_headroom_pct=50\n", &cfg) == 0) return 11;
    if (load_text(path, "thermal_budget_severe_trim_pct=99\n", &cfg) == 0) return 12;
    if (load_text(path, "thermal_budget_dwell_s=0\n", &cfg) == 0) return 13;
    if (load_text(path, "shadow_mode=2\n", &cfg) == 0) return 14;

    /* ASB-01: ceiling and enter must be independent of persisted key order. */
    if (load_text(path, "sustained_temp_ceiling=68\nsustained_temp_enter=65\n", &cfg) != 0 ||
        cfg.sustained_temp_enter != 65 || cfg.sustained_temp_enter_user != 68) return 15;
    if (load_text(path, "sustained_temp_enter=65\nsustained_temp_ceiling=68\n", &cfg) != 0 ||
        cfg.sustained_temp_enter != 65 || cfg.sustained_temp_enter_user != 68) return 16;
    /* A stale/lower ceiling is normalized up to the active safety threshold. */
    if (load_text(path, "sustained_temp_ceiling=62\nsustained_temp_enter=65\n", &cfg) != 0 ||
        cfg.sustained_temp_enter_user != 65) return 17;

    /* ASB-04: manual config/import data reaches native code; malformed values
     * must not silently become zero or a non-finite FSM threshold. */
    if (load_text(path, "heavy_load_enter=nan\n", &cfg) == 0) return 18;
    if (load_text(path, "heavy_load_enter=inf\n", &cfg) == 0) return 19;
    if (load_text(path, "gpu_idle_trim_pct=-100\n", &cfg) == 0) return 20;
    if (load_text(path, "gpu_video_max_pct=999\n", &cfg) == 0) return 21;
    if (load_text(path, "gaming_confirm_ticks=0\n", &cfg) == 0) return 22;
    if (load_text(path, "thermal_throttle_temp=0\n", &cfg) == 0) return 23;
    if (load_text(path, "device_bounds_override=999\n", &cfg) == 0) return 24;

    asb_config_defaults(&cfg);
    cfg.sustained_level = 0.62f;
    cfg.sustained_level_user_set = 1;
    asb_config_apply_burst_override(&cfg);
    if (cfg.sustained_level != 0.62f) return 25;
    asb_config_apply_stable_override(&cfg);
    if (cfg.sustained_level != 0.62f) return 26;

    remove(path);
    puts("PASS config safety");
    return 0;
}
