#!/usr/bin/env bash
# ASB host tests: Audio and DSP, network (LTE, Wi-Fi, GNSS), doze, wakelocks, display and battery.
#
# Each test is a function t_<name> whose body runs in its own subshell, exactly as the
# standalone script it used to be; the C fixtures it builds are the functions _c_<name>.
#   bash tests/asb_features.sh                 run every test in this file
#   bash tests/asb_features.sh NAME [NAME...]  run the named tests
#   bash tests/asb_features.sh --list          list the tests
#   bash tests/asb_features.sh --source NAME   print an embedded C fixture
# tools/asb_full_regression.sh runs every test of every tests/asb_*.sh in parallel.

_c_camera_pcm_native() {
  cat <<'ASB_C_EOF'
/* fix141 native fixture: the camera guard with the screen off, and the PCM playback probe.
 *
 * Includes the production asb_metrics.h (as the thermal fixture does) and drives the real
 * metrics_camera_active() and metrics_pcm_playing(). The "camera provider" is this process:
 * its own CPU time is what the guard samples, so a busy loop makes it look like a streaming
 * pipeline. The PCM tree is a synthetic /proc/asound below /tmp. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define ASOUND_BASE "/tmp/asb_fx141_asound"
#include "asb_metrics.h"

asb_runtime_config_t g_asb_cfg;

static int g_failures;
static void check_i(const char *name, int got, int want) {
    if (got != want) { printf("  FAIL %-52s got=%d want=%d\n", name, got, want); g_failures++; }
    else printf("  ok   %-52s %d\n", name, got);
}

static void burn(double secs) {
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    volatile unsigned long x = 0;
    for (;;) {
        for (int i = 0; i < 200000; i++) x += (unsigned long)i;
        clock_gettime(CLOCK_MONOTONIC, &b);
        if ((b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) * 1e-9 >= secs) break;
    }
}

static int cam_tick(int screen_on) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    g_cam_scr_prev = screen_on;
    return metrics_camera_active(&now);
}

static void put(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (!f) { printf("  FAIL cannot write %s: %s\n", path, strerror(errno)); g_failures++; return; }
    fputs(text, f);
    fclose(f);
}

int main(void) {
    /* --- camera guard --- */
    g_asb_cfg.camera_hold_enable = 1;
    g_asb_cfg.camera_busy_pct = 15;
    g_asb_cfg.camera_hold_grace_s = 20;
    g_cam_pid = getpid();
    g_cam_npid = 0;
    g_cam_scan_ts = time(NULL);
    g_cam_scr_on_since = time(NULL) - 60;   /* well past the unlock window */

    burn(0.1);                   /* a provider with no CPU time at all reads as gone */
    cam_tick(1);                 /* first sample: no previous jiffies yet */
    burn(0.6);
    check_i("screen on, provider busy -> guard on", cam_tick(1), 1);
    check_i("grace armed while the screen is on", g_cam_hold_until > time(NULL), 1);
    burn(0.6);
    check_i("screen off -> guard off at once", cam_tick(0), 0);
    check_i("screen off -> grace tail dropped", (int)g_cam_hold_until, 0);
    burn(0.6);
    check_i("screen still off, provider still busy -> no guard", cam_tick(0), 0);
    check_i("screen off -> provider not sampled", g_cam_jif_prev == 0ULL, 1);
    cam_tick(1);                 /* screen back on: re-baseline */
    burn(0.6);
    check_i("screen on again -> guard works as before", cam_tick(1), 1);

    /* --- PCM playback probe --- */
    if (system("rm -rf " ASOUND_BASE) != 0) { printf("  FAIL cannot clear the fixture\n"); g_failures++; }
    mkdir(ASOUND_BASE, 0755);
    mkdir(ASOUND_BASE "/card0", 0755);
    mkdir(ASOUND_BASE "/card0/pcm0p", 0755);
    mkdir(ASOUND_BASE "/card0/pcm0p/sub0", 0755);
    mkdir(ASOUND_BASE "/card0/pcm1c", 0755);
    mkdir(ASOUND_BASE "/card0/pcm1c/sub0", 0755);
    mkdir(ASOUND_BASE "/card0/pcm12p", 0755);
    mkdir(ASOUND_BASE "/card0/pcm12p/sub0", 0755);
    put(ASOUND_BASE "/card0/pcm0p/sub0/status", "closed\n");
    put(ASOUND_BASE "/card0/pcm12p/sub0/status", "closed\n");
    /* A running CAPTURE stream (a call's microphone, a hotword) is not playback. */
    put(ASOUND_BASE "/card0/pcm1c/sub0/status", "state: RUNNING\nowner_pid   : 1\n");
    g_pcm_npaths = -1;
    check_i("nothing playing (capture running) -> 0", metrics_pcm_playing(), 0);
    check_i("two playback substreams listed", g_pcm_npaths, 2);
    put(ASOUND_BASE "/card0/pcm12p/sub0/status", "state: RUNNING\nowner_pid   : 1234\n");
    check_i("a playback substream running -> 1", metrics_pcm_playing(), 1);
    if (system("rm -rf " ASOUND_BASE) != 0) { printf("  FAIL cannot remove the fixture\n"); g_failures++; }
    g_pcm_npaths = -1;
    check_i("no /proc/asound -> -1 (unknown, every window counts)", metrics_pcm_playing(), -1);

    if (g_failures) { printf("FAIL camera/pcm native: %d check(s)\n", g_failures); return 1; }
    printf("PASS camera/pcm native: no camera guard with the screen off; PCM playback probe\n");
    return 0;
}
ASB_C_EOF
}

t_active_efficiency_contract() (
# Contract: active-use efficiency must be capability-gated, monotonic and reversible.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GEN="$ROOT/runtime/asb_active_efficiency_envelope.sh"
SRC="$ROOT/src/asb_governor.c"
SERVICE="$ROOT/service.sh"
DIAG="$ROOT/tools/asb_diag.sh"
BIN_DIAG="$ROOT/system/bin/asbdiag"
EFFECTIVE="$ROOT/tools/asb_effective_policy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL active-efficiency: $*" >&2; exit 1; }
get() { grep -E "^$1=" "$2" 2>/dev/null | tail -1 | sed 's/^[^=]*=//'; }
mkcaps() {
  cat > "$TMP/device_caps.env" <<EOF
soc_platform=$1
cpu_policy_count=$2
gpu_backend=$3
thermal_zone_count=$4
EOF
}
run_case() {
  _soc="$1" _pol="$2" _gpu="$3" _zones="$4"
  mkcaps "$_soc" "$_pol" "$_gpu" "$_zones"
  ASB_CONFIG_STATE="$TMP" sh "$GEN" >/dev/null 2>&1 || fail "generator execution ($_soc)"
}
assert_monotonic() {
  _light="$(get budget_light_bonus_pct "$TMP/active_efficiency.env")"
  _moderate="$(get budget_moderate_bonus_pct "$TMP/active_efficiency.env")"
  _severe="$(get budget_severe_bonus_pct "$TMP/active_efficiency.env")"
  [ "$_moderate" -ge "$_light" ] 2>/dev/null || fail "nonmonotonic light/moderate envelope"
  [ "$_severe" -ge "$_moderate" ] 2>/dev/null || fail "nonmonotonic moderate/severe envelope"
}

[ -x "$GEN" ] || fail "generator is not executable"
sh -n "$GEN" || fail "generator syntax"

run_case sm8750 2 devfreq 24
[ "$(get status "$TMP/active_efficiency.env")" = "active" ] || fail "SM8750 should be active"
[ "$(get tier "$TMP/active_efficiency.env")" = "sm8750" ] || fail "SM8750 tier"
[ "$(get budget_light_bonus_pct "$TMP/active_efficiency.env")" = "1" ] || fail "SM8750 light bonus"
[ "$(get budget_moderate_bonus_pct "$TMP/active_efficiency.env")" = "2" ] || fail "SM8750 moderate bonus"
[ "$(get budget_severe_bonus_pct "$TMP/active_efficiency.env")" = "2" ] || fail "SM8750 severe bonus"
assert_monotonic

run_case sm8850 2 pwrlevel 98
[ "$(get status "$TMP/active_efficiency.env")" = "active" ] || fail "SM8850 should be active"
[ "$(get tier "$TMP/active_efficiency.env")" = "sm8850" ] || fail "SM8850 tier"
[ "$(get budget_moderate_bonus_pct "$TMP/active_efficiency.env")" = "2" ] || fail "SM8850 moderate bonus"
[ "$(get budget_severe_bonus_pct "$TMP/active_efficiency.env")" = "2" ] || fail "SM8850 severe bonus"
assert_monotonic

run_case sm8650 3 pwrlevel 22
[ "$(get status "$TMP/active_efficiency.env")" = "active" ] || fail "SM8650 should be active"
[ "$(get tier "$TMP/active_efficiency.env")" = "sm8650" ] || fail "SM8650 tier"
[ "$(get budget_moderate_bonus_pct "$TMP/active_efficiency.env")" = "3" ] || fail "SM8650 moderate bonus"
[ "$(get bg_uclamp_moderate_delta "$TMP/active_efficiency.env")" = "64" ] || fail "SM8650 bg moderate delta"
[ "$(get bg_uclamp_severe_delta "$TMP/active_efficiency.env")" = "128" ] || fail "SM8650 bg severe delta"
[ "$(get budget_severe_bonus_pct "$TMP/active_efficiency.env")" = "3" ] || fail "SM8650 severe bonus"
assert_monotonic

run_case sm8550 3 devfreq 20
[ "$(get status "$TMP/active_efficiency.env")" = "active" ] || fail "SM8550 should be active"
[ "$(get tier "$TMP/active_efficiency.env")" = "sm8550" ] || fail "SM8550 tier"
[ "$(get gpu_idle_trim_bonus_pct "$TMP/active_efficiency.env")" = "1" ] || fail "SM8550 gpu bonus"
assert_monotonic

# A complete but unnamed platform gets only the universal capability baseline: it is
# percentage/uclamp-only and strictly smaller than family-specific tiers.
run_case sm9999 3 devfreq 20
[ "$(get status "$TMP/active_efficiency.env")" = "active" ] || fail "complete unknown SoC should use capability baseline"
[ "$(get tier "$TMP/active_efficiency.env")" = "capability" ] || fail "capability baseline tier"
[ "$(get reason "$TMP/active_efficiency.env")" = "capability_baseline" ] || fail "capability baseline reason"
[ "$(get budget_moderate_bonus_pct "$TMP/active_efficiency.env")" = "1" ] || fail "capability baseline moderate bonus"
[ "$(get bg_uclamp_moderate_delta "$TMP/active_efficiency.env")" = "32" ] || fail "capability baseline bg delta"
assert_monotonic

run_case sm8650 1 devfreq 20
[ "$(get status "$TMP/active_efficiency.env")" = "generic" ] || fail "insufficient CPU topology must be no-op"
[ "$(get reason "$TMP/active_efficiency.env")" = "missing_cpu_gpu_or_thermal_capability" ] || fail "missing capability reason"

# No raw frequency/voltage writes belong in the derived policy generator.
if sed '/^[[:space:]]*#/d' "$GEN" | grep -Eqi 'undervolt|voltage|scaling_max_freq|khz'; then
  fail "generator must remain percentage/uclamp-only"
fi

# Native loader is strict; policy stays inside established thermal/GPU exclusions.
grep -Fq 'ACTIVE_EFFICIENCY_FILE' "$SRC" || fail "native manifest path missing"
grep -Fq 'asb_active_efficiency_load();' "$SRC" || fail "native loader not called"
grep -Fq 'strcmp(g_active_efficiency.tier, "sm8850")' "$SRC" || fail "native SM8850 tier allowlist missing"
grep -Fq 'strcmp(g_active_efficiency.tier, "capability")' "$SRC" || fail "native capability tier allowlist missing"
grep -Fq 'manifest_nonmonotonic' "$SRC" || fail "native monotonic guard missing"
grep -Fq 'fsm->profile_idx != PROFILE_PERFORMANCE' "$SRC" || fail "GPU performance exclusion missing"
grep -Fq 'fsm->state == ASB_STATE_SUSTAINED' "$SRC" || fail "platform thermal exclusion missing"
grep -Fq 'if (target < 128) target = 128;' "$SRC" || fail "background uclamp floor missing"
grep -Fq '!g_asb_cfg.thermal_budget_enable || !g_active_efficiency.active' "$SRC" || fail "thermal budget user opt-out gate missing"
# Screen-on comfort may only add the already-configured light trim with fresh foreground
# evidence. It must fail closed outside Battery/known light-or-medium Smart and never touch
# gaming, camera, charging or sleep.
grep -Fq '"screenon_comfort"' "$SRC" || fail "screen-on comfort reason missing"
grep -Fq 'm->misc.screen_on && !m->misc.camera_active' "$SRC" || fail "screen-on/camera exclusion missing"
grep -Fq 'fsm->state != ASB_STATE_GAMING' "$SRC" || fail "gaming exclusion missing"
grep -Fq 'if (g_asb_cfg.thermal_budget_enable && !fsm->thermal_cap &&' "$SRC" || fail "comfort path must remain thermal-cap gated"
grep -Fq 'fsm->state != ASB_STATE_SUSTAINED) {' "$SRC" || fail "SUSTAINED game-safety exclusion missing"
grep -Fq 'fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled && g_pkg_detect_ok' "$SRC" || fail "Smart comfort fresh-context gate missing"
grep -Fq 'g_smart_rt.app_hint <= ASB_APP_MEDIUM' "$SRC" || fail "Smart comfort light/medium app gate missing"
grep -Fq 'int comfort_current_ma = g_asb_cfg.smart_battery_bias >= 400 ? 250 :' "$SRC" || fail "Smart/Battery comfort current split missing"
grep -Fq '(smart_screenon_comfort ? 350 : 450);' "$SRC" || fail "Smart moderate-current comfort threshold missing"
grep -Fq 'asb_ma_ref(_cma) >= (_cin ? comfort_current_ma * 4 / 5 : comfort_current_ma)' "$SRC" || fail "adaptive comfort current evidence gate missing (smoothed, with exit band - fix121)"
grep -Fq 'screenon_comfort_smart_medium' "$SRC" || fail "early Smart comfort telemetry reason missing"
# Repeated field captures permit an earlier Smart-only light trim only for a high-current,
# positively classified light/medium foreground context. It must never become a generic cap.
grep -Fq 'int smart_high_current_comfort =' "$SRC" || fail "high-current Smart comfort guard missing"
grep -Fq 'screenon_comfort_smart_high_current' "$SRC" || fail "high-current Smart comfort telemetry reason missing"
grep -Fq 'asb_ma_ref(_cma) >= (_cin ? 480 : 600)' "$SRC" || fail "high-current Smart evidence threshold missing (600 mA entry, fix121 exit band)"
grep -Fq 'm->therm.cpu_max_c >= (_cin ? 40 : 42)' "$SRC" || fail "high-current Smart warmth floor missing (42 C entry, fix121 exit band)"
grep -Fq 'm->gpu.load_pct < g_asb_cfg.heavy_gpu_enter' "$SRC" || fail "high-current Smart low-GPU exclusion missing"
grep -Fq 'fsm->state != ASB_STATE_GAMING && fsm->state != ASB_STATE_SUSTAINED' "$SRC" || fail "high-current Smart game/sustained exclusion missing"
grep -Fq 'surface_comfort_smart' "$SRC" || fail "surface-hotspot Smart comfort telemetry reason missing"
grep -Fq 'surface_comfort_smart_sustained' "$SRC" || fail "light SUSTAINED Smart surface-comfort telemetry reason missing"
grep -Fq 'int surface_comfort_sustained =' "$SRC" || fail "light SUSTAINED Smart comfort gate missing"
grep -Fq 'g_smart_rt.app_hint <= ASB_APP_MEDIUM' "$SRC" || fail "SUSTAINED comfort must stay below heavy/gaming app hint"
grep -Fq 'm->gpu.load_valid' "$SRC" || fail "SUSTAINED comfort requires valid GPU evidence"
# The surface-comfort gate now has an entry/exit band instead of one bare threshold.
#
# It was pinned at >= 43, and a field capture showed why that number was wrong: mean
# surface temperature across 122 phases was exactly 43 C, so the 20% ceiling trim was
# engaged essentially all the time on a phone reported as running hotter and draining
# faster WITH the module than without. A trim that never lifts makes every task longer,
# and a longer task keeps the cores, panel and radio awake for all of it.
#
# What the contract protects is that the gate exists, is driven by surface temperature,
# and has hysteresis - not one particular degree. Pinning the exact value made the test
# fail on the fix rather than on a regression.
grep -Eq 'surface_hotspot_c >= \(g_budget_surface_engaged \? [0-9]+ : [0-9]+\)' "$SRC" \
  || fail "surface-hotspot Smart comfort threshold missing or lost its hysteresis"
grep -Fq 'g_budget_surface_engaged' "$SRC" \
  || fail "surface-comfort hysteresis state missing"
grep -Fq 'g_asb_cfg.thermal_budget_moderate_trim_pct' "$SRC" || fail "surface-hotspot path must reuse bounded moderate trim"
grep -Fq 'smart_screenon_comfort && !m->bat.charging && m->misc.screen_on' "$SRC" || fail "surface comfort charging/screen exclusion missing"
grep -Fq '!m->misc.camera_active && fsm->state != ASB_STATE_GAMING' "$SRC" || fail "surface comfort camera/gaming exclusion missing"
grep -Fq 'fsm->profile_idx == PROFILE_BATTERY' "$SRC" || fail "Battery profile gate missing"
grep -Fq 'g_asb_cfg.smart_battery_bias >= 400' "$SRC" || fail "battery-lean Smart gate missing"
# Media recovery may use the existing light trim only after fresh, positively recognised media
# context. Every QoS/liveness exclusion is independent and must remain explicit.
grep -Fq '"media_recovery"' "$SRC" || fail "media recovery reason missing"
grep -Fq 'fsm->state == ASB_STATE_SUSTAINED' "$SRC" || fail "media recovery sustained gate missing"
grep -Fq 'fsm->profile_idx == PROFILE_SMART && g_smart_rt.enabled' "$SRC" || fail "media recovery Smart gate missing"
grep -Fq 'g_pkg_detect_ok && g_smart_media_pkg_known' "$SRC" || fail "media recovery fresh-media gate missing"
grep -Fq 'g_smart_rt.app_hint < ASB_APP_GAMING' "$SRC" || fail "media recovery game exclusion missing"
grep -Fq '!m->misc.camera_active && !m->bat.charging' "$SRC" || fail "media recovery camera/charging exclusion missing"
grep -Fq 'asb_ma_ref(m->bat.current_ma) >= 450' "$SRC" || fail "media recovery current evidence gate missing"
grep -Fq 'smart_screenon_comfort ? "screenon_comfort_smart_medium" : "screenon_comfort"' "$SRC" || fail "Smart comfort must retain Battery reason split"
grep -Fq 'media_recovery = !strcmp(g_budget_reason, "media_recovery")' "$SRC" || fail "media recovery must recheck dwell-held reason"
grep -Fq 'fsm->state == ASB_STATE_SUSTAINED && !media_recovery' "$SRC" || fail "SUSTAINED must stay blocked outside fresh media recovery"
grep -Fq '(!media_recovery && g_budget_stage < 2)' "$SRC" || fail "light-stage cgroup recovery gate missing"
grep -Fq 'Foreground/top-app caps are deliberately untouched' "$SRC" || fail "media recovery foreground QoS guarantee missing"
grep -Fq 'active_efficiency_active=%d' "$SRC" || fail "state telemetry missing"

# The derived manifest must exist before asb_utils.sh starts the governor.
_pre="$(grep -n 'asb_active_efficiency_envelope.sh' "$SERVICE" | head -1 | cut -d: -f1)"
_utils="$(grep -n 'runtime/asb_utils.sh' "$SERVICE" | head -1 | cut -d: -f1)"
[ -n "$_pre" ] && [ -n "$_utils" ] && [ "$_pre" -lt "$_utils" ] || fail "manifest is not prepared before governor start"

grep -Fq 'active-use envelope' "$DIAG" || fail "diagnostic envelope section missing"
grep -Fq 'active-use runtime' "$DIAG" || fail "diagnostic runtime telemetry missing"
grep -Fq 'Vendor already holds a stricter CPU ceiling' "$DIAG" || fail "cooperative vendor ceiling verdict missing"
grep -Fq '"active_efficiency"' "$EFFECTIVE" || fail "effective-policy JSON telemetry missing"
grep -Fq 'thermal_budget_envelope_bonus_pct' "$EFFECTIVE" || fail "effective-policy staged budget telemetry missing"
cmp -s "$DIAG" "$BIN_DIAG" || fail "asbdiag copies differ"

echo "PASS active-efficiency capability contract"
)

t_active_wifi_fallback_runtime() (
# Runtime fixture for the bounded poor-Wi-Fi fallback. Android commands are mocked so this
# verifies framework-validation gates and lifecycle ownership without touching a real radio.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wifi_fallback.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'if [[ -n "${WPID:-}" ]]; then kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/mod/runtime" "$TMP/mod/config" "$TMP/bin" "$TMP/state"
cp "$SRC" "$TMP/mod/runtime/asb_wifi_fallback.sh"
printf 'radio_policy_enable=1\nnet_wifi_leave=aggressive\n' > "$TMP/mod/config/governor.conf"
cat > "$TMP/bin/dumpsys" <<'EOF'
#!/bin/sh
case "$1" in
  power) printf '%s\n' 'mWakefulness=Awake' ;;
  wifi) cat "$ASB_WIFI_DUMP" ;;
  *) : ;;
esac
EOF
cat > "$TMP/bin/settings" <<'EOF'
#!/bin/sh
case "$1:$2" in
  get:global)
    case "$3" in airplane_mode_on) echo 0 ;; mobile_data) echo 1 ;; *) echo null ;; esac ;;
esac
EOF
cat > "$TMP/bin/ip" <<'EOF'
#!/bin/sh
[ "$1" = route ] && [ "$2" = get ] && printf '%s\n' '1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.9'
EOF
cat > "$TMP/bin/svc" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ASB_SVC_LOG"
EOF
chmod 0755 "$TMP/bin/dumpsys" "$TMP/bin/settings" "$TMP/bin/ip" "$TMP/bin/svc"
export PATH="$TMP/bin:$PATH" ASB_WIFI_DUMP="$TMP/wifi.dump" ASB_SVC_LOG="$TMP/svc.log"
export ASB_WIFI_FALLBACK_STATE_DIR="$TMP/state"
run() {
  MODDIR="$TMP/mod" ASB_WIFI_FALLBACK_INTERVAL_S=1 ASB_WIFI_FALLBACK_RELEASE_S=2 ASB_WIFI_FALLBACK_COOLDOWN_S=4 \
    sh "$TMP/mod/runtime/asb_wifi_fallback.sh" "$@"
}
wait_for() {
  local f="$1" n="${2:-50}"
  while (( n > 0 )); do [ -e "$f" ] && return 0; sleep 0.1; ((n--)); done
  return 1
}
wait_for_line() {
  local want="$1" f="$2" n="${3:-80}"
  while (( n > 0 )); do grep -qx "$want" "$f" 2>/dev/null && return 0; sleep 0.1; ((n--)); done
  return 1
}
wait_for_absent() {
  local f="$1" n="${2:-50}"
  while (( n > 0 )); do [ ! -e "$f" ] && return 0; sleep 0.1; ((n--)); done
  return 1
}

# A healthy Wi-Fi default route never gets released merely because it is default. reconcile
# starts one detached watcher and a second reconcile must preserve the exact same watcher.
printf '%s\n' 'NetworkInfo: VALIDATED=true' > "$TMP/wifi.dump"
run reconcile
wait_for "$TMP/state/wifi_fallback.pid" || fail 'reconcile did not start watcher'
WPID="$(cat "$TMP/state/wifi_fallback.pid")"
kill -0 "$WPID" 2>/dev/null || fail 'recorded watcher is not alive'
# A shell may exec this script and omit the literal `sh` token from cmdline. Lifecycle
# ownership must depend on the exact ASB script and watch argument, not its interpreter name.
_cmdline="$(tr '\000' ' ' < "/proc/$WPID/cmdline" 2>/dev/null)"
case "$_cmdline" in *"$TMP/mod/runtime/asb_wifi_fallback.sh watch"*) : ;; *) fail 'watcher argv lacks exact script plus watch argument' ;; esac
sleep 0.3
[ ! -s "$TMP/svc.log" ] || fail 'released validated Wi-Fi'
run reconcile
wait_for "$TMP/state/wifi_fallback.pid" || fail 'reconcile lost watcher PID'
[ "$(cat "$TMP/state/wifi_fallback.pid")" = "$WPID" ] || fail 'reconcile spawned duplicate watcher'
[ "$(find "$TMP/state" -maxdepth 1 -type d -name 'wifi_fallback.watch.lock' | wc -l | tr -d ' ')" = 1 ] || fail 'watcher lock missing or duplicated'

# Android-owned non-validation evidence while wlan0 is default releases once, then restores.
printf '%s\n' 'NetworkInfo: VALIDATED=false' > "$TMP/wifi.dump"
wait_for_line 'wifi disable' "$TMP/svc.log" || fail 'did not release unvalidated default Wi-Fi'
wait_for_line 'wifi enable' "$TMP/svc.log" || fail 'did not restore Wi-Fi after bounded release'
[ "$(grep -cx 'wifi disable' "$TMP/svc.log")" -eq 1 ] || fail 'repeated Wi-Fi release during cooldown'

# Turning the feature off via reconcile terminates its watcher and clears only ASB state.
printf 'radio_policy_enable=1\nnet_wifi_leave=off\n' > "$TMP/mod/config/governor.conf"
run reconcile
wait_for_absent "$TMP/state/wifi_fallback.pid" || fail 'stale watcher PID after OFF'
wait_for_absent "$TMP/state/wifi_fallback.watch.lock" || fail 'stale watcher lock after OFF'
kill -0 "$WPID" 2>/dev/null && fail 'reconcile OFF did not stop watcher'
[ "$(grep -cx 'wifi disable' "$TMP/svc.log")" -eq 1 ] || fail 'fallback acted after explicit off'
unset WPID

# If OFF happens during an ASB-owned release window, reconcile returns Wi-Fi immediately.
# The arming gate applies here too: a fresh watcher only acts on an attachment that has
# validated at least once, so this phase must let the link validate before it breaks.
printf 'radio_policy_enable=1\nnet_wifi_leave=aggressive\n' > "$TMP/mod/config/governor.conf"
printf '%s\n' 'NetworkInfo: VALIDATED=true' > "$TMP/wifi.dump"
run reconcile
# The log persists across phases, so a stale 'armed' line proves nothing about THIS
# watcher. Give the fresh watcher two full passes (INTERVAL_S=1) to arm on the validated
# link before it breaks.
# Wait for the watcher to actually take a pass, not for a fixed two seconds.
#
# The old "sleep 2" assumed two INTERVAL_S=1 passes fit in two seconds of wall clock. On a
# loaded machine they do not, and the test failed in the full suite while passing on its
# own - twice, and both times the first suspicion was a real regression. Wait for the
# watcher's own evidence instead: the state file it writes once it has armed.
wait_for "$TMP/state/wifi_fallback.confirm" 100 || sleep 2
printf '%s\n' 'NetworkInfo: VALIDATED=false' > "$TMP/wifi.dump"
wait_for "$TMP/state/wifi_fallback.action" || fail 'did not enter owned release window'
WPID="$(cat "$TMP/state/wifi_fallback.pid")"
printf 'radio_policy_enable=1\nnet_wifi_leave=off\n' > "$TMP/mod/config/governor.conf"
run reconcile
wait_for_absent "$TMP/state/wifi_fallback.action" || fail 'OFF did not clear ASB action marker after restore'
wait_for_absent "$TMP/state/wifi_fallback.pid" || fail 'watcher PID remained after active-window OFF'
wait_for_absent "$TMP/state/wifi_fallback.watch.lock" || fail 'watcher lock remained after active-window OFF'
[ "$(grep -cx 'wifi enable' "$TMP/svc.log")" -ge 2 ] || fail 'OFF did not return ASB-owned Wi-Fi'
kill -0 "$WPID" 2>/dev/null && fail 'watcher survived active-window OFF'
unset WPID

# A network that NEVER validated must never be touched: this is the field-reported loop
# where a watcher started at boot met validation-pending (or a blocked-region router whose
# connectivity check never succeeds) and kept killing Wi-Fi forever. The fallback may only
# act on an attachment that proved it can validate at least once.
rm -f "$TMP/svc.log"
printf 'radio_policy_enable=1\nnet_wifi_leave=aggressive\n' > "$TMP/mod/config/governor.conf"
printf '%s\n' 'NetworkInfo: VALIDATED=false' > "$TMP/wifi.dump"
run reconcile
wait_for "$TMP/state/wifi_fallback.pid" || fail 'reconcile did not start watcher for never-validated case'
WPID="$(cat "$TMP/state/wifi_fallback.pid")"
sleep 5
[ ! -s "$TMP/svc.log" ] || fail 'released a Wi-Fi attachment that never validated'
[ ! -e "$TMP/state/wifi_fallback.action" ] || fail 'actioned a Wi-Fi attachment that never validated'
printf 'radio_policy_enable=1\nnet_wifi_leave=off\n' > "$TMP/mod/config/governor.conf"
run reconcile
# Same race as above: the OFF signal is delivered, the watcher exits on its next pass.
# Checking the PID the instant reconcile returns failed about one run in three under load.
wait_for_absent "$TMP/state/wifi_fallback.pid" || true
_wv=0; while kill -0 "$WPID" 2>/dev/null && [ "$_wv" -lt 50 ]; do sleep 0.1; _wv=$((_wv + 1)); done
kill -0 "$WPID" 2>/dev/null && fail 'never-validated watcher survived OFF'
unset WPID

# Model an Android shell that execs the script directly: no literal `sh` argument precedes
# the script, yet the ASB-owned exact path and `watch` role remain verifiable through /proc.
mkdir -p "$TMP/proc/4242"
printf '%s\0' "$TMP/mod/runtime/asb_wifi_fallback.sh" watch > "$TMP/proc/4242/cmdline"
sed -n '/^_pid_is_our_watcher() {/,/^}/p' "$SRC" > "$TMP/pid_identity.sh"
PROC_ROOT="$TMP/proc" MODDIR="$TMP/mod"
. "$TMP/pid_identity.sh"
_pid_is_our_watcher 4242 || fail 'direct-exec watcher identity was not accepted'
printf '%s\0' '/data/local/tmp/asb_wifi_fallback.sh' watch > "$TMP/proc/4242/cmdline"
if _pid_is_our_watcher 4242; then
  fail 'same-basename non-module watcher was accepted'
fi

# Source-visible bounds prevent malformed host overrides from becoming a production busy loop.
grep -Fq '_valid_seconds "$_raw_interval" 1 120' "$SRC" || fail 'interval override is not bounded'
grep -Fq '_valid_seconds "$_raw_release" 1 120' "$SRC" || fail 'release override is not bounded'
grep -Fq '_valid_seconds "$_raw_cooldown" 1 3600' "$SRC" || fail 'cooldown override is not bounded'
grep -Fq 'PROC_ROOT="${ASB_WIFI_FALLBACK_PROC_ROOT:-/proc}"' "$SRC" || fail 'watcher proc root is not injectable for portability fixtures'
grep -Fq '*"$MODDIR/runtime/asb_wifi_fallback.sh watch"*) return 0 ;;' "$SRC" || fail 'watcher identity is not exact script plus watch argument'
if grep -Fq '*"sh $MODDIR/runtime/asb_wifi_fallback.sh watch"*)' "$SRC"; then
  fail 'watcher identity still requires a literal sh interpreter token'
fi
echo 'PASS: active Wi-Fi fallback runtime'
)

t_anim_scale_ownership_runtime() (
# Runtime (fix128): ASB gives the animation scales back once, then leaves them alone.
#
# Field report (OP15, V64): animations removed in Android, ASB's animation options tried and
# switched off again - and the scale returned to 1.0x again and again, through reboots. With
# "UI speed" off, asb_apply_ux restored its saved baseline on EVERY call whenever the live
# value differed from it, and a baseline holding a profile scale (0.8/0.9) was rewritten as
# 1.0 - so the user's own 0 was "corrected" back to 1.0 forever. The OP15 diag of the author
# shows the other half: anim_speed=3 (0.85x) chosen in the WebUI, live scale 0.9 - the
# profile's - because the profile pass overwrote the explicit choice.
# The REAL asb_apply_ux is cut out of profile_core.sh and run against a fake settings store.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL anim ownership: $*" >&2; exit 1; }
MD="$T/mod"; DD="$T/data"; ST="$T/settings"
mkdir -p "$MD/config" "$MD/runtime" "$DD" "$ST" "$T/bin"
cp "$ROOT/runtime/asb_anim_apply.sh" "$MD/runtime/"
cat > "$T/bin/settings" <<'X'
#!/bin/sh
d="$ASB_FAKE_SETTINGS"
case "$1" in
  get) cat "$d/$2.$3" 2>/dev/null || echo null ;;
  put) printf '%s\n' "$4" > "$d/$2.$3"; echo "$2.$3=$4" >> "$d/writes.log" ;;
  delete) rm -f "$d/$2.$3" ;;
esac
X
chmod +x "$T/bin/settings"
export PATH="$T/bin:$PATH" ASB_FAKE_SETTINGS="$ST"
sed -n '/^asb_apply_ux() {/,/^}/p' "$ROOT/runtime/profile_core.sh" > "$T/ux.sh"
[ -s "$T/ux.sh" ] || fail "asb_apply_ux not found"

conf() {   # $1 UX_MANAGE_TIMEOUTS  $2 anim_speed
  printf 'UX_MANAGE_TIMEOUTS=%s\nUX_MANAGE_OEM_TOGGLES=0\nanim_speed=%s\ndisable_blur=0\n' "$1" "$2" > "$MD/config/governor.conf"
}
scale() { printf '%s\n' "$1" > "$ST/global.window_animation_scale"; printf '%s\n' "$1" > "$ST/global.transition_animation_scale"; printf '%s\n' "$1" > "$ST/global.animator_duration_scale"; }
live() { cat "$ST/global.window_animation_scale"; }
apply() {
  ( MODDIR="$MD" ASB_DATA_DIR="$DD" UX_ANIM_SCALE=0.9 sh -c '
      asb_feature_enabled() { return 0; }; has() { command -v "$1" >/dev/null 2>&1; }
      asb_settings_put() { settings put "$1" "$2" "$3"; }
      asb_ram_expand_apply() { :; }
      . "$1"; asb_apply_ux' x "$T/ux.sh" ) >/dev/null 2>&1
}

# 1. UI speed on: the profile scale is applied, the user's own value saved first.
scale 0; conf 1 -1; apply
[ "$(live)" = 0.9 ] || fail "managed scale not applied: $(live)"
grep -q '^BASE_WIN_ANIM=0$' "$MD/config/ux_baseline.conf" || fail "user's own scale not saved"
# 2. Switched off: given back once, then the baseline is gone.
conf 0 -1; apply
[ "$(live)" = 0 ] || fail "user's scale not restored: $(live)"
[ -f "$MD/config/ux_baseline.conf" ] && fail "baseline kept after the restore"
# 3. Afterwards ASB never touches it - whatever the user picks.
scale 1.5; : > "$ST/writes.log"
apply; apply; apply
[ "$(live)" = 1.5 ] || fail "ASB changed a scale it no longer manages: $(live)"
[ -s "$ST/writes.log" ] && fail "settings written while unmanaged: $(cat "$ST/writes.log")"
# 4. The field case: a baseline from an older build (a profile 0.8, read as 1.0), no record of
#    what ASB wrote, and the user's "remove animations" (0). Hands off, every time.
rm -rf "$DD"; mkdir -p "$DD"
printf 'BASE_WIN_ANIM=0.8\nBASE_TRANS_ANIM=0.8\nBASE_DUR_ANIM=0.8\n' > "$MD/config/ux_baseline.conf"
scale 0; conf 0 -1
apply; apply; apply
[ "$(live)" = 0 ] || fail "user's 0 overwritten (the 1.0x every few seconds report): $(live)"
[ -f "$MD/config/ux_baseline.conf" ] && fail "stale baseline kept"
# 5. ...but a scale an older build left behind (0.9) is still given back to stock, once.
rm -rf "$DD"; mkdir -p "$DD"
printf 'BASE_WIN_ANIM=1\nBASE_TRANS_ANIM=1\nBASE_DUR_ANIM=1\n' > "$MD/config/ux_baseline.conf"
scale 0.9; apply
[ "$(live)" = 1 ] || fail "older build's 0.9 not restored: $(live)"
# 6. No baseline at all: the legacy 0.8/0.9 cleanup runs once, then a user's own 0.8 stays.
rm -rf "$DD"; mkdir -p "$DD"; rm -f "$MD/config/ux_baseline.conf"
scale 0.8; apply
[ "$(live)" = 1.0 ] || fail "legacy cleanup did not run: $(live)"
scale 0.8; apply
[ "$(live)" = 0.8 ] || fail "user's own 0.8 reset by the legacy cleanup: $(live)"
# 7. An explicit Animation Speed wins over the profile (anim_speed=3 is 0.85x).
rm -rf "$DD"; mkdir -p "$DD"; rm -f "$MD/config/ux_baseline.conf"
scale 1; conf 1 3; apply
[ "$(live)" = 0.85 ] || fail "profile overwrote the explicit speed: $(live)"
: > "$ST/writes.log"; apply
[ -s "$ST/writes.log" ] && fail "explicit speed rewritten although already set"

echo "PASS anim ownership: given back once, never fought afterwards, explicit speed wins"
)

t_aod_screen_runtime() (
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
)

t_audio_prop_tweaks_runtime() (
# Runtime (fix155): the two audio tweaks applied through system properties.
#
# Resampler Quality and Media Volume Steps are read by Android only when the audio server
# and the audio service start, so ASB sets them before Android starts (post-fs-data) and the
# cards say "reboot to apply". The REAL blocks run here with a fake resetprop / getprop /
# dumpsys:
#   - stock writes nothing at all, and neither does an unknown value;
#   - high and max write the full filter set, max the stronger one, from 44.1 kHz up;
#   - 30 and 50 write the volume steps, any other number does not;
#   - with the audio category off nothing is written;
#   - the action screen and asbdiag tell "live", "after the next reboot" and "this ROM
#     ignores it" apart, reading the media steps from the STREAM_MUSIC block only.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL audio prop tweaks: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PFD="$ROOT/post-fs-data.sh"
_s="$(grep -n "_rs_q=\"\$(grep -E '\^\[\[:space:\]\]\*audio_resampler='" "$PFD" | head -1 | cut -d: -f1)"
[ -n "$_s" ] || fail "post-fs-data does not read audio_resampler"
_s=$((_s - 2))
_e="$(awk -v s="$_s" 'NR>s && /^fi$/ {print NR; exit}' "$PFD")"
sed -n "${_s},${_e}p" "$PFD" > "$T/block.sh"
grep -q 'asb_feature_enabled AUDIO' "$T/block.sh" || fail "the prop block is not gated on the audio category"
grep -q 'asb_device_pack_allows properties' "$T/block.sh" || fail "the prop block ignores the device pack"
mkdir -p "$T/bin" "$T/mod/config"
cat > "$T/bin/resetprop" <<'S'
#!/bin/sh
echo "$*" >> "$RP_LOG"
S
chmod +x "$T/bin/resetprop"
run_pfd() {
  : > "$T/rp"
  printf '%s\n' "$1" > "$T/mod/config/governor.conf"
  PATH="$T/bin:$PATH" MODDIR="$T/mod" RP_LOG="$T/rp" AUDIO_ON="${2:-1}" sh -c '
    asb_feature_enabled() { [ "$1" = AUDIO ] && [ "$AUDIO_ON" = 1 ]; }
    asb_device_pack_allows() { return 0; }
    . "$0"' "$T/block.sh"
}
run_pfd "audio_resampler=stock
media_vol_steps=stock"
[ ! -s "$T/rp" ] || fail "stock wrote properties: $(cat "$T/rp")"
run_pfd "audio_resampler=ultra
media_vol_steps=250"
[ ! -s "$T/rp" ] || fail "an unknown value wrote properties: $(cat "$T/rp")"
run_pfd "audio_resampler=stock
media_vol_steps=12"
[ ! -s "$T/rp" ] || fail "fewer steps than stock were written: $(cat "$T/rp")"
run_pfd "audio_resampler=stock
media_vol_steps=7x"
[ ! -s "$T/rp" ] || fail "a malformed step count was written: $(cat "$T/rp")"
run_pfd "audio_resampler=stock
media_vol_steps=75"
[ "$(cat "$T/rp")" = "-n ro.config.media_vol_steps 75" ] || fail "a slider value (75) not written: $(cat "$T/rp")"
run_pfd "audio_resampler=stock
media_vol_steps=100"
[ "$(cat "$T/rp")" = "-n ro.config.media_vol_steps 100" ] || fail "the slider maximum (100) not written: $(cat "$T/rp")"
run_pfd "audio_resampler=high
media_vol_steps=stock"
[ "$(cat "$T/rp")" = "-n ro.audio.resampler.psd.enable_at_samplerate 44100
-n ro.audio.resampler.psd.stopband 140
-n ro.audio.resampler.psd.halflength 160
-n ro.audio.resampler.psd.cutoff_percent 100" ] || fail "high: $(cat "$T/rp")"
run_pfd "  audio_resampler=max
media_vol_steps=30"
grep -qx -- '-n ro.audio.resampler.psd.stopband 179' "$T/rp" || fail "max stopband: $(cat "$T/rp")"
grep -qx -- '-n ro.audio.resampler.psd.halflength 320' "$T/rp" || fail "max length: $(cat "$T/rp")"
grep -qx -- '-n ro.audio.resampler.psd.cutoff_percent 99' "$T/rp" || fail "max cutoff: $(cat "$T/rp")"
grep -qx -- '-n ro.config.media_vol_steps 30' "$T/rp" || fail "30 steps not written: $(cat "$T/rp")"
for hl in 160 320; do [ $((hl % 4)) -eq 0 ] || fail "half length $hl is not a multiple of 4"; done
run_pfd "audio_resampler=stock
media_vol_steps=50"
[ "$(cat "$T/rp")" = "-n ro.config.media_vol_steps 50" ] || fail "50 steps: $(cat "$T/rp")"
run_pfd "audio_resampler=max
media_vol_steps=50" 0
[ ! -s "$T/rp" ] || fail "audio category off still wrote: $(cat "$T/rp")"
cat > "$T/dumpsys_audio" <<'S'
Stream volumes (device: index)
- STREAM_VOICE_CALL:
   Muted: false
   Min: 1
   Max: 5
- STREAM_RING:
   Muted: false
   Min: 0
   Max: 7
- STREAM_MUSIC:
   Muted: false
   Muted Internally: false
   Min: 0
   Max: __MAX__
   streamVolume:6
   Current: 2 (speaker): 6, 4 (headset): 9
- STREAM_ALARM:
   Muted: false
   Min: 1
   Max: 7
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = audio ] && sed "s/__MAX__/$FAKE_MAX/" "$FAKE_DUMP"
exit 0
S
cat > "$T/bin/getprop" <<'S'
#!/bin/sh
case "$1" in
  ro.audio.resampler.psd.stopband) printf '%s\n' "${FAKE_SB:-}" ;;
  ro.audio.resampler.psd.halflength) printf '%s\n' "${FAKE_HL:-}" ;;
  ro.audio.resampler.psd.enable_at_samplerate) printf '%s\n' "${FAKE_EN:-}" ;;
  ro.config.media_vol_steps) printf '%s\n' "${FAKE_VS:-}" ;;
esac
S
chmod +x "$T/bin/dumpsys" "$T/bin/getprop"
A="$ROOT/action.sh"
_as="$(grep -n '^_a_rs="$(_cfg audio_resampler)"$' "$A" | cut -d: -f1)"
[ -n "$_as" ] || fail "action screen does not report the resampler"
_ae="$(awk -v s="$_as" 'NR>s && /^_a_vs=/ {f=1} f && /^esac$/ {print NR; exit}' "$A")"
sed -n "${_as},${_ae}p" "$A" > "$T/action_block.sh"
{
  grep -E '^T_A_(RS|VS)_[A-Z]+=' "$A"
  echo '_f() { _sfmt="$1"; shift; printf "$_sfmt\n" "$@"; }'
  echo '_cfg() { sed -n "s/^$1=//p" "$T_CONF" | head -1; }'
  cat "$T/action_block.sh"
} > "$T/action_run.sh"
act() {
  printf '%s\n' "$1" > "$T/act.conf"
  PATH="$T/bin:$PATH" T_CONF="$T/act.conf" FAKE_DUMP="$T/dumpsys_audio" FAKE_MAX="$2" \
    FAKE_SB="$3" FAKE_VS="$4" sh "$T/action_run.sh"
}
o="$(act "audio_resampler=high
media_vol_steps=30" 30 140 30)"
printf '%s\n' "$o" | grep -q 'resampler: high (active)' || fail "action: live resampler not confirmed: $o"
printf '%s\n' "$o" | grep -q 'media volume: 30 steps (Android confirms)' || fail "action: live steps not confirmed: $o"
o="$(act "audio_resampler=max
media_vol_steps=50" 15 140 "")"
printf '%s\n' "$o" | grep -q 'resampler: max - takes effect after the next reboot' || fail "action: pending resampler: $o"
printf '%s\n' "$o" | grep -q 'media volume: 50 steps - takes effect after the next reboot' || fail "action: pending steps: $o"
o="$(act "audio_resampler=stock
media_vol_steps=50" 16 "" 50)"
printf '%s\n' "$o" | grep -q 'media volume: 16 steps - this ROM ignores the 50 asked for' || fail "action: ignored steps: $o"
printf '%s\n' "$o" | grep -q resampler && fail "action: stock resampler reported: $o"
o="$(act "audio_resampler=stock
media_vol_steps=stock" 15 "" "")"
[ -z "$o" ] || fail "action: stock printed lines: $o"
for l in ar de es fr hy id it pt ru tr uk zh; do
  for k in T_A_RS_OK T_A_RS_WAIT T_A_VS_OK T_A_VS_IGN T_A_VS_WAIT; do
    grep -q "^$k=" "$ROOT/runtime/i18n/action_$l.sh" || fail "action_$l.sh lacks $k"
  done
  [ "$(sed -n 's/^T_A_VS_IGN=//p' "$ROOT/runtime/i18n/action_$l.sh" | grep -o '%s' | wc -l)" -eq 2 ] || fail "action_$l.sh T_A_VS_IGN must keep two values"
done
D="$ROOT/tools/asb_diag.sh"
cmp -s "$D" "$ROOT/system/bin/asbdiag" || fail "system/bin/asbdiag differs from tools/asb_diag.sh"
_ds="$(grep -n '^_rs_c="$(cfg audio_resampler)"$' "$D" | cut -d: -f1)"
[ -n "$_ds" ] || fail "asbdiag does not check the resampler"
_de="$(awk -v s="$_ds" 'NR>s && /^_mv_c=/ {f=1} f && /^esac$/ {print NR; exit}' "$D")"
{
  echo 'V() { echo "V|$1|$2|$3"; }'
  echo 'NOTE() { echo "NOTE|$1"; }'
  echo 'OFF() { echo "OFF|$1|$2"; }'
  echo 'gp() { getprop "$1"; }'
  echo 'cfg() { sed -n "s/^$1=//p" "$T_CONF" | head -1; }'
  sed -n "${_ds},${_de}p" "$D"
} > "$T/diag_run.sh"
diag() {
  printf '%s\n' "$1" > "$T/diag.conf"
  PATH="$T/bin:$PATH" T_CONF="$T/diag.conf" FAKE_DUMP="$T/dumpsys_audio" FAKE_MAX="$2" \
    FAKE_SB="$3" FAKE_HL="$4" FAKE_EN=44100 FAKE_VS="$5" sh "$T/diag_run.sh"
}
o="$(diag "audio_resampler=max
media_vol_steps=50" 50 179 320 50)"
printf '%s\n' "$o" | grep -q '^V|resampler max .*|179/320|179/320$' || fail "asbdiag: live max not verified: $o"
printf '%s\n' "$o" | grep -q '^V|media volume steps (STREAM_MUSIC Max)|50|50$' || fail "asbdiag: live steps not verified: $o"
o="$(diag "audio_resampler=high
media_vol_steps=30" 15 "" "" "")"
printf '%s\n' "$o" | grep -q '^NOTE|audio_resampler=high is not live yet (stopband/halflength <ROM default>)' || fail "asbdiag: pending resampler: $o"
printf '%s\n' "$o" | grep -q '^NOTE|media_vol_steps=30 is not live yet (Android uses 15 steps)' || fail "asbdiag: pending steps: $o"
printf '%s\n' "$o" | grep -q '^V|' && fail "asbdiag: a pending setting counted as a check: $o"
o="$(diag "audio_resampler=stock
media_vol_steps=30" 16 90 32 30)"
printf '%s\n' "$o" | grep -q '^NOTE|ro.config.media_vol_steps=30 is set, yet the audio service uses 16 steps' || fail "asbdiag: ignored steps: $o"
printf '%s\n' "$o" | grep -q '^OFF|resampler quality - audio_resampler=stock, stopband/halflength 90/32|audio_resampler$' || fail "asbdiag: stock resampler: $o"
o="$(diag "audio_resampler=stock
media_vol_steps=stock" 15 "" "" "")"
printf '%s\n' "$o" | grep -q '^OFF|media volume steps - media_vol_steps=stock, Android uses 15 steps|media_vol_steps$' || fail "asbdiag: stock steps: $o"
echo "PASS audio prop tweaks: stock writes nothing, high/max/30/50 write exactly their props before Android starts, action and asbdiag tell live, pending and ignored apart"
)

t_bt_lifecycle_recorder_contract() (
# Contract: full-day Bluetooth lifecycle telemetry is read-only, bounded, privacy-aware and
# distinguishes literal reconnect evidence from phase/route snapshots.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMMON="$ROOT/tools/logkit/_asb_logkit_common.sh"
FULL="$ROOT/tools/logkit/asb_log_full_day.sh"
DOC="$ROOT/docs/log_schemas.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL BT lifecycle recorder: $*" >&2; exit 1; }
[ -f "$COMMON" ] || fail "common logkit missing"
[ -f "$FULL" ] || fail "full-day recorder missing"
sh -n "$COMMON" || fail "common shell syntax"
sh -n "$FULL" || fail "full-day shell syntax"

# Source pure helper definitions. No capture is started by sourcing common.
# shellcheck disable=SC1090
. "$COMMON"
LK_OUT_DIR="$TMP"
LK_BT_RECONNECT_EVENTS="$TMP/bt_lifecycle_events.tsv"
LK_BT_RECONNECT_CONTEXT="$TMP/bt_lifecycle_context.tsv"
LK_BT_RECONNECT_SNAPSHOTS="$TMP/bt_lifecycle_snapshots.txt"
LK_BT_RECONNECT_EVENT_COUNT=0
LK_BT_RECONNECT_MAX_EVENTS=3
printf '%s\n' '# epoch<TAB>iso_utc<TAB>event<TAB>source' > "$LK_BT_RECONNECT_EVENTS"

[ "$(lk_bt_lifecycle_kind '1.0 AdapterService: reconnect requested')" = "reconnect_literal" ] || fail "literal reconnect classification"
[ "$(lk_bt_lifecycle_kind '1.0 HeadsetService: disconnectAudio: device AA:BB:CC:DD:EE:FF')" = "hfp_audio_disconnect" ] || fail "HFP audio detach classification"
[ "$(lk_bt_lifecycle_kind '1.0 HeadsetService: connectAudio: device AA:BB:CC:DD:EE:FF')" = "hfp_audio_connect" ] || fail "HFP audio attach classification"
# A Java stack frame or a state query is not an event (fix44 capture: 240 rows from one trace).
[ -z "$(lk_bt_lifecycle_kind "$(printf '1.0 10675 12397 D BluetoothA2dp: \tat android.bluetooth.BluetoothA2dp.getConnectionState(BluetoothA2dp.java:449)')")" ] || fail "stack frame counted as an event"
[ -z "$(lk_bt_lifecycle_kind '1.0 SystemUI: CachedBluetoothDevice.isConnected() true')" ] || fail "connection-state query counted as an event"
[ "$(lk_bt_lifecycle_kind '1.0 A2dpService: connectionStateChanged, state: 2->3')" = "a2dp_profile_disconnect" ] || fail "A2DP profile disconnect classification"
[ "$(lk_bt_lifecycle_kind '1.0 A2dpService: connectionStateChanged, state: 1->2')" = "a2dp_profile_connect" ] || fail "A2DP profile connect classification"
[ "$(lk_bt_lifecycle_kind '1.0 A2dpService: device disconnected')" = "disconnect_generic" ] || fail "generic disconnect classification"
[ "$(lk_bt_lifecycle_kind '1.0 AdapterService: connected state=2')" = "connect_generic" ] || fail "generic connect classification"
[ -z "$(lk_bt_lifecycle_kind 'feature disconnect_hid_channels_serially=true')" ] || fail "V63 static feature false positive"
[ -z "$(lk_bt_lifecycle_kind 'Devices: bt_a2dp(80)')" ] || fail "route snapshot must not become event"
# fix178: the link drop itself, with its HCI reason, and the one-step 2->0 of a lost link.
_acl='1.0 BluetoothRemoteDevices: aclStateChangeCallback: Adapter State: ON Disconnected: AA:BB:CC:DD:EE:FF transportLinkType: 1 hciReason: 8'
[ "$(lk_bt_lifecycle_kind "$_acl")" = acl_disconnect ] || fail "ACL disconnect classification"
[ "$(lk_bt_lifecycle_source "$_acl")" = "ACL reason=8" ] || fail "ACL reason: $(lk_bt_lifecycle_source "$_acl")"
[ "$(lk_bt_lifecycle_source '1.0 BluetoothRemoteDevices: aclStateChangeCallback: Adapter State: ON Disconnected: AA:BB:CC:DD:EE:FF reason=0x13')" = "ACL reason=0x13" ] || fail "hex ACL reason"
[ "$(lk_bt_lifecycle_kind '1.0 BluetoothRemoteDevices: aclStateChangeCallback: Adapter State: ON Connected: AA:BB:CC:DD:EE:FF')" = acl_connect ] || fail "ACL connect classification"
[ "$(lk_bt_lifecycle_kind '1.0 A2dpStateMachine: Connection state AA:BB:CC:DD:EE:FF: CONNECTED->DISCONNECTED')" = a2dp_profile_disconnect ] || fail "A2DP state machine disconnect"
[ "$(lk_bt_lifecycle_kind '1.0 A2dpStateMachine: Connection state AA:BB:CC:DD:EE:FF: CONNECTING->CONNECTED')" = a2dp_profile_connect ] || fail "A2DP state machine connect"
[ "$(lk_bt_lifecycle_kind '1.0 A2dpService: connectionStateChanged, device: AA:BB:CC:DD:EE:FF, state: 2->0')" = a2dp_profile_disconnect ] || fail "A2DP 2->0 lost link"
[ "$(lk_bt_lifecycle_kind '1.0 HeadsetStateMachine: Connection state AA:BB:CC:DD:EE:FF: CONNECTED->DISCONNECTED')" = hfp_profile_disconnect ] || fail "headset profile disconnect"
printf '%s\n' "$(lk_bt_lifecycle_source "$_acl")" | grep -q 'AA:BB' && fail "an address in the ACL source"
grep -q 'BluetoothRemoteDevices:V A2dpStateMachine:V' "$COMMON" || fail "the recorder does not listen to the link and state-machine tags"
# The report's reason table, on events from a multipoint morning.
printf '1\tx\tacl_disconnect\tACL reason=8\n2\tx\tacl_disconnect\tACL reason=0x13\n3\tx\tacl_disconnect\tACL reason=19\n4\tx\tacl_disconnect\tACL reason=?\n5\tx\ta2dp_profile_connect\tA2DP\n' > "$TMP/ev.tsv"
python3 - "$FULL" "$TMP/acl.awk" <<'P'
import sys
s = open(sys.argv[1], encoding='utf-8').read()
a = s.index("'!/^#/ && $3 == \"acl_disconnect\"") + 1
b = s.index("' \"$_bt_ev\"", a)
open(sys.argv[2], 'w').write(s[a:b])
P
_r="$(awk -F'\t' -f "$TMP/acl.awk" "$TMP/ev.tsv")"
printf '%s\n' "$_r" | grep -q '^link drops (ACL disconnects): 4 - lost link (timeout): 1, ended by the headset: 2, ended by this phone: 0, other/unknown: 1$' || fail "ACL reason table: $_r"
printf '%s\n' "$_r" | grep -q 'multipoint headset switching' || fail "no reading of a headset-ended drop: $_r"
# fix178: the audio mode owner as Android 16 prints it (on the line after the heading).
_ad='Audio mode:
- Requested mode = MODE_IN_COMMUNICATION
- Actual mode = MODE_IN_COMMUNICATION
- Mode owner: 
   pid: 4437 uid: 10419 mode: MODE_IN_COMMUNICATION package: org.telegram.messenger'
_mo="$(printf '%s\n' "$_ad" | awk '
      /[Mm]ode owner/ { sub(/.*[Mm]ode owner:?[ \t]*/, ""); if ($0 != "") { print; exit } own = 1; next }
      own && NF { sub(/^[ \t]+/, ""); print; exit }')"
[ "$_mo" = 'pid: 4437 uid: 10419 mode: MODE_IN_COMMUNICATION package: org.telegram.messenger' ] || fail "mode owner: '$_mo'"
grep -q "Actual mode =" "$COMMON" || fail "the audio mode is not read from Android 16's line"

# No raw line, BT address, or device name is written. The file is a four-column evidence TSV.
lk_bt_lifecycle_record '1787300000.100 HeadsetService: disconnectAudio: device AA:BB:CC:DD:EE:FF PixelBuds'
lk_bt_lifecycle_record '1787300001.100 A2dpService: connectionStateChanged, device AA:BB:CC:DD:EE:FF, state: 2->3 PixelBuds'
lk_bt_lifecycle_record '1787300002.100 HeadsetService: reconnect requested AA:BB:CC:DD:EE:FF PixelBuds'
[ "$(awk '!/^#/ {n++} END{print n+0}' "$LK_BT_RECONNECT_EVENTS")" = 3 ] || fail "event persistence count"
awk -F'\t' '!/^#/ { if (NF != 4 || $3 !~ /^(hfp_audio_disconnect|a2dp_profile_disconnect|reconnect_literal)$/) exit 1 }' "$LK_BT_RECONNECT_EVENTS" || fail "event TSV shape"
! grep -Eq 'AA:BB:CC:DD:EE:FF|PixelBuds|device ' "$LK_BT_RECONNECT_EVENTS" || fail "raw identifier leaked"

# Reaching the cap stops rather than continually consuming the all-day log stream.
if lk_bt_lifecycle_record '1787300003.100 AdapterService: connected'; then
  fail "event cap should return stop status"
else
  [ "$?" = 2 ] || fail "event cap returned wrong status"
fi
[ "$(awk '!/^#/ {n++} END{print n+0}' "$LK_BT_RECONNECT_EVENTS")" = 3 ] || fail "cap wrote extra event"

# Context is intentionally separate and can be written without device services on host.
LK_BT_RECONNECT_ENABLED=1
LK_AUDIO_PLAY=1
LK_AUDIO_ROUTE=bt
lk_get_prop() { printf '%s' ''; }
dumpsys() { :; }
settings() { :; }
lk_bt_reconnect_snapshot 'phase:audio_bt'
awk -F '\t' '$3=="phase:audio_bt" && $4=="1" && $5=="bt" {ok=1} END{exit !ok}' "$LK_BT_RECONNECT_CONTEXT" || fail "route context missing"

# Full-day capture turns trace on by default; still allowing an explicit opt-out is essential.
grep -Fq ': "${ASB_BT_RECONNECT_TRACE:=1}"' "$FULL" || fail "default lifecycle trace missing"
grep -Fq 'ASB_BT_RECONNECT_TRACE=0' "$FULL" || fail "explicit opt-out documentation missing"
grep -Fq 'bt_lifecycle_events.tsv' "$FULL" || fail "report lacks lifecycle events reference"
grep -Fq 'bt_lifecycle_context.tsv' "$FULL" || fail "report lacks lifecycle context reference"
grep -Fq 'HFP/SCO audio-link detach, not proof that the' "$COMMON" || fail "HFP versus device disconnect boundary missing"
grep -Fq 'a2dp_profile_disconnect' "$FULL" || fail "A2DP summary boundary missing"
grep -Fq 'disconnect_hid_channels_serially' "$COMMON" || fail "V63 false positive exclusion missing"
grep -Fq 'Bluetooth lifecycle recorder' "$DOC" || fail "schema documentation missing"
grep -Fq 'bt_lifecycle_events.tsv' "$DOC" || fail "event schema missing"
grep -Fq 'bt_lifecycle_context.tsv' "$DOC" || fail "context schema missing"

# fix131: one connection logs 0->1, 1->2 and okToConnect - one row, not three. A later
# connection (or a different kind) in between is its own row.
LK_BT_RECONNECT_EVENT_COUNT=0; LK_BT_RECONNECT_MAX_EVENTS=50; LK_BT_LAST_KIND=""; LK_BT_LAST_EPOCH=0
printf '%s\n' '# epoch<TAB>iso_utc<TAB>event<TAB>source' > "$LK_BT_RECONNECT_EVENTS"
lk_bt_lifecycle_record '1787400000.100 A2dpService: connectionStateChanged, state: 0->1'
lk_bt_lifecycle_record '1787400000.200 A2dpService: connectionStateChanged, state: 1->2'
lk_bt_lifecycle_record '1787400001.100 A2dpService: okToConnect: device x'
lk_bt_lifecycle_record '1787400002.100 HeadsetService: connectAudio: device x'
lk_bt_lifecycle_record '1787400090.100 A2dpService: connectionStateChanged, state: 1->2'
[ "$(awk '!/^#/ && $3=="a2dp_profile_connect" {n++} END{print n+0}' "$LK_BT_RECONNECT_EVENTS")" = 2 ] \
  || fail "one A2DP connection counted more than once ($(grep -c a2dp_profile_connect "$LK_BT_RECONNECT_EVENTS"))"
[ "$(awk '!/^#/ && $3=="hfp_audio_connect" {n++} END{print n+0}' "$LK_BT_RECONNECT_EVENTS")" = 1 ] || fail "a different kind was swallowed"

# fix178: device names in the AVRCP volume table are redacted with the addresses (capture
# 30423 carried a headphone model and a car name); the volume and state stay.
_nm="$(printf '      AA:BB:CC:DD:EE:FF : BMW 68311      :   0 : NotConnected\n      AA:BB:CC:DD:EE:01 : OnePlus Bud... : 160 : Connected\n' | lk_bt_redact_addr)"
printf '%s\n' "$_nm" | grep -q 'BMW\|OnePlus' && fail "a device name survived redaction: $_nm"
printf '%s\n' "$_nm" | grep -q '^      <BT_ADDR> : <name> :   0 : NotConnected$' || fail "AVRCP row lost its volume/state: $_nm"
printf '%s\n' "$_nm" | grep -q '<name> : 160 : Connected$' || fail "second AVRCP row: $_nm"
[ "$(printf 'mCodecConfig: {codecName:LHDC}\n' | lk_bt_redact_addr)" = 'mCodecConfig: {codecName:LHDC}' ] || fail "redaction touched a non-AVRCP line"

# fix178: profile drops from the service's own state history, deduplicated across snapshots.
# Device A: a whole-device drop (call profile with it) back in 2 s, then a media-only drop
# (call profile rows on both sides, same state) back after 18 min; device B: asked for on the
# phone. The A2DP history appears in two snapshots and is counted once.
_sn="$TMP/snap_hist.txt"
_hist_a='  === A2dpStateMachine for XX:XX:XX:XX:B8:86 (Active) ===
    StateMachine: name=A2dpStateMachine state=Connected
       rec[0]: time=10-18 20:11:48.302 processed=Connected org=Connected dest=Disconnecting what=101(0x65) STACK_EVENT: x
       rec[1]: time=10-18 20:11:48.310 processed=Disconnecting org=Disconnecting dest=Disconnected what=101(0x65) STACK_EVENT: x
       rec[2]: time=10-18 20:11:49.788 processed=Disconnected org=Disconnected dest=Connecting what=101(0x65) STACK_EVENT: x
       rec[3]: time=10-18 20:11:50.100 processed=Connecting org=Connecting dest=Connected what=101(0x65) STACK_EVENT: x
       rec[4]: time=10-19 12:59:43.736 processed=Connected org=Connected dest=Disconnecting what=101(0x65) STACK_EVENT: x
       rec[5]: time=10-19 13:17:52.865 processed=Disconnected org=Disconnected dest=Connecting what=101(0x65) STACK_EVENT: x
       rec[6]: time=10-19 13:17:53.072 processed=Connecting org=Connecting dest=Connected what=101(0x65) STACK_EVENT: x
  === A2dpStateMachine for XX:XX:XX:XX:9D:9F ===
    StateMachine: name=A2dpStateMachine state=Disconnected
       rec[0]: time=10-19 08:24:08.000 processed=Connected org=Connected dest=Disconnecting what=2(0x2) DISCONNECT: x'
_hist_h='Profile: HeadsetService
    StateMachine: name=HeadsetStateMachine state=Connected
       rec[0]: time=10-18 20:11:48.265 processed=Connected org=Connected dest=Disconnecting what=101(0x65) STACK_EVENT: x
       rec[1]: time=10-19 12:58:00.000 processed=Connected org=Connected dest=<null> what=10(0xa) DEVICE_STATE_CHANGED: x
       rec[2]: time=10-19 13:01:00.000 processed=Connected org=Connected dest=<null> what=10(0xa) DEVICE_STATE_CHANGED: x'
{ echo '===== BLUETOOTH [hourly] 2026-10-19T10:00:00Z ====='; printf '%s\n' "$_hist_a" "$_hist_h"
  echo '===== BLUETOOTH [hourly] 2026-10-19T11:00:00Z ====='; printf '%s\n' "$_hist_a" "$_hist_h"
  echo '===== BLUETOOTH [other] 2026-10-19T11:30:00Z ====='
  echo '    StateMachine: name=BondStateMachine state=Stable'
  echo '       rec[0]: time=10-19 13:00:00.000 processed=Connected org=Connected dest=Disconnected what=101(0x65) x'; } > "$_sn"
_hd="$(lk_bt_history_drops "$_sn")"
printf '%s\n' "$_hd" | grep -q '^media drops: 3 (stack-reported 2, asked for on the phone 1); whole device (call profile too): 1; media only (call profile kept): 1$' \
  || fail "history drop summary: $_hd"
printf '%s\n' "$_hd" | grep -q '^  10-18 20:11:48  device A  reported by the Bluetooth stack.*call profile dropped with it; back after 2s$' || fail "whole-device drop row: $_hd"
printf '%s\n' "$_hd" | grep -q '^  10-19 12:59:43  device A .*call profile stayed connected; back after 18m09s$' || fail "media-only drop row: $_hd"
printf '%s\n' "$_hd" | grep -q '^  10-19 08:24:08  device B  asked for on this phone; call profile not in the kept history; not back within the kept history$' || fail "phone-requested drop row: $_hd"
printf '%s\n' "$_hd" | grep -q 'B8:86\|9D:9F' && fail "an address fragment reached the report"
# A state change with no row for it (AudioOn before, Connected after) is a hole, not "stayed".
sed 's/12:58:00.000 processed=Connected org=Connected dest=<null>/12:58:00.000 processed=AudioOn org=AudioOn dest=<null>/' "$_sn" > "$_sn.2"
lk_bt_history_drops "$_sn.2" | grep -q '12:59:43 .*call profile not in the kept history' || fail "a history hole read as a kept call profile"
[ -z "$(lk_bt_history_drops "$TMP/none.txt")" ] || fail "missing snapshots printed something"
grep -Fq 'lk_bt_history_drops "$LK_OUT_DIR/bt_lifecycle_snapshots.txt"' "$FULL" || fail "full-day report does not read the service history"
# fix178: the network trace's Wi-Fi link - band, signal and speed, never the SSID/BSSID.
_wl="$(printf '%s\n' 'WifiInfo: SSID: "home", BSSID: 11:22:33:44:55:66, Wi-Fi standard: 11be, RSSI: -58, Link speed: 2882Mbps, Tx Link speed: 2882Mbps, Rx Link speed: 1441Mbps, Frequency: 6115MHz' | lk_wifi_link)"
[ "$_wl" = '6115 MHz (6 GHz), RSSI -58 dBm, 2882 Mbps, 11be' ] || fail "wifi link summary: $_wl"
[ -z "$(printf 'BSSID  Frequency  RSSI\n  aa  2412  -40\n' | lk_wifi_link)" ] || fail "a scan table read as the link"
grep -q 'SSID: \[\^,\]\*, BSSID' "$COMMON" && fail "the network trace still asks for the SSID and BSSID"

echo 'PASS Bluetooth lifecycle recorder contract'
)

t_bt_safe_policy_contract() (
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APPLY="$ROOT/runtime/asb_apply_managed_props.sh"
REC="$ROOT/tools/logkit/_asb_logkit_common.sh"
AUDIO="$ROOT/runtime/asb_audio_apply.sh"
fail() { echo "FAIL BT safe policy contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
need "$APPLY" 'enable_bt_policy'
need "$APPLY" 'disabled_default'
need "$APPLY" 'bt_policy=$_bt_policy_state'
need "$APPLY" 'resetprop --delete "$_key"'
need "$AUDIO" 'runtime/asb_baseline.sh'
need "$AUDIO" '_asb_setting_put global bluetooth_a2dp_offload_enabled'
need "$AUDIO" '_asb_setting_put global bluetooth_disable_absolute_volume'
need "$AUDIO" '_asb_setting_put secure bluetooth_disable_absolute_volume'
need "$REC" 'LK_BT_RECONNECT_RAW'
need "$REC" 'bt_lifecycle_stack_evidence.tsv'
need "$REC" 'lk_bt_redact_addr'
need "$REC" 'reason/status/transport'
echo 'PASS BT safe policy contract'
)

t_camera_pcm_native_runtime() (
# Runtime (fix141): builds and runs tests/test_camera_pcm_native.c against the production
# asb_metrics.h - the camera guard drops with the screen off, and the PCM playback probe the
# screen-off drain tracker uses tells playback from capture and from "cannot read".
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CCX="${HOST_CC:-${CC:-}}"
[ -n "$CCX" ] || for c in cc gcc clang; do command -v "$c" >/dev/null 2>&1 && { CCX="$c"; break; }; done
[ -n "$CCX" ] || { echo "FAIL camera/pcm native: no host C compiler" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_c_camera_pcm_native > "$T/fx.c"
"$CCX" -D_GNU_SOURCE -std=c11 -O1 -Wno-unused-function -I "$ROOT/src" "$T/fx.c" -lm -o "$T/fx" \
  || { echo "FAIL camera/pcm native: build failed" >&2; exit 1; }
"$T/fx"
)

t_charge_hold_runtime() (
# Runtime (fix148): a charger online at "Not charging" is the charger, not the battery.
#
# CPH2769 capture 13290: OnePlus battery protection parked the level at 80% with the cable
# in for 161 + 48 minutes. The battery status read "Not charging", so the recorder filed both
# stretches as "sleep" - 99% awake, 0 %/h - the kernel's "wired wakelock" held throughout,
# and the report printed "night verdict: valid (226 min)" with no night row to back it. The
# governor read the same status as "on battery". The REAL functions run here on a fake
# power_supply tree, a fake ledger and fake holder blocks.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"; F="$ROOT/tools/logkit/asb_log_full_day.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL charge hold: $*" >&2; fail=1; }

# --- 1. power state -----------------------------------------------------------------------
P="$T/psy"; mkdir -p "$P/battery" "$P/usb" "$P/wireless"
st() {   # status usb wireless
  printf '%s\n' "$1" > "$P/battery/status"; echo "$2" > "$P/usb/online"; echo "$3" > "$P/wireless/online"
  ASB_LK_PSY="$P" sh -c '. "$0" >/dev/null 2>&1; lk_power_state' "$C"
}
[ "$(st Charging 1 0)" = charging ] || f "Charging"
[ "$(st Full 1 0)" = full ] || f "Full"
[ "$(st Discharging 1 0)" = battery ] || f "Discharging wins over an online flag"
[ "$(st 'Not charging' 1 0)" = held ] || f "Not charging with the cable in: '$(st 'Not charging' 1 0)' (want held)"
[ "$(st 'Not charging' 0 1)" = held ] || f "Not charging on a wireless pad"
[ "$(st 'Not charging' 0 0)" = battery ] || f "Not charging with no supply online"
[ "$(st Unknown 1 0)" = charging ] || f "Unknown status with a supply online (OxygenOS 16)"
[ "$(st Unknown 0 0)" = battery ] || f "Unknown status, nothing online"
[ "$(ASB_LK_PSY="$P" sh -c '. "$0" >/dev/null 2>&1; lk_power_state Charging' "$C")" = charging ] || f "status passed in"

# --- 2. the recorder files it as a charging phase, the battery trace as charging -----------
grep -q 'case "$(lk_power_state "$_cs")" in' "$F" && grep -q '    charging|full|held)' "$F" || f "phase classifier ignores the hold"
sed -n '/^lk_capture_battery_trace_row\|^lk_battery_trace_row/,/^}/p' "$C" | grep -q 'case "$(lk_power_state)" in' \
  || grep -q '  case "$(lk_power_state)" in' "$C" || f "battery trace reads the hold as discharging"

# --- 3. night verdict from the battery phases -----------------------------------------------
{ awk '/^lk_night_chain\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$F"
  awk '/^lk_emit_capture_validity\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$F"; } > "$T/v.sh"
grep -q '^lk_emit_capture_validity() {' "$T/v.sh" && grep -q '^lk_night_chain() {' "$T/v.sh" || f "lk_emit_capture_validity or lk_night_chain not found"
mkdir -p "$T/o"
printf 'charging_idle\t1000\t13000\t28\t80\nsleep\t13000\t22660\t80\t80\nidle\t22660\t23200\t80\t79\n' > "$T/o/phase_ledger.tsv"
out="$(LK_OUT_DIR="$T/o" LK_START_EPOCH=$(( $(date +%s) - 30000 )) LK_SCREENOFF_LONGEST_S=13560 sh -c '. "$1"; lk_emit_capture_validity' x "$T/v.sh")"
printf '%s\n' "$out" | grep -q '^night verdict: unavailable on battery (screen off up to 226 min, but the longest stretch off the charger was 170 min; need >=180 min).$' \
  || f "night on the charger read as valid: $out"
printf 'active\t23200\t30000\t79\t70\nsleep\t30000\t42000\t90\t86\n' >> "$T/o/phase_ledger.tsv"
out="$(LK_OUT_DIR="$T/o" LK_START_EPOCH=$(( $(date +%s) - 30000 )) LK_SCREENOFF_LONGEST_S=13560 sh -c '. "$1"; lk_emit_capture_validity' x "$T/v.sh")"
printf '%s\n' "$out" | grep -q '^night verdict: valid (longest screen-off stretch on battery 200 min >=180 min).$' || f "a real night not valid: $out"
mkdir -p "$T/n"
printf 'active\t0\t600\t95\t94\nidle\t600\t1800\t94\t94\nidle\t1802\t3200\t94\t93\nsleep\t3202\t11600\t93\t91\n' > "$T/n/phase_ledger.tsv"
out="$(LK_OUT_DIR="$T/n" LK_START_EPOCH=$(( $(date +%s) - 30000 )) LK_SCREENOFF_LONGEST_S=8520 sh -c '. "$1"; lk_emit_capture_validity' x "$T/v.sh")"
printf '%s\n' "$out" | grep -q '^night verdict: valid (longest screen-off stretch on battery 183 min >=180 min).$' || f "fix167: a night split into idle and sleep phases is not one night: $out"
printf 'active\t0\t600\t95\t94\nidle\t600\t6000\t94\t93\nactive\t6000\t6600\t93\t92\nsleep\t6600\t12000\t92\t91\n' > "$T/n/phase_ledger.tsv"
out="$(LK_OUT_DIR="$T/n" LK_START_EPOCH=$(( $(date +%s) - 30000 )) LK_SCREENOFF_LONGEST_S=5400 sh -c '. "$1"; lk_emit_capture_validity' x "$T/v.sh")"
printf '%s\n' "$out" | grep -q '^night verdict: unavailable (longest continuous screen-off 90 min; need >=180 min).$' || f "fix167: ten minutes on screen did not split the night: $out"

# --- 4. charging-idle verdict names the kernel holder ---------------------------------------
awk '/^lk_emit_charging_idle_anomaly\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$F" > "$T/a.sh"
mkdir -p "$T/q"
printf 'charging_idle\t1000\t13000\t28\t80\t33\t31\t418\t0\t0\t0\t100\t0\t0\t0\t0\n' > "$T/q/phase_ledger.tsv"
cat > "$T/q/phase_wakeholders.txt" <<'X'
phase=idle awake=60% dur=900s  (time gained inside this phase)
  kernel: +5m 00s  hal_bluetooth_lock
phase=charging_idle awake=100% dur=9000s  (time gained inside this phase; kernel only - batterystats counts no app wakelock on the charger)
  kernel: +149m 30s  wired wakelock
  kernel: +12m 05s  rmnet_ipa%d
phase=charging_idle awake=100% dur=3000s  (time gained inside this phase; kernel only - batterystats counts no app wakelock on the charger)
  kernel: +50m 00s  wired wakelock
X
out="$(LK_OUT_DIR="$T/q" LK_CHG_IDLE_SAMPLES=10 LK_CHG_IDLE_AUDIO_SAMPLES=0 LK_CHG_IDLE_COALESCED=0 sh -c '. "$1"; lk_emit_charging_idle_anomaly' x "$T/a.sh")"
printf '%s\n' "$out" | grep -q '^  kernel holder on the charger: wired wakelock 199 min$' || f "charger wakelock not summed over the charging phases: $out"
printf '%s\n' "$out" | grep -q 'hal_bluetooth_lock' && f "an idle-phase holder counted as a charging one: $out"
printf '%s\n' "$out" | grep -q 'the phone.s own design, nothing an app or ASB holds' || f "charger wakelock not explained: $out"
grep -q 'gap|idle|sleep|charging_idle) lk_wh_kernel_snap' "$F" || f "no kernel snapshot at a charging-idle phase open"

# --- 5. report line, governor, action screen -------------------------------------------------
grep -q 'held, not charging       : %d samples at %s%%' "$F" || f "charging block does not count the hold"
grep -q "else if (st\[0\] == 'D')                 b->charging = 0;" "$ROOT/src/asb_metrics.h" || f "governor still reads Not charging as on battery"
grep -q 'Held)     _bst_l="  ·  $T_HELD" ;;' "$ROOT/action.sh" || f "action screen does not say the charge is paused"
for l in "$ROOT"/runtime/i18n/action_*.sh; do grep -q '^T_HELD=' "$l" || f "T_HELD missing in ${l##*/}"; done

[ "$fail" = 0 ] && echo "PASS charge hold: a paused charge is the charger in the recorder, the night verdict, the governor and the action screen"
exit "$fail"
)

t_doze_keep_list_runtime() (
# Runtime (fix152): the apps picked in the WebUI are kept out of Doze, for real and at once.
#
# Testers liked the trim ("the best tweak against night drain") and asked to choose the
# apps it must leave alone from the WebUI. The old list showed only apps Android still
# exempted, so an app ASB had already trimmed was not there to tick, and a ticked app that
# Android dozes changed nothing. The REAL applier runs on a fake pm / deviceidle whose
# exemption list persists between calls:
#   - a kept app ASB trimmed earlier is given back and no longer recorded as removed;
#   - a kept app Android dozes is made exempt and recorded as ASB's grant;
#   - unticking it withdraws only ASB's grant; trim off or stock withdraws all grants and
#     returns every trimmed app; protected and system apps are never touched;
#   - `list` reports apps, exemptions, records and the rules' protection for the picker;
#   - a hostile line in the keep file never reaches deviceidle.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_doze_apply.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL doze keep list: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
cat > "$T/bin/pm" <<'S'
#!/bin/sh
printf 'package:%s\n' org.telegram.messenger com.example.vpn com.example.game com.azure.authenticator com.example.trimmed
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = deviceidle ] || exit 0
[ "$2" = whitelist ] || exit 0
case "${3:-}" in
  +*) echo "$3" >> "$WL_LOG"; p="${3#+}"; grep -qx "$p" "$WL" || echo "$p" >> "$WL"; exit 0 ;;
  -*) echo "$3" >> "$WL_LOG"; p="${3#-}"; grep -vx "$p" "$WL" > "$WL.n"; mv "$WL.n" "$WL"; exit 0 ;;
esac
echo 'system-excidle,com.android.phone,1001'
while IFS= read -r p; do echo "user,$p,10$(printf '%s' "$p" | wc -c)"; done < "$WL"
S
cat > "$T/bin/settings" <<'S'
#!/bin/sh
exit 0
S
chmod +x "$T/bin/"*
printf '%s\n' com.example.vpn com.example.game com.azure.authenticator > "$T/wl"
printf '%s\n' com.example.trimmed > "$T/st/doze_whitelist_removed"
printf '%s\n' org.telegram.messenger com.example.trimmed com.example.vpn 'x;touch /tmp/pwn' > "$T/st/doze_whitelist_keep"
printf '%s' 'com.example.vpn' >> "$T/st/doze_whitelist_keep"
conf() { printf 'doze_level=%s\ndoze_trim_whitelist=%s\n' "$1" "$2" > "$T/mod/config/governor.conf"; }
apply() {
  : > "$T/wl.log"
  PATH="$T/bin:$PATH" WL="$T/wl" WL_LOG="$T/wl.log" MODDIR="$T/mod" ASB_DOZE_STATE_DIR="$T/st" \
    sh "$SRC" "$@" </dev/null 2>/dev/null
}
conf aggressive 1
apply > "$T/out"
grep -qx '+org.telegram.messenger' "$T/wl.log" || f "a kept app Android dozes was not made exempt"
grep -qx 'org.telegram.messenger' "$T/st/doze_whitelist_added" || f "ASB's grant was not recorded"
grep -qx '+com.example.trimmed' "$T/wl.log" || f "a kept app ASB had trimmed was not given back"
grep -qx 'com.example.trimmed' "$T/st/doze_whitelist_removed" && f "a returned app is still recorded as removed"
grep -qx 'com.example.trimmed' "$T/st/doze_whitelist_added" && f "an app given back was recorded as ASB's grant"
grep -qx -- '-com.example.game' "$T/wl.log" || f "an ordinary exempt app was not trimmed"
grep -q 'com.example.vpn' "$T/wl.log" && f "a kept app that was already exempt was touched"
grep -q 'authenticator' "$T/wl.log" && f "a protected app was touched"
grep -q 'com.android.phone' "$T/wl.log" && f "a system entry was touched"
grep -q 'pwn\|touch' "$T/wl.log" && f "a hostile keep-file line reached deviceidle"
[ -e /tmp/pwn ] && f "a hostile keep-file line ran"
grep -q 'org.telegram.messenger is kept - ASB made it exempt from Doze' "$T/out" || f "no line says the kept app was made exempt"
apply list > "$T/list"
grep -qx 'trim=1' "$T/list" || f "list: trim state missing"
grep -qx 'A com.azure.authenticator p' "$T/list" || f "list: rule protection not reported"
grep -qx 'A com.example.game -' "$T/list" || f "list: an ordinary app line wrong"
grep -qx 'E org.telegram.messenger' "$T/list" || f "list: current exemptions missing"
grep -qx 'R com.example.game' "$T/list" || f "list: trimmed apps missing"
grep -qx 'G org.telegram.messenger' "$T/list" || f "list: ASB grants missing"
grep -qx 'K com.example.vpn' "$T/list" || f "list: last keep line without a newline lost"
grep -q 'pwn' "$T/list" && f "list: hostile keep line passed through"
grep -q 'com.android.phone' "$T/list" && f "list: a system entry listed as a user app"
[ -s "$T/wl.log" ] && f "list changed the exemption list: $(tr '\n' ' ' < "$T/wl.log")"
printf '%s\n' com.example.trimmed com.example.vpn > "$T/st/doze_whitelist_keep"
apply >/dev/null
grep -qx -- '-org.telegram.messenger' "$T/wl.log" || f "unticking did not withdraw ASB's grant"
grep -qx 'org.telegram.messenger' "$T/st/doze_whitelist_added" && f "a withdrawn grant is still recorded"
grep -qx -- '-com.example.vpn' "$T/wl.log" && f "unticking another app withdrew the user's own exemption"
printf '%s\n' org.telegram.messenger com.example.trimmed com.example.vpn > "$T/st/doze_whitelist_keep"
apply >/dev/null
grep -qx 'org.telegram.messenger' "$T/st/doze_whitelist_added" || f "re-ticking did not grant again"
conf aggressive 0
apply >/dev/null
grep -qx -- '-org.telegram.messenger' "$T/wl.log" || f "trim off did not withdraw ASB's grant"
grep -qx '+com.example.game' "$T/wl.log" || f "trim off did not give back the trimmed app"
[ -e "$T/st/doze_whitelist_added" ] && f "grant record left behind with trim off"
grep -qx 'com.example.vpn' "$T/wl" || f "the user's own exemption lost with trim off"
grep -qx 'com.example.trimmed' "$T/wl" || f "an app returned earlier lost its exemption with trim off"
apply list > "$T/list.off"
grep -qx 'trim=0' "$T/list.off" || f "list: trim off not reported"
conf moderate 1
apply list > "$T/list.mod"
grep -qx 'trim=0' "$T/list.mod" || f "list: trim reported working with Deep Sleep at moderate"
U="$ROOT/uninstall.sh"
grep -q 'done < /data/adb/asb/doze_whitelist_added' "$U" || f "uninstall does not withdraw ASB's grants"
grep -q 'dumpsys deviceidle whitelist "-$_p"' "$U" || f "uninstall grant removal is not a withdrawal"
[ "$fail" = 0 ] && echo "PASS doze keep list: kept apps given back or made exempt at once, grants withdrawn on untick, off and uninstall"
exit "$fail"
)

t_doze_night_keep_runtime() (
# Runtime (fix158): Deep Sleep on night - what Trimmed and the ticked apps do by day.
#
# A tester asked what the picker's labels mean and to check that Trimmed works. With Deep
# Sleep on night the trim runs inside the sleep window only, and outside it every trimmed app
# is given back - correct, but the picker said "trimming works" by day and showed an empty
# Trimmed with no reason. Worse, the same day path withdrew the exemptions ASB had given to
# ticked apps, so a ticked messenger Android did not exempt was exempt at night and dozed by
# day, against what the card promises. The REAL applier runs on a fake pm / deviceidle and a
# fake clock:
#   - in the window the exempt user apps are trimmed and a ticked app gets ASB's exemption;
#   - out of it the trimmed apps come back and the ticked app keeps its exemption;
#   - unticking by day withdraws ASB's exemption; trim off withdraws everything;
#   - `list` says whether the window is open and when it is, for the picker.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_doze_apply.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL doze night keep: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
cat > "$T/bin/pm" <<'S'
#!/bin/sh
printf 'package:%s\n' org.telegram.messenger com.example.vpn com.example.game
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = deviceidle ] && [ "$2" = whitelist ] || exit 0
case "${3:-}" in
  +*) p="${3#+}"; grep -qx "$p" "$WL" || echo "$p" >> "$WL"; exit 0 ;;
  -*) p="${3#-}"; grep -vx "$p" "$WL" > "$WL.n"; mv "$WL.n" "$WL"; exit 0 ;;
esac
while IFS= read -r p; do echo "user,$p,10001"; done < "$WL"
S
printf '#!/bin/sh\necho "$FAKE_HM"\n' > "$T/bin/date"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/settings"
chmod +x "$T/bin/"*
conf() { printf 'doze_level=%s\ndoze_trim_whitelist=%s\nnight_quiet_auto=0\nnight_quiet_hour_start=23\nnight_quiet_hour_end=6\n' "$1" "$2" > "$T/mod/config/governor.conf"; }
at() { PATH="$T/bin:$PATH" FAKE_HM="$1" WL="$T/wl" MODDIR="$T/mod" ASB_DOZE_STATE_DIR="$T/st" sh "$SRC" ${2:-} </dev/null 2>/dev/null; }
has() { grep -qx "$1" "$T/wl"; }
printf '%s\n' com.example.vpn com.example.game > "$T/wl"
printf '%s\n' org.telegram.messenger > "$T/st/doze_whitelist_keep"
conf night 1
at 02:30 > "$T/o1"
has org.telegram.messenger || f "night: the ticked app was not made exempt"
has com.example.game && f "night: an exempt user app was not trimmed"
grep -qx com.example.game "$T/st/doze_whitelist_removed" 2>/dev/null || f "night: the trim was not recorded"
at 02:40 list > "$T/l1"
grep -qx 'window=1' "$T/l1" || f "list at night: window not open"
grep -qx 'R com.example.game' "$T/l1" || f "list at night: Trimmed empty"
at 14:00 > "$T/o2"
has com.example.game || f "day: a trimmed app was not given back"
has com.example.vpn || f "day: a trimmed app was not given back"
has org.telegram.messenger || f "day: the ticked app lost the exemption ASB gave it"
grep -qx org.telegram.messenger "$T/st/doze_whitelist_added" 2>/dev/null || f "day: ASB's grant record lost"
[ -s "$T/st/doze_whitelist_removed" ] && f "day: trimmed apps still recorded"
grep -q 'ticked apps keep their exemption' "$T/o2" || f "day: no line says the ticked apps keep their exemption"
at 14:10 list > "$T/l2"
grep -qx 'trim=1' "$T/l2" || f "list by day: trim switch state lost"
grep -qx 'window=0' "$T/l2" || f "list by day: window reported open"
grep -qx 'night=23:00-06:00' "$T/l2" || f "list by day: no sleep window"
grep -q '^R ' "$T/l2" && f "list by day: Trimmed not empty"
grep -qx 'G org.telegram.messenger' "$T/l2" || f "list by day: ASB's grant missing"
at 23:30 >/dev/null
has com.example.game && f "next night: not trimmed again"
has org.telegram.messenger || f "next night: the ticked app lost its exemption"
at 12:00 >/dev/null
: > "$T/st/doze_whitelist_keep"
at 12:30 >/dev/null
has org.telegram.messenger && f "unticked by day: ASB's exemption not withdrawn"
grep -qx org.telegram.messenger "$T/st/doze_whitelist_added" 2>/dev/null && f "unticked by day: grant still recorded"
has com.example.game || f "unticked by day: an app Android exempted was touched"
printf '%s\n' org.telegram.messenger > "$T/st/doze_whitelist_keep"
at 13:00 >/dev/null
has org.telegram.messenger || f "ticked by day: not made exempt"
conf night 0
at 13:30 >/dev/null
has org.telegram.messenger && f "trim off: ASB's exemption kept"
[ -e "$T/st/doze_whitelist_added" ] && f "trim off: grant record left behind"
conf aggressive 1
at 14:00 list > "$T/l3"
grep -q '^window=' "$T/l3" && f "aggressive: a sleep window reported"
grep -qx 'trim=1' "$T/l3" || f "aggressive: trim not reported"
[ "$fail" = 0 ] && echo "PASS doze night keep: trimmed apps back by day, ticked apps exempt day and night, the picker told when the window opens"
exit "$fail"
)

t_doze_whitelist_trim_runtime() (
# Runtime (fix88): doze exemption trimming matches whole package names, keeps wearable /
# caller-ID / authenticator apps, and gives back what an earlier run took wrongly.
# OP15 /data/adb/asb: the system Gboard was trimmed because a third-party fork is called
# dev.jason.com.google.android.inputmethod.latin; the Galaxy Watch plugin and Truecaller too.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL doze trim: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
printf 'doze_level=aggressive\ndoze_trim_whitelist=1\n' > "$T/mod/config/governor.conf"
cat > "$T/bin/pm" <<'S'
#!/bin/sh
printf 'package:%s\n' dev.jason.com.google.android.inputmethod.latin com.samsung.wearable.watch7plugin com.truecaller com.facebook.katana com.example.chat
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
[ "$1" = deviceidle ] || exit 0
case "$3" in
  +*|-*) echo "$3" >> "$WL_LOG"; exit 0 ;;
esac
printf 'user,%s,10001\n' com.google.android.inputmethod.latin dev.jason.com.google.android.inputmethod.latin com.samsung.wearable.watch7plugin com.truecaller com.facebook.katana com.example.chat
S
chmod +x "$T/bin/"*
printf '%s\n' com.google.android.inputmethod.latin com.samsung.wearable.watch7plugin com.facebook.katana > "$T/st/doze_whitelist_removed"
PATH="$T/bin:$PATH" WL_LOG="$T/wl.log" MODDIR="$T/mod" ASB_DOZE_STATE_DIR="$T/st" \
  sh "$ROOT/runtime/asb_doze_apply.sh" >/dev/null 2>&1 </dev/null
grep -qx '+com.google.android.inputmethod.latin' "$T/wl.log" || f "system Gboard not given back"
grep -qx '+com.samsung.wearable.watch7plugin' "$T/wl.log" || f "watch plugin not given back"
grep -qx -- '-com.google.android.inputmethod.latin' "$T/wl.log" && f "system Gboard trimmed (substring match)"
grep -qx -- '-com.truecaller' "$T/wl.log" && f "caller ID trimmed"
grep -qx -- '-com.samsung.wearable.watch7plugin' "$T/wl.log" && f "watch plugin trimmed"
grep -qx -- '-com.example.chat' "$T/wl.log" || f "an ordinary user app was not trimmed"
grep -qx 'com.facebook.katana' "$T/st/doze_whitelist_removed" || f "a still-valid record was dropped"
grep -qx 'com.google.android.inputmethod.latin' "$T/st/doze_whitelist_removed" && f "returned app still recorded as removed"
[ "$fail" = 0 ] && echo "PASS doze whitelist trim is exact and keeps companions"
exit "$fail"
)

t_drain_meter_runtime() (
# Runtime (fix161, status fix165): one drain measurement for every profile, Stock included,
# kept per profile. fix165: the OP15 battery status reads "Unknown" in every state, and the
# meter took anything but "Discharging" for a charger - in the fix163 capture it measured
# nothing in seven hours. A charger is now a Charging/Full status or a supply online, as the
# governor and the log kit read it.
#
# Asked for: the Monitor's screen-on and screen-off drain on every profile, Stock too, so the
# profiles can be compared. Screen-on drain was only counted inside the Smart tick, and Stock
# runs no governor at all. The REAL runtime/asb_drain_meter.sh is sourced and its step function
# driven through a day: screen-on use, a night, music with the screen off, charging, a gap in
# sampling, a profile switch, the file round trip, and the screen read from the backlight when
# Android's display state is not there.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
M="$ROOT/runtime/asb_drain_meter.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL drain meter: $*" >&2; fail=1; }
grep -q 'sh "$MODDIR/runtime/asb_drain_meter.sh" run' "$ROOT/service.sh" || f "service.sh does not start the meter"
_svc_line="$(grep -n 'runtime/asb_drain_meter.sh" run' "$ROOT/service.sh" | cut -d: -f1)"
awk -v L="$_svc_line" 'NR < L && /^if \[ "\$\{ASB_STOCK_PROFILE:-0\}" != "1" \]; then$/ { open = 1 } NR < L && open && /^fi$/ { open = 0 } END { exit open }' "$ROOT/service.sh" \
  || f "the meter is started inside a non-Stock branch"
grep -q '"runtime/asb_drain_meter.sh"' "$ROOT/.github/workflows/build-debug.yml" || f "CI does not require the meter"

ASB_DM_DIR="$T/asb"; ASB_DM_LIVE="$T/live"; ASB_DM_BL="$T/bl"; ASB_DM_PS="$T/ps"
export ASB_DM_DIR ASB_DM_LIVE ASB_DM_BL ASB_DM_PS
. "$M"
dm_load
rate_on() { _s="$(dm_get "$1" on_s)"; _x="$(dm_get "$1" on_x)"; [ "$_s" -ge 600 ] && [ "$_x" -gt 0 ] && echo $((_x * 360 / _s)) || echo 0; }
rate_off() { _s="$(dm_get "$1" off_s)"; _x="$(dm_get "$1" off_x)"; [ "$(dm_get "$1" off_n)" -ge 1 ] && [ "$_s" -gt 0 ] && echo $((_x * 3600 / _s)) || echo 0; }

t=1000; pct=80
i=0; while [ $i -lt 40 ]; do
  i=$((i + 1)); t=$((t + 30))
  [ $i = 10 ] && pct=79; [ $i = 25 ] && pct=78; [ $i = 40 ] && pct=77
  dm_step "$t" "$pct" 0 1 smart 0
done
[ "$(dm_get smart on_s)" = 1170 ] || f "screen-on seconds: $(dm_get smart on_s), want 1170"
[ "$(rate_on smart)" = 92 ] || f "screen-on rate x10: $(rate_on smart), want 92 (3% in 19.5 min)"
# The screen coming back on ends a night once it stays on past a glance (fix178): five samples,
# two minutes.
wake() { _wk=0; while [ $_wk -lt 5 ]; do _wk=$((_wk + 1)); t=$((t + 30)); dm_step "$t" "$1" 0 1 smart 0; done; }
t=$((t + 30)); dm_step "$t" 77 0 0 smart 0
t=$((t + 7200)); dm_step "$t" 76 0 0 smart 0
t=$((t + 30)); dm_step "$t" 76 0 1 smart 0
[ "$(dm_get smart off_n)" = 0 ] || f "the night was closed by the first screen-on sample - a glance would end it"
t=$((t + 120)); dm_step "$t" 76 0 1 smart 0
[ "$(dm_get smart off_n)" = 1 ] || f "a 2 h night was not counted"
[ "$(rate_off smart)" = 49 ] || f "screen-off rate x100: $(rate_off smart), want 49 (1% in 2 h 0.5 min)"
t=$((t + 90)); dm_step "$t" 76 0 1 smart 0
# A glance in the night - the time checked for a minute - keeps one window (fix178).
t=$((t + 30)); dm_step "$t" 76 0 0 smart 0
t=$((t + 2400)); dm_step "$t" 76 0 0 smart 0
t=$((t + 30)); dm_step "$t" 76 0 1 smart 0
t=$((t + 30)); dm_step "$t" 76 0 1 smart 0
t=$((t + 30)); dm_step "$t" 76 0 0 smart 0
t=$((t + 2400)); dm_step "$t" 75 0 0 smart 0
wake 75
[ "$(dm_get smart off_n)" = 2 ] || f "a glance split the night into two windows under the hour (off_n=$(dm_get smart off_n))"
[ "$(dm_get smart off_s)" = 12150 ] || f "the glanced night: off_s=$(dm_get smart off_s), want 12150"
# Music: audio on consecutive samples drops the window.
t=$((t + 30)); dm_step "$t" 75 0 0 smart 0
t=$((t + 60)); dm_step "$t" 75 0 0 smart 1
t=$((t + 60)); dm_step "$t" 75 0 0 smart 1
t=$((t + 5000)); dm_step "$t" 74 0 0 smart 0
wake 74
[ "$(dm_get smart off_n)" = 2 ] || f "a screen-off stretch with music was counted"
# One sound in the night (a notification, or the first probe after the screen went off) is not
# playback (fix178): every window used to be dropped this way.
t=$((t + 30)); dm_step "$t" 74 0 0 smart 1
t=$((t + 60)); dm_step "$t" 74 0 0 smart 0
t=$((t + 60)); dm_step "$t" 74 0 0 smart 1
t=$((t + 5000)); dm_step "$t" 73 0 0 smart 0
wake 73
[ "$(dm_get smart off_n)" = 3 ] || f "a single sound threw the night away"
t=$((t + 30)); dm_step "$t" 73 0 0 smart 0
t=$((t + 1800)); dm_step "$t" 73 0 0 smart 0
wake 73
[ "$(dm_get smart off_n)" = 3 ] || f "a 30 min screen-off stretch was counted"
_before="$(dm_get smart on_s)"
t=$((t + 30)); dm_step "$t" 74 1 1 smart 0
t=$((t + 30)); dm_step "$t" 75 1 1 smart 0
t=$((t + 30)); dm_step "$t" 75 0 1 smart 0
[ "$(dm_get smart on_s)" = "$_before" ] || f "charging time was counted as screen-on drain"
t=$((t + 30)); dm_step "$t" 75 0 0 smart 0
t=$((t + 3000)); dm_step "$t" 80 1 0 smart 0
t=$((t + 3000)); dm_step "$t" 80 0 1 smart 0
[ "$(dm_get smart off_n)" = 3 ] || f "a night with the charger was counted"
_before="$(dm_get smart on_s)"
t=$((t + 600)); dm_step "$t" 79 0 1 smart 0
[ "$(dm_get smart on_s)" = "$_before" ] || f "a 10 min gap between samples was counted as screen time"
t=$((t + 30)); dm_step "$t" 79 0 1 stock 0
i=0; while [ $i -lt 30 ]; do i=$((i + 1)); t=$((t + 30)); [ $i = 15 ] && dm_step "$t" 78 0 1 stock 0 || dm_step "$t" 79 0 1 stock 0; done
[ "$(dm_get stock on_s)" -gt 0 ] || f "Stock got no screen-on time"
[ "$(dm_get smart on_s)" = "$_before" ] || f "Stock time was booked to Smart"
dm_step "$((t + 30))" 79 0 1 none 0
[ -z "$dm_prof" ] || f "an unknown profile was measured"
# fix189: the windows that did not count, and why - the music night, the 30 minutes, the night
# that ended on the charger.
[ "$dm_rej_media $dm_rej_short $dm_rej_charge" = "1 1 1" ] || f "rejections: media=$dm_rej_media short=$dm_rej_short charge=$dm_rej_charge, want 1 1 1"
dm_flush "$t"
grep -q '^smart 1770 300 17300 300 3$' "$T/asb/drain_meter" || f "file line for smart: $(grep '^smart' "$T/asb/drain_meter")"
grep -qx '1 1 1 smart:charge:50' "$T/asb/drain_meter.rej" || f "rejections not kept: $(cat "$T/asb/drain_meter.rej" 2>/dev/null)"
dm_rej_media=0; dm_load; [ "$dm_rej_media" = 1 ] || f "rejections not read back"
printf '%s\n' 'smart 99 x 1 1 1' 'bogus 1 1 1 1 1' >> "$T/asb/drain_meter"
dm_load
[ "$(dm_get smart on_s)" = 1770 ] && [ "$(dm_get stock on_s)" -gt 0 ] || f "file round trip lost values"
dm_set balanced on_s 14390; dm_set balanced on_x 2000; dm_prof=balanced; dm_add_on 30 1
[ "$(dm_get balanced on_s)" = 7210 ] && [ "$(dm_get balanced on_x)" = 1050 ] || f "screen-on window not halved past 4 h: $(dm_get balanced on_s)/$(dm_get balanced on_x)"
dm_publish
grep -q '^current balanced$' "$T/live" || f "live file does not name the profile"
mkdir -p "$T/bl/panel0-backlight"; echo 0 > "$T/bl/panel0-backlight/brightness"
dm_screen && f "a dark backlight read as screen on"
echo 412 > "$T/bl/panel0-backlight/brightness"
dm_screen || f "a lit backlight read as screen off"
mkdir -p "$T/ps" "$T/psy/usb"; DM_PSY="$T/psy"; echo 0 > "$T/psy/usb/online"
echo Discharging > "$T/ps/status"; dm_charging && f "Discharging read as charging"
echo Charging > "$T/ps/status"; dm_charging || f "Charging not seen"
echo Unknown > "$T/ps/status"; dm_charging && f "the OP15's Unknown status read as charging with no charger online - the meter never measured"
echo 1 > "$T/psy/usb/online"; dm_charging || f "Unknown status with a charger online read as discharging"
echo "Not charging" > "$T/ps/status"; dm_charging || f "a plugged-in held battery counted as discharging"
echo 0 > "$T/psy/usb/online"; dm_charging && f "Not charging with no charger online read as charging"
L="$T/loop"; mkdir -p "$L/bin" "$L/ps" "$L/psy/usb" "$L/bl/panel0-backlight"
echo Unknown > "$L/ps/status"; echo 80 > "$L/ps/capacity"; echo 0 > "$L/psy/usb/online"; echo 300 > "$L/bl/panel0-backlight/brightness"
echo smart > "$L/profile"; echo 1000 > "$L/clock"
printf '#!/bin/sh\nn=$(cat "%s"); n=$((n + 30)); echo $n > "%s"; echo $n\n' "$L/clock" "$L/clock" > "$L/bin/date"
printf '#!/bin/sh\nexec /bin/sleep 0.05\n' > "$L/bin/sleep"
printf '#!/bin/sh\necho 2\n' > "$L/bin/getprop"
chmod +x "$L/bin/date" "$L/bin/sleep" "$L/bin/getprop"
( PATH="$L/bin:$PATH" ASB_DM_DIR="$L/d" ASB_DM_LIVE="$L/live" ASB_DM_PS="$L/ps" ASB_DM_PSY="$L/psy" ASB_DM_BL="$L/bl" \
    ASB_DM_PROFILE="$L/profile" exec sh "$M" run ) >/dev/null 2>&1 &
_lp=$!
_w=0; _on=0
while [ "$_w" -lt 100 ]; do
  _on="$(awk '$1 == "smart" { print $2 }' "$L/live" 2>/dev/null)"
  [ "${_on:-0}" -ge 120 ] 2>/dev/null && break
  /bin/sleep 0.05; _w=$((_w + 1))
done
kill "$_lp" 2>/dev/null; wait "$_lp" 2>/dev/null
[ "${_on:-0}" -ge 120 ] 2>/dev/null || f "the real loop measured no screen-on time with the OP15's Unknown status (smart on_s=${_on:-none})"
[ -s "$L/d/drain_meter" ] || f "the real loop never saved its table"
# fix178: the audio-thread probe is started afresh at each screen-off. The REAL probe and the
# REAL lines of the loop run on a fake audioserver whose output thread ran during screen-on use.
A="$T/aud"; mkdir -p "$A/proc/500/task/501" "$A/noasound"
echo audioserver > "$A/proc/500/comm"; echo AudioOut_D > "$A/proc/500/task/501/comm"
echo "1 2 100" > "$A/proc/500/task/501/schedstat"
sed -n '/^    _lm=0$/,/^    fi$/p' "$M" > "$A/probe.sh"
grep -q '_aa_prev=""' "$A/probe.sh" || f "the loop does not restart the audio probe at screen-off"
( ASB_AUDIO_ASOUND="$A/noasound"; ASB_AUDIO_PROC="$A/proc"; export ASB_AUDIO_ASOUND ASB_AUDIO_PROC
  . "$ROOT/runtime/asb_audio_activity.sh"
  _ls=0; dm_prev_scr=0
  . "$A/probe.sh"                                    # screen off: baseline
  echo "1 2 400" > "$A/proc/500/task/501/schedstat"  # the screen comes on: a video plays
  dm_prev_scr=1; _ls=0
  . "$A/probe.sh"                                    # first sample after screen-off
  [ "$_lm" = 0 ] || { echo "screen-on audio counted as screen-off playback" >&2; exit 1; }
  echo "1 2 430" > "$A/proc/500/task/501/schedstat"
  dm_prev_scr=0
  . "$A/probe.sh"
  [ "$_lm" = 1 ] || { echo "playback with the screen off not seen" >&2; exit 1; }
) || f "audio probe across a screen-on period"
H="$ROOT/webroot/index.html"
grep -q "function lvMeterParse(text)" "$H" || f "the Monitor does not read the meter"
grep -q "const isCharging = batteryStatus !== 'discharging' && (batteryStatus === 'charging' || batteryStatus === 'full' || ma < 0);" "$H" || f "Stock still reads Discharging as charging"
[ "$fail" = 0 ] && echo "PASS drain meter: screen-on and screen-off drain per profile with one method, Stock included; music, charging, gaps and short nights left out"
exit "$fail"
)

t_dsp_effects_guard_runtime() (
# fix73: the DSP is registered in the effects config a HIDL audio HAL reads
# (/odm/etc/audio_effects.xml on SM8650 - field OP12: library staged, never mapped), and a
# crash fuse removes every effects-config bind if audioserver/the HAL then keeps restarting.
# Runtime: the REAL asb_odm_rebind.sh effects-guard against fake pidof/umount/setprop.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/runtime/asb_odm_rebind.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL dsp effects guard: $*" >&2; fail=1; }

# --- installer and boot wiring ------------------------------------------------------------
I="$ROOT/common/install.sh"
grep -q '/odm/etc/audio_effects.xml \\' "$I" || f "installer does not register the HIDL-name odm config"
grep -q 'ro.boot.product.vendor.sku' "$I" || f "installer ignores the vendor SKU dirs"
grep -q 'dsp_effects_blocked' "$I" || f "installer ignores a tripped fuse"
grep -q 'asb_odm_rebind.sh" effects-guard' "$ROOT/service.sh" || f "boot does not start the fuse"
grep -q 'dsp_effects_blocked' "$ROOT/uninstall.sh" || f "uninstall leaves the fuse flag"
grep -q 'first $_dn in lookup order' "$ROOT/tools/asb_diag.sh" || f "asbdiag does not name the config the HAL reads"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || f "asbdiag copies differ"

# --- runtime ---------------------------------------------------------------------------
SH="${ASB_TEST_SH:-sh}"
[ -x "$ROOT/../mksh_bin" ] && SH="$ROOT/../mksh_bin"
mkdir -p "$T/bin" "$T/state"
cat > "$T/bin/pidof" <<'X'
#!/bin/sh
# audioserver pid comes from a counter file advanced on every call when CRASHING=1
case "$1" in
  audioserver)
    n="$(cat "$PIDF" 2>/dev/null || echo 100)"
    [ "${CRASHING:-0}" = 1 ] && { n=$((n + 1)); echo "$n" > "$PIDF"; }
    echo "$n" ;;
  android.hardware.audio.service_64) echo 900 ;;
  *) exit 1 ;;
esac
X
printf '#!/bin/sh\necho "$@" >> "$UMLOG"\nexit 0\n' > "$T/bin/umount"
printf '#!/bin/sh\necho "$@" >> "$SPLOG"\n' > "$T/bin/setprop"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*

run_guard() {   # $1 = CRASHING
  printf '/odm/etc/audio_effects.xml|%s/p1\n/odm/etc/camera/x.json|%s/p2\n' "$T" "$T" > "$T/man"
  true > "$T/p1"; true > "$T/p2"
  printf '1 2 0:1 / /odm/etc/audio_effects.xml rw - f2fs /dev/x rw\n' > "$T/mi"
  rm -f "$T/state/dsp_effects_blocked" "$T/um" "$T/sp" "$T/pid"
  ( PATH="$T/bin:$PATH" CRASHING="$1" PIDF="$T/pid" UMLOG="$T/um" SPLOG="$T/sp" \
    ASB_ODM_MAN="$T/man" ASB_ODM_LOG="$T/log" ASB_ODM_MOUNTINFO="$T/mi" ASB_ODM_NS=none \
    ASB_ODM_STATE="$T/state" ASB_ODM_GUARD_POLLS=6 ASB_ODM_GUARD_SLEEP=0 \
    "$SH" "$R" effects-guard )
}

run_guard 0
[ ! -f "$T/state/dsp_effects_blocked" ] || f "stable audio tripped the fuse"
grep -q '/odm/etc/audio_effects.xml' "$T/man" || f "stable audio lost the effects bind"
grep -q 'result=stable restarts=0' "$T/log" || f "stable verdict not logged"

run_guard 1
[ -f "$T/state/dsp_effects_blocked" ] || f "crash loop did not trip the fuse"
grep -q 'audio_effects' "$T/man" && f "effects bind still in the manifest after tripping"
grep -q '/odm/etc/camera/x.json' "$T/man" || f "tripping removed an unrelated (camera) bind"
grep -q '/odm/etc/audio_effects.xml' "$T/um" 2>/dev/null || f "effects config not unmounted"
[ ! -f "$T/p1" ] || f "effects payload left behind"
grep -q 'ctl.restart audioserver' "$T/sp" 2>/dev/null || f "audioserver not restarted on stock configs"

# No effects bind at all: the guard does nothing (no polling, no log line).
printf '/odm/etc/camera/x.json|%s/p2\n' "$T" > "$T/man"; true > "$T/log"
( PATH="$T/bin:$PATH" ASB_ODM_MAN="$T/man" ASB_ODM_LOG="$T/log" ASB_ODM_STATE="$T/state" "$SH" "$R" effects-guard )
[ -s "$T/log" ] && f "guard ran without an effects bind"

[ "$fail" = 0 ] && echo "PASS dsp effects guard runtime"
exit "$fail"
)

t_dsp_heat_backoff_runtime() (
# Runtime (fix135): the DSP gain no longer sinks when the volume is changed.
#
# Field report: "loudness, gain and voice only work after I open the WebUI; when I change the
# volume the sound sinks and goes flat; open the WebUI again and it is back". The gain's heat
# back-off read cpu_max_c - the hottest core at that instant - whenever the Smart tuner ran,
# and the tuner runs exactly when that number has just jumped (the volume panel animating) or
# the foreground changed (opening the WebUI). +25 dB became +12 or +8 dB on a cool phone and
# stayed there until the next app switch.
#
# The REAL asb_audio_apply.sh (mirror mode, which the tuner calls) and the REAL helpers run
# here against a mocked property store and mocked Android commands.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL dsp heat back-off: $*" >&2; exit 1; }
MOD="$TMP/mod"; BIN="$TMP/bin"
mkdir -p "$MOD/config" "$MOD/runtime" "$BIN"
cp "$ROOT_DIR/runtime/asb_audio_apply.sh" "$ROOT_DIR/runtime/asb_dsp_thermal.sh" \
   "$ROOT_DIR/runtime/asb_dsp_live.sh" "$MOD/runtime/"
printf 'dsp_loudness=25\ndsp_bass=2\ndsp_voice=4\ndsp_outputs=speaker\n' > "$MOD/config/governor.conf"
PROPS="$TMP/props"; : > "$PROPS"
cat > "$BIN/getprop" <<'EOF'
#!/bin/sh
echo "$1" >> "$GP_LOG"
grep -m1 "^$1=" "$PROPS" 2>/dev/null | cut -d= -f2-
EOF
cat > "$BIN/resetprop" <<'EOF'
#!/bin/sh
[ "$1" = "-n" ] && shift
grep -v "^$1=" "$PROPS" > "$PROPS.t" 2>/dev/null || true
printf '%s=%s\n' "$1" "$2" >> "$PROPS.t"; mv "$PROPS.t" "$PROPS"
EOF
cp "$BIN/resetprop" "$BIN/setprop"
cat > "$BIN/pkill" <<'EOF'
#!/bin/sh
echo "$*" >> "$PK_LOG"
EOF
cat > "$BIN/dumpsys" <<'EOF'
#!/bin/sh
case "$1" in audio) cat "$AUDIO_DUMP" 2>/dev/null ;; media.audio_flinger) cat "$AF_DUMP" 2>/dev/null ;; esac
EOF
chmod 0755 "$BIN"/*
export PATH="$BIN:$PATH" PROPS GP_LOG="$TMP/gp.log" PK_LOG="$TMP/pk.log" \
       AUDIO_DUMP="$TMP/audio.dump" AF_DUMP="$TMP/af.dump" \
       ASB_DSP_TH_STATE="$TMP/dsp_thermal" ASB_DSP_TH_BAT="$TMP/bat_temp"
prop() { grep -m1 "^$1=" "$PROPS" | cut -d= -f2-; }
setp() { resetprop -n "$1" "$2"; }
mirror() { MODDIR="$MOD" sh "$MOD/runtime/asb_audio_apply.sh" mirror >/dev/null; }
bat() { echo "$1" > "$TMP/bat_temp"; }
setp persist.asb.dsp.enable 1
setp persist.asb.dsp.outputs speaker
setp persist.asb.dsp.route speaker
setp persist.asb.dsp.gain_mb 800        # what the old CPU rule left behind

# 1. Cool phone (battery 29.5 C): full gain, whatever the CPU did a second ago. The old rule
#    gave 800 here with cpu_max_c=70.
bat 295
mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "cool phone: gain $(prop persist.asb.dsp.gain_mb), want 2500"
[ "$(prop persist.vendor.asb.dsp.gain_mb)" = 2500 ] || fail "vendor copy not updated"
grep -q 'USR1' "$PK_LOG" || fail "the attach daemon was not woken for the restored gain"
grep -qx 'reason=cool' "$ASB_DSP_TH_STATE" || fail "decision not recorded"

# 2. Hot on the speaker: one step at 42 C, and it holds until 40 C (hysteresis).
: > "$PK_LOG"
bat 425; mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 1200 ] || fail "42.5 C on the speaker: $(prop persist.asb.dsp.gain_mb), want 1200"
grep -qx 'reason=hot_speaker' "$ASB_DSP_TH_STATE" || fail "hot_speaker not recorded"
bat 410; mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 1200 ] || fail "41 C dropped the back-off (no hysteresis)"
: > "$PK_LOG"; mirror
[ -s "$PK_LOG" ] && fail "the daemon was woken although nothing changed"
bat 395; mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "39.5 C: back-off not released"

# 3. Two steps at 45 C; back to one step only under 43 C.
bat 455; mirror; [ "$(prop persist.asb.dsp.gain_mb)" = 800 ] || fail "45.5 C: want 800"
bat 440; mirror; [ "$(prop persist.asb.dsp.gain_mb)" = 800 ] || fail "44 C left step 2 too early"
bat 425; mirror; [ "$(prop persist.asb.dsp.gain_mb)" = 1200 ] || fail "42.5 C after step 2: want 1200"

# 4. Bluetooth and wired are never reduced - the amplifier is not in the phone / drives mW.
setp persist.asb.dsp.outputs bt; setp persist.asb.dsp.route bt
bat 470; mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "Bluetooth reduced at 47 C"
grep -qx 'reason=hot_not_speaker' "$ASB_DSP_TH_STATE" || fail "hot_not_speaker not recorded"
# outputs=all: nothing keeps the route property fresh, so the music stream's own line decides.
setp persist.asb.dsp.outputs all; setp persist.asb.dsp.route bt
printf '%s\n' '- STREAM_VOICE_CALL:' '   Devices: earpiece' '- STREAM_MUSIC:' '   Muted: false' \
  '   Devices: speaker' '- STREAM_ALARM:' '   Devices: speaker' > "$AUDIO_DUMP"
mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 800 ] || fail "outputs=all on the speaker at 47 C: want 800 (stale route used)"

# 5. Unknown temperature never reduces.
rm -f "$TMP/bat_temp" "$ASB_DSP_TH_STATE"; mirror
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "unreadable battery temperature reduced the gain"

# 6. The once-a-minute check: cool twice in a row costs no property reads past "enable".
. "$MOD/runtime/asb_dsp_thermal.sh"
bat 300; setp persist.asb.dsp.gain_requested_mb 2500; setp persist.asb.dsp.gain_mb 1200
rm -f "$ASB_DSP_TH_STATE"
MODDIR="$MOD" asb_dsp_thermal_tick
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "first check after boot did not release a held gain"
: > "$GP_LOG"
MODDIR="$MOD" asb_dsp_thermal_tick
[ "$(grep -c '' "$GP_LOG")" = 1 ] || fail "cool tick read $(grep -c '' "$GP_LOG") properties, want 1 (enable)"
setp persist.asb.dsp.enable 0; : > "$GP_LOG"; bat 480
MODDIR="$MOD" asb_dsp_thermal_tick
[ "$(prop persist.asb.dsp.gain_mb)" = 2500 ] || fail "DSP off: the check touched the gain"

# 7. The step table itself.
for c in '300 0 0' '420 0 1' '450 0 2' '419 1 1' '399 1 0' '449 1 1' '450 1 2' '430 2 2' '429 2 1' '399 2 0' ' 0 0' 'x 2 0'; do
  set -- $c
  if [ $# = 3 ]; then got="$(asb_dsp_th_step "$1" "$2")"; want="$3"; else got="$(asb_dsp_th_step "" "$1")"; want="$2"; fi
  [ "$got" = "$want" ] || fail "step table: '$c' gave $got"
done
[ "$(asb_dsp_th_cap 3000 0 speaker)" = 2500 ] || fail "cap above +25 dB"
[ "$(asb_dsp_th_cap 900 1 speaker)" = 900 ] || fail "a gain under the step was raised"
[ "$(asb_dsp_th_cap 2500 2 unknown)" = 800 ] || fail "unknown route is not treated as the speaker"
[ "$(asb_dsp_th_cap 2500 2 wired)" = 2500 ] || fail "wired reduced"

# 8. Wiring: every gain writer uses the same rule; the CPU rule is gone.
A="$ROOT_DIR/runtime/asb_audio_apply.sh"
grep -q 'cpu_max_c=' "$A" && fail "asb_audio_apply.sh still reads the CPU temperature"
[ "$(grep -c 'asb_dsp_thermal_decide' "$A")" -ge 2 ] || fail "the WebUI apply path skips the heat rule"
grep -q 'asb_dsp_thermal_tick' "$ROOT_DIR/service.sh" || fail "no once-a-minute re-check"
echo "PASS dsp heat back-off: battery-based, hysteresis, loudspeaker only, re-checked and pushed at once"
)

t_dsp_legacy_core_runtime() (
# fix74: the legacy (HIDL / AELI) DSP effect runs the shared core and takes the gain the
# attach daemon pushes. Before, it had its own gain+limiter copy (no saturation, no bass,
# no bit-exact bypass), configured itself from persist.asb.dsp.* alone - which a vendor
# HAL process cannot read, leaving a loaded effect in bypass - and declared the null type
# while the daemon creates it by Loudness Enhancer type + implementation uuid.
#
# Executable fixture: the REAL src/DSP/asb_dsp.c compiled on the host against a property
# stub, driven through its own AELI create / command() / process() entry points.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/DSP/asb_dsp.c"
fail() { echo "FAIL legacy dsp core: $*" >&2; exit 1; }
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || CC=gcc
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

grep -q '#include "asb_dsp_core.h"' "$SRC" || fail "legacy effect does not include the shared core"
grep -q 'asb_core_configure_ex' "$SRC" || fail "legacy effect does not configure the shared core"
grep -q 'persist.vendor.asb.dsp.%s' "$SRC" || fail "legacy effect ignores the vendor-namespace props"
grep -q 'I"$SCRIPT_DIR/DSP_AIDL"' "$ROOT/src/build_ndk_release.sh" || fail "NDK build lacks the core include path"
for w in build-debug build-release; do
  grep -q 'src/DSP_AIDL/asb_dsp_core.h' "$ROOT/.github/workflows/$w.yml" || fail "$w.yml does not require the core header"
done

mkdir -p "$T/inc/sys"
cat > "$T/inc/sys/system_properties.h" <<'X'
#pragma once
#include <string.h>
#define PROP_VALUE_MAX 92
#define ASB_TEST_PROPS 16
static char g_tp_key[ASB_TEST_PROPS][96];
static char g_tp_val[ASB_TEST_PROPS][PROP_VALUE_MAX];
static int  g_tp_n;
static void tp_set(const char *k, const char *v) {
    for (int i = 0; i < g_tp_n; i++) if (!strcmp(g_tp_key[i], k)) { strcpy(g_tp_val[i], v); return; }
    strcpy(g_tp_key[g_tp_n], k); strcpy(g_tp_val[g_tp_n], v); g_tp_n++;
}
static void tp_clear(void) { g_tp_n = 0; }
static int __system_property_get(const char *k, char *v) {
    for (int i = 0; i < g_tp_n; i++) if (!strcmp(g_tp_key[i], k)) { strcpy(v, g_tp_val[i]); return (int)strlen(v); }
    v[0] = 0; return 0;
}
X

cat > "$T/drv.c" <<'X'
#include "asb_dsp.c"
#include <stdio.h>

static effect_handle_t h;
static int cmd(uint32_t code, uint32_t sz, void *data) {
    int reply = 12345; uint32_t rs = sizeof(int);
    int r = (*h)->command(h, code, sz, data, &rs, &reply);
    if (r != 0) return r;
    return reply;
}
static void make(int ch, uint8_t fmt, uint8_t access) {
    const effect_uuid_t u = g_asb_descriptor.uuid;
    if (AELI.create_effect(&u, 0, 0, &h) != 0) { puts("create"); exit(1); }
    effect_config_t cfg; memset(&cfg, 0, sizeof(cfg));
    cfg.inputCfg.samplingRate = cfg.outputCfg.samplingRate = 48000;
    uint32_t mask = (1u << ch) - 1u;
    cfg.inputCfg.channels = cfg.outputCfg.channels = mask;
    cfg.inputCfg.format = cfg.outputCfg.format = fmt;
    cfg.outputCfg.accessMode = access;
    if (cmd(EFFECT_CMD_INIT, 0, NULL) != 0) { puts("init"); exit(1); }
    if (cmd(EFFECT_CMD_SET_CONFIG, sizeof(cfg), &cfg) != 0) { puts("cfg"); exit(1); }
    if (cmd(EFFECT_CMD_ENABLE, 0, NULL) != 0) { puts("enable"); exit(1); }
}
static int push(int32_t param, int32_t value, uint32_t size_override) {
    uint8_t buf[sizeof(effect_param_t) + 8] = {0};
    effect_param_t *p = (effect_param_t *)buf;
    p->psize = 4; p->vsize = 4;
    memcpy(p->data, &param, 4); memcpy(p->data + 4, &value, 4);
    return cmd(EFFECT_CMD_SET_PARAM, size_override ? size_override : sizeof(buf), buf);
}
#define N 4800
static float in_f[N * 10], out_f[N * 10];
static void sig_f(int ch, float amp) {
    for (int i = 0; i < N; i++) for (int k = 0; k < ch; k++)
        in_f[i * ch + k] = amp * sinf(2.0f * 3.14159f * 440.0f * (float)i / 48000.0f + (float)k);
}
static float run_f(int ch) {
    audio_buffer_t a = { .frameCount = N, .f32 = in_f }, b = { .frameCount = N, .f32 = out_f };
    memset(out_f, 0, sizeof(out_f));
    if ((*h)->process(h, &a, &b) != 0) { puts("process"); exit(1); }
    double si = 0, so = 0;
    for (int i = 0; i < N * ch; i++) { si += in_f[i] * in_f[i]; so += out_f[i] * out_f[i]; }
    return (float)(10.0 * log10(so / si));
}
static int bitexact(int ch) { return memcmp(in_f, out_f, sizeof(float) * N * ch) == 0; }
static float peak_out(int ch) { float m = 0; for (int i = 0; i < N * ch; i++) if (fabsf(out_f[i]) > m) m = fabsf(out_f[i]); return m; }

int main(void) {
    /* descriptor: Loudness Enhancer type, ASB uuid */
    const effect_uuid_t le = { 0xfe3199be, 0xaed0, 0x413f, 0x87bb, { 0x11, 0x26, 0x0e, 0xb6, 0x3c, 0xf1 } };
    if (memcmp(&g_asb_descriptor.type, &le, sizeof(le))) { puts("FAIL type is not Loudness Enhancer"); return 1; }

    /* 1. props invisible (vendor HAL view): bit-exact bypass */
    tp_clear(); make(2, AUDIO_FORMAT_PCM_FLOAT, EFFECT_BUFFER_ACCESS_WRITE); sig_f(2, 0.2f);
    run_f(2); if (!bitexact(2)) { puts("FAIL no props should be a bit-exact bypass"); return 1; }

    /* 2. the daemon's gain push turns it on without any readable property */
    if (push(0, 600, 0) != 0) { puts("FAIL set_param status"); return 1; }
    float d = run_f(2);
    if (d < 3.0f) { printf("FAIL pushed +6 dB delivered %.2f dB\n", d); return 1; }
    if (peak_out(2) > 0.984f) {   /* default ceiling -15 mB = 0.983 */ printf("FAIL limiter ceiling broken: %.3f\n", peak_out(2)); return 1; }

    /* 3. route not selected -> daemon pushes 0 -> bit-exact again */
    push(0, 0, 0); run_f(2);
    if (!bitexact(2)) { puts("FAIL gain 0 push should bypass bit-exact"); return 1; }

    /* 4. malformed / foreign parameters are ignored, not applied */
    push(0, 900, 10); run_f(2);
    if (!bitexact(2)) { puts("FAIL truncated SET_PARAM was applied"); return 1; }
    push(7, 900, 0); run_f(2);
    if (!bitexact(2)) { puts("FAIL foreign parameter id was applied as gain"); return 1; }
    (*h)->command(h, EFFECT_CMD_DISABLE, 0, NULL, &(uint32_t){4}, &(int){0});
    AELI.release_effect(h);

    /* 5. vendor-namespace props win over the legacy name */
    tp_clear();
    tp_set("persist.asb.dsp.enable", "1"); tp_set("persist.asb.dsp.gain_mb", "0");
    tp_set("persist.vendor.asb.dsp.enable", "1"); tp_set("persist.vendor.asb.dsp.gain_mb", "600");
    make(2, AUDIO_FORMAT_PCM_FLOAT, EFFECT_BUFFER_ACCESS_WRITE); sig_f(2, 0.2f);
    d = run_f(2); if (d < 3.0f) { printf("FAIL vendor prop not preferred (%.2f dB)\n", d); return 1; }
    AELI.release_effect(h);

    /* 6. shared-core features reach the legacy effect: softclip is bounded */
    tp_set("persist.vendor.asb.dsp.softclip", "1"); tp_set("persist.vendor.asb.dsp.gain_mb", "2500");
    make(2, AUDIO_FORMAT_PCM_FLOAT, EFFECT_BUFFER_ACCESS_WRITE); sig_f(2, 0.9f);
    run_f(2); if (peak_out(2) > 1.0f) { puts("FAIL softclip escaped [-1,1]"); return 1; }
    AELI.release_effect(h);

    /* 7. 16-bit ACCUMULATE with softclip adds into the output instead of overwriting */
    make(2, AUDIO_FORMAT_PCM_16_BIT, EFFECT_BUFFER_ACCESS_ACCUMULATE);
    {
        static int16_t i16[N * 2], o16[N * 2];
        for (int i = 0; i < N * 2; i++) { i16[i] = 0; o16[i] = 1000; }
        audio_buffer_t a = { .frameCount = N, .s16 = i16 }, b = { .frameCount = N, .s16 = o16 };
        (*h)->process(h, &a, &b);
        for (int i = 0; i < N * 2; i++) if (o16[i] != 1000) { puts("FAIL s16 accumulate overwrote the mix"); return 1; }
    }
    AELI.release_effect(h);

    /* 8. more channels than the core's state holds: passthrough, no out-of-bounds */
    tp_set("persist.vendor.asb.dsp.bass_db", "6");
    make(10, AUDIO_FORMAT_PCM_FLOAT, EFFECT_BUFFER_ACCESS_WRITE); sig_f(10, 0.2f);
    run_f(10); if (!bitexact(10)) { puts("FAIL 10-channel stream was processed"); return 1; }
    AELI.release_effect(h);

    puts("ok");
    return 0;
}
X

_san=""
printf 'int main(void){return 0;}\n' > "$T/probe.c"
if "$CC" -fsanitize=address,undefined "$T/probe.c" -o "$T/probe" >/dev/null 2>&1 && "$T/probe" >/dev/null 2>&1; then
  _san="-fsanitize=address,undefined -fno-sanitize-recover=all"
fi
# shellcheck disable=SC2086
"$CC" -std=gnu11 -O1 -g -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Werror \
  $_san -I"$T/inc" -I"$ROOT/src/DSP" -I"$ROOT/src/DSP_AIDL" "$T/drv.c" -lm -o "$T/drv" \
  || fail "the legacy effect does not compile against the shared core"
out="$("$T/drv" 2>&1)" || fail "$out"
[ "$out" = "ok" ] || fail "$out"
echo "PASS legacy DSP runs the shared core"
)

t_dsp_live_state_runtime() (
# Runtime (fix135): asbdiag, the action screen and captures say what AudioFlinger is doing
# with ASB's effect - processing, idle, gone, or SUSPENDED because an app enabled an effect of
# its own on the same output (global effects yield to per-app ones). "Registered" alone could
# not tell a flat-sounding phone's four causes apart.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL dsp live state: $*" >&2; exit 1; }
. "$ROOT_DIR/runtime/asb_dsp_live.sh"
T="$(printf '\t')"

# Android 14-16 layout: the effect on a deep-buffer mixer, processing.
cat > "$TMP/active.txt" <<EOF
Output thread 0xb400007412b95080, name AudioOut_D, tid 14652, type 0 (MIXER):
  1 Effect Chains
${T}Effect ID 41:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00000   003   y          n       y       n
${T}${T}Descriptor:
${T}${T}- UUID: 7a8044a0-1a14-11e3-a184-0002a5d5c51b
Output thread 0xb4000073e985e540, name AudioOut_1D, tid 14691, type 0 (MIXER):
  I/O handle: 29
  Sample rate: 48000 Hz
  1 Effect Chains
${T}Effect ID 59:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00000   003   y          n       y       n
${T}${T}Descriptor:
${T}${T}- UUID: a5b10001-7e55-4c60-9f21-415342445350
${T}${T}- TYPE: fe3199be-aed0-413f-87bb-11260eb63cf1
${T}${T}- name: ASB Loudness
EOF
out="$(asb_dsp_live_state "$TMP/active.txt")"
[ "$out" = "found=1 thread=AudioOut_1D type=MIXER rate=48000 session=0 state=ACTIVE enabled=y suspended=n others_enabled=0" ] \
  || fail "active: $out"
[ "$(asb_dsp_live_explain "$out")" = processing ] || fail "active explained as: $(asb_dsp_live_explain "$out")"

# Suspended: an app's own effect enabled on session 113 of the same output. An enabled
# per-app effect on ANOTHER output does not count.
cat > "$TMP/susp.txt" <<EOF
Output thread 0xa, name AudioOut_D, tid 1, type 0 (MIXER):
${T}Effect ID 7:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00097   003   y          n       y       n
${T}${T}- UUID: 0bed4300-ddd6-11db-8f34-0002a5d5c51b
Output thread 0xb, name AudioOut_1D, tid 2, type 1 (DIRECT):
  Sample rate: 96000 Hz
${T}Effect ID 60:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00113   003   y          n       y       n
${T}${T}- UUID: ce772f20-847d-11df-bb17-0002a5d5c51b
${T}Effect ID 59:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00000   000   y          n       y       y
${T}${T}- UUID: a5b10001-7e55-4c60-9f21-415342445350
EOF
out="$(asb_dsp_live_state "$TMP/susp.txt")"
[ "$out" = "found=1 thread=AudioOut_1D type=DIRECT rate=96000 session=0 state=IDLE enabled=y suspended=y others_enabled=1" ] \
  || fail "suspended: $out"
asb_dsp_live_explain "$out" | grep -q '^SUSPENDED by AudioFlinger' || fail "suspension not named"

# fix139: a call's echo canceller and noise suppressor are enabled on CAPTURE sessions. The
# input threads come after the outputs in the dump; their effects (and their sample rate) are
# not the output's business.
cat "$TMP/active.txt" - > "$TMP/call.txt" <<EOF
Input thread 0xd, name AudioIn_3E, tid 4, type 3 (RECORD):
  Sample rate: 16000 Hz
${T}Effect ID 80:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00145   003   y          n       y       n
${T}${T}- UUID: bb392ec0-8d4d-11e0-a896-0002a5d5c51b
${T}Effect ID 81:
${T}${T}Session State Registered Internal Enabled Suspended:
${T}${T}00145   003   y          n       y       n
${T}${T}- UUID: c06c8400-8e06-11e0-9cb6-0002a5d5c51b
EOF
out="$(asb_dsp_live_state "$TMP/call.txt")"
[ "$out" = "found=1 thread=AudioOut_1D type=MIXER rate=48000 session=0 state=ACTIVE enabled=y suspended=n others_enabled=0" ] \
  || fail "capture-side effects counted against the output: $out"

# Older header without Internal/Suspended: parsed by name, unknown columns say "?".
cat > "$TMP/old.txt" <<EOF
Output thread 0xc, name AudioOut_15, tid 3, type 0 (MIXER):
${T}Effect ID 12:
${T}${T}Session Status State Engine:
${T}${T}00000   000    003   0xb400007
${T}${T}- UUID: a5b10001-7e55-4c60-9f21-415342445350
EOF
out="$(asb_dsp_live_state "$TMP/old.txt")"
[ "$out" = "found=1 thread=AudioOut_15 type=MIXER rate=? session=0 state=ACTIVE enabled=? suspended=? others_enabled=0" ] \
  || fail "older layout: $out"

# Released by the attach daemon (or never attached).
grep -v 'a5b10001' "$TMP/active.txt" > "$TMP/none.txt"
[ "$(asb_dsp_live_state "$TMP/none.txt")" = found=0 ] || fail "absent instance reported"
asb_dsp_live_explain found=0 | grep -q '^no live instance' || fail "absent instance not explained"

# Wired into asbdiag (both copies), the action screen and the capture.
for f in "$ROOT_DIR/tools/asb_diag.sh" "$ROOT_DIR/system/bin/asbdiag"; do
  grep -q 'asb_dsp_live_state' "$f" || fail "${f##*/} does not show the live effect"
done
grep -q 'T_A_SUSP' "$ROOT_DIR/action.sh" || fail "action screen silent about a suspended effect"
grep -q 'asb.dsp.effect_live' "$ROOT_DIR/tools/logkit/_asb_logkit_common.sh" || fail "captures do not record the live effect"
grep -q 'asb.dsp.heat' "$ROOT_DIR/tools/logkit/_asb_logkit_common.sh" || fail "captures do not record the heat decision"
for f in "$ROOT_DIR"/runtime/i18n/action_*.sh; do
  grep -q '^T_A_HEAT=' "$f" && grep -q '^T_A_SUSP=' "$f" || fail "heat/suspend lines missing in ${f##*/}"
done
echo "PASS dsp live state: processing / idle / released / suspended told apart, output rate shown, capture effects not counted"
)

t_dsp_outputs_off_runtime() (
# Runtime (fix155): "DSP Outputs = off" switches the whole DSP off in one step.
#
# Asked for: turning the DSP off meant pulling loudness, bass and voice tone to zero one by
# one, and setting them up again afterwards. The REAL asb_audio_apply.sh runs on a mocked
# property store: with dsp_outputs=off the engine is disabled and says why, the slider
# values stay in the config, the Smart tuner's mirror pass does not switch it back on, and
# the WebUI, action screen and asbdiag treat it as off.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL dsp outputs off: $*" >&2; exit 1; }
MOD="$T/mod"; BIN="$T/bin"
mkdir -p "$MOD/config" "$MOD/runtime" "$BIN"
cp "$ROOT/runtime/asb_audio_apply.sh" "$ROOT/runtime/asb_dsp_thermal.sh" "$ROOT/runtime/asb_dsp_live.sh" "$MOD/runtime/"
printf 'dsp_loudness=25\ndsp_bass=2\ndsp_voice=4\ndsp_outputs=off\naudio_profile=hifi\n' > "$MOD/config/governor.conf"
PROPS="$T/props"; : > "$PROPS"
cat > "$BIN/getprop" <<'X'
#!/bin/sh
grep -m1 "^$1=" "$PROPS" 2>/dev/null | cut -d= -f2-
X
cat > "$BIN/resetprop" <<'X'
#!/bin/sh
[ "$1" = "-n" ] && shift
grep -v "^$1=" "$PROPS" > "$PROPS.t" 2>/dev/null || true
printf '%s=%s\n' "$1" "$2" >> "$PROPS.t"; mv "$PROPS.t" "$PROPS"
X
cp "$BIN/resetprop" "$BIN/setprop"
printf '#!/bin/sh\nexit 0\n' > "$BIN/pkill"
printf '#!/bin/sh\nexit 0\n' > "$BIN/dumpsys"
chmod 0755 "$BIN"/*
export PATH="$BIN:$PATH" PROPS ASB_DSP_TH_STATE="$T/th" ASB_DSP_TH_BAT="$T/bat"
prop() { grep -m1 "^$1=" "$PROPS" | cut -d= -f2-; }
resetprop -n persist.asb.dsp.enable 1
MODDIR="$MOD" sh "$MOD/runtime/asb_audio_apply.sh" dsp > "$T/out" 2>&1 || true
[ "$(prop persist.asb.dsp.enable)" = 0 ] || fail "the DSP is still enabled: $(prop persist.asb.dsp.enable)"
[ "$(prop persist.asb.dsp.inactive_reason)" = outputs_off ] || fail "no reason given: $(prop persist.asb.dsp.inactive_reason)"
grep -q 'dsp=off(outputs)' "$T/out" || fail "the run does not say why: $(cat "$T/out")"
grep -qx 'dsp_loudness=25' "$MOD/config/governor.conf" && grep -qx 'dsp_bass=2' "$MOD/config/governor.conf" \
  || fail "the sliders were touched"
MODDIR="$MOD" sh "$MOD/runtime/asb_audio_apply.sh" mirror >/dev/null 2>&1 || true
[ "$(prop persist.asb.dsp.enable)" = 0 ] || fail "the mirror pass switched the DSP back on"
UI="$ROOT/webroot/index.html"
grep -q "key:'dsp_outputs', type:'seg', def:'all', stock:'all', opts:\['off','all'," "$UI" || fail "no off in the WebUI"
grep -q "_cfgVals\['dsp_outputs'\] === 'off' &&" "$UI" || fail "the DSP cards do not show off"
for l in ar de en es fr hy id it pt ru tr uk zh; do
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['optFor']['dsp_outputs']['off']" "$ROOT/webroot/i18n/$l.json" \
    || fail "$l.json has no label for off"
done
grep -q '\[ "$(_cfg dsp_outputs)" = "off" \] && \[ "$_a_dsp" != "off" \]' "$ROOT/action.sh" || fail "action screen still lists the DSP as on"
grep -q '^\[ "$(cfg dsp_outputs)" = "off" \] && _dsp_g=outputs_off$' "$ROOT/tools/asb_diag.sh" || fail "asbdiag still checks the gain"
echo "PASS dsp outputs off: one switch turns the DSP off, sliders kept, mirror keeps it off"
)

t_dsp_reference_contract() (
# Regression: the known-good DSP path must not depend on a device-pack
# marker. It stages the exact shipped AIDL library selected by the ABI helper.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOD="$TMP/module"
mkdir -p "$MOD/bin" "$MOD/config" "$MOD/runtime"
cp "$ROOT/config/governor.conf" "$MOD/config/governor.conf"
cp "$ROOT/runtime/asb_dsp_abi_apply.sh" "$MOD/runtime/asb_dsp_abi_apply.sh"
# A source-only archive carries no prebuilt libraries (fix133). The static gates below still
# run; only the staging half needs the .so files. It is skipped ONLY when the caller says so
# explicitly - a release build never sets this, so a package that lost its libraries still
# fails here instead of quietly falling back to the legacy effect.
PB="$ROOT/src/DSP_AIDL/prebuilt"
_pb_missing=0
for _pb in arm64-v8a/libasbdsp_v3.so armeabi-v7a/libasbdsp_v3.so arm64-v8a/asb_dsp_attach \
           arm64-v8a/libasbdsp_v2.so armeabi-v7a/libasbdsp_v2.so; do
  [ -s "$PB/$_pb" ] || _pb_missing=1
done
if [ "$_pb_missing" = 1 ] && [ "${ASB_DSP_REFERENCE_OPTIONAL:-0}" != 1 ]; then
  echo "FAIL: DSP prebuilt libraries missing under src/DSP_AIDL/prebuilt (set ASB_DSP_REFERENCE_OPTIONAL=1 only for a source-only archive)" >&2
  exit 1
fi
if [ "$_pb_missing" = 0 ]; then
  cp "$PB/arm64-v8a/libasbdsp_v3.so" "$MOD/bin/libasbdsp_v3.so"
  cp "$PB/armeabi-v7a/libasbdsp_v3.so" "$MOD/bin/libasbdsp_v3_32.so"
fi

# The feature remains enabled; user-level dsp_loudness defaults to off, so this
# does not enable any gain by itself.
grep -qx 'AUDIO=1' "$ROOT/features.conf"
if grep -q 'asb_device_pack_allows audio' "$ROOT/runtime/asb_dsp_abi_apply.sh" \
   || grep -q 'asb_device_pack_allows audio' "$ROOT/runtime/asb_audio_apply.sh"; then
  echo 'FAIL: direct DSP runtime still has a fingerprint-only audio gate' >&2
  exit 1
fi
# service.sh owns the boot-time overlay bind and attacher. It may retain separate
# gates for non-DSP vendor tweaks later in the file, but never around this block.
if sed -n '/^(/,/^) >\/dev\/null 2>\&1 \&/p' "$ROOT/service.sh" | grep -q 'asb_device_pack_allows audio'; then
  echo 'FAIL: boot-time DSP attacher still has a fingerprint-only audio gate' >&2
  exit 1
fi
if sed -n '/_abi_conf=/,/^fi$/p' "$ROOT/post-fs-data.sh" | grep -q 'asb_device_pack_allows audio'; then
  echo 'FAIL: early DSP ABI staging still has a fingerprint-only audio gate' >&2
  exit 1
fi
grep -q 'DSP status: requested' "$ROOT/action.sh" || {
  echo 'FAIL: action UI lacks DSP runtime status' >&2
  exit 1
}
# WebUI already permits 25 dB; every runtime/core/diagnostic path must now deliver that
# same ceiling rather than silently reporting requested +25 but applying legacy +18.
# fix74: the legacy effect runs the shared core, so its cap IS the core's cap.
grep -Fq '#include "asb_dsp_core.h"' "$ROOT/src/DSP/asb_dsp.c" || { echo 'FAIL: legacy DSP does not use the shared core (+25 dB cap)' >&2; exit 1; }
grep -Fq '#define ASB_GAIN_MB_MAX    2500' "$ROOT/src/DSP_AIDL/asb_dsp_core.h" || { echo 'FAIL: AIDL DSP cap is not +25 dB' >&2; exit 1; }
grep -Fq '[ "$_dsp_applied_mb" -gt 2500 ] && _dsp_applied_mb=2500' "$ROOT/runtime/asb_audio_apply.sh" || { echo 'FAIL: runtime DSP cap is not +25 dB' >&2; exit 1; }
grep -Fq '[ "$_dsp_expected_mb" -gt 2500 ] && _dsp_expected_mb=2500' "$ROOT/tools/asb_diag.sh" || { echo 'FAIL: diagnostic DSP cap is not +25 dB' >&2; exit 1; }

if [ "$_pb_missing" = 1 ]; then
  printf '%s\n' 'SKIP DSP reference staging: prebuilt libraries absent, ASB_DSP_REFERENCE_OPTIONAL=1 (static gates passed)'
  exit 0
fi
MODDIR="$MOD" sh "$MOD/runtime/asb_dsp_abi_apply.sh" aidl_v3 >/dev/null
cmp -s "$MOD/bin/libasbdsp_v3.so" "$MOD/system/vendor/lib64/soundfx/libasbdsp.so"
cmp -s "$MOD/bin/libasbdsp_v3_32.so" "$MOD/system/vendor/lib/soundfx/libasbdsp.so"

printf '%s\n' 'PASS DSP reference contract'
)

t_dsp_route_idle_runtime() (
# Runtime (fix137): with nothing playing, the DSP route watcher takes ONE look at the route a
# minute into the idle stretch, so a route published while the headphones were on does not
# outlive them.
#
# OP15 capture 2830: route_published=bt from 22:46 to 08:00 while the audio service had gone
# back to the speaker (play=0 route=speaker in every hourly audio snapshot), and with
# dsp_outputs=bt the attach daemon held the effect all night ("effect_live found=1").
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SVC="$ROOT/service.sh"
fail() { echo "FAIL dsp route idle: $*" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sed -n '/^  _idle_at=""; _idle_looked=""; _force=""$/,/^  while true; do$/p' "$SVC" | sed '$d' > "$TMP/idle.sh"
grep -q '_idle_due()' "$TMP/idle.sh" || fail "idle helpers not found in service.sh"
# shellcheck disable=SC1090
. "$TMP/idle.sh"
_pcm_known=1

SECONDS=1000
_idle_track ""                         # playback just stopped
_idle_due && fail "looked before a minute had passed"
SECONDS=1059; _idle_due && fail "looked at 59 s"
SECONDS=1061; _idle_due || fail "no look a minute into the idle stretch"
SECONDS=1200; _idle_track ""; _idle_due && fail "looked twice in one idle stretch"
_idle_track "/proc/asound/card0/pcm0p/sub0/status"   # a stream plays again
SECONDS=2000; _idle_track ""; SECONDS=2061
_idle_due || fail "a new idle stretch did not get its own look"
# Where the kernel does not expose PCM state, idle cannot be told from playing: never look.
_pcm_known=""; _idle_track "x"; SECONDS=3000; _idle_track ""; SECONDS=3100
_idle_due && fail "looked without PCM state (idle and playing look the same there)"

# Wiring: both the screen-off and the screen-on path use it, and a forced pass dumps.
grep -q '_idle_due && _force=1 || continue' "$SVC" || fail "screen-off path never looks"
grep -q '      _idle_due || continue' "$SVC" || fail "screen-on path never looks"
grep -q 'elif \[ -n "\$_force" \]; then' "$SVC" || fail "a forced look does not reach the dump"
[ "$(grep -c '_idle_track "\$_sig' "$SVC")" -ge 2 ] || fail "idle stretch not tracked on both paths"
echo "PASS dsp route idle: one route look a minute into every idle stretch, none without PCM state"
)

t_dsp_route_wake_runtime() (
# Runtime (fix159): the DSP route watcher follows the route on phones whose kernel exposes no
# PCM state, and the screen coming on is noticed in seconds.
#
# Owner's OP15 (AudioReach): music went to Bluetooth while persist.asb.dsp.route still read
# "speaker" - asbdiag at 19:13:57 and the action screen at 19:14:45 both said "playing on
# speaker -> not processed" while STREAM_MUSIC was on bt_a2dp, and the capture's "alsa pcm
# status" section is empty in all 22 audio snapshots of the day, speaker playback included.
# The watcher's only cheap playback signal is that PCM state, so on this phone it never dumped
# the audio service with the screen off, slept through its 60 s nap after the screen came on and
# then waited out a 30 s back-off: about 80 s of unboosted Bluetooth, then +25 dB mid-track.
#
# The REAL watcher loop is cut out of service.sh and run in virtual time (fake sleep advances
# SECONDS), with fake dumpsys / getprop / resetprop, a fake /proc with an audioserver whose
# AudioOut threads count their runs in schedstat, and the REAL runtime/asb_audio_activity.sh.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SVC="${ASB_TEST_SERVICE:-$ROOT/service.sh}"
T="${ASB_TEST_KEEP:-$(mktemp -d)}"; [ -n "${ASB_TEST_KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL dsp route wake: $*" >&2; fail=1; }

body="$T/watch.sh"
awk '/^  _prev_route=""$/ { on = 1 } on && /^\) >\/dev\/null 2>&1 &$/ { exit } on { print }' "$SVC" > "$body"
grep -q 'dsp route changed' "$body" || { echo "FAIL dsp route wake: watcher block not found" >&2; exit 1; }

# ---- 1. the activity detector on its own -------------------------------------------------
. "$ROOT/runtime/asb_audio_activity.sh"
P="$T/p1"; mkdir -p "$P/1/task/1" "$P/77/task/77" "$P/77/task/80" "$P/77/task/81" "$P/77/task/82"
echo init > "$P/1/comm"; echo init > "$P/1/task/1/comm"; echo 5 > "$P/1/task/1/schedstat"
echo audioserver > "$P/77/comm"
echo audioserver > "$P/77/task/77/comm"; echo "1 2 900" > "$P/77/task/77/schedstat"
echo AudioOut_D  > "$P/77/task/80/comm"; echo "1 2 1000" > "$P/77/task/80/schedstat"
echo AudioOut_85 > "$P/77/task/81/comm"; echo "1 2 400" > "$P/77/task/81/schedstat"
echo binder:77_2 > "$P/77/task/82/comm"; echo "1 2 50" > "$P/77/task/82/schedstat"
ASB_AUDIO_PROC="$P"; ASB_AUDIO_ASOUND="$T/no_asound"; export ASB_AUDIO_PROC ASB_AUDIO_ASOUND
asb_audio_sig
[ "$_aa_pid" = 77 ] || f "audioserver not found in /proc (pid=$_aa_pid)"
[ -z "$_aa_mode" ] || f "a mode claimed before any baseline: $_aa_mode"
[ -z "$_aa_sig" ] || f "activity claimed on the first look: $_aa_sig"
echo "1 2 460" > "$P/77/task/81/schedstat"; echo "1 2 9000" > "$P/77/task/77/schedstat"; echo "1 2 999" > "$P/77/task/82/schedstat"
asb_audio_sig
[ "$_aa_mode" = threads ] || f "thread mode not reached on the second look: $_aa_mode"
[ "$_aa_sig" = "AudioOut_85 " ] || f "active output not named (only AudioOut threads count): '$_aa_sig'"
asb_audio_sig
[ -z "$_aa_sig" ] || f "a thread that stopped running still reads as playing: '$_aa_sig'"
mkdir -p "$P/77/task/90"; echo AudioOut_95 > "$P/77/task/90/comm"; echo "1 2 30" > "$P/77/task/90/schedstat"
asb_audio_sig
[ "$_aa_sig" = "AudioOut_95 " ] || f "an output thread that just opened and runs is not seen: '$_aa_sig'"
rm -f "$P/77/task/90/schedstat"
printf 'Name:\tAudioOut_95\nvoluntary_ctxt_switches:\t100\nnonvoluntary_ctxt_switches:\t7\n' > "$P/77/task/90/status"
asb_audio_sig
printf 'Name:\tAudioOut_95\nvoluntary_ctxt_switches:\t140\nnonvoluntary_ctxt_switches:\t9\n' > "$P/77/task/90/status"
asb_audio_sig
[ "$_aa_sig" = "AudioOut_95 " ] || f "context switches not used where schedstat is missing: '$_aa_sig'"
mkdir -p "$P/99/task/99" "$P/99/task/101"; echo audioserver > "$P/99/comm"; echo audioserver > "$P/99/task/99/comm"
echo AudioOut_D > "$P/99/task/101/comm"; echo "1 2 10" > "$P/99/task/101/schedstat"
rm -rf "$P/77"
asb_audio_sig
[ "$_aa_pid" = 99 ] || f "audioserver restart not followed (pid=$_aa_pid)"
[ -z "$_aa_sig" ] && [ -z "$_aa_mode" ] || f "a restarted audioserver compared against the old one: mode=$_aa_mode sig='$_aa_sig'"
mkdir -p "$T/asound/card0/pcm0p/sub0" "$T/asound/card0/pcm1p/sub0"
echo closed > "$T/asound/card0/pcm0p/sub0/status"; printf 'state: RUNNING\nowner_pid   : 1\n' > "$T/asound/card0/pcm1p/sub0/status"
ASB_AUDIO_ASOUND="$T/asound" asb_audio_sig
[ "$_aa_mode" = pcm ] || f "PCM state not preferred where the kernel has it: $_aa_mode"
[ "$_aa_sig" = "$T/asound/card0/pcm1p/sub0/status " ] || f "PCM signature changed format: '$_aa_sig'"
echo "screen=1" > "$T/st"; echo "capacity=50" >> "$T/st"
ASB_AUDIO_STATE="$T/st" asb_audio_screen; [ "$_aa_s" = 1 ] || f "screen state not read from the governor's file"
ASB_AUDIO_STATE="$T/none" asb_audio_screen; [ -z "$_aa_s" ] || f "a missing state file read as a screen state"
unset ASB_AUDIO_PROC ASB_AUDIO_ASOUND

# ---- 2. the real watcher loop in virtual time --------------------------------------------
# $1 = scenario name. Scenario timeline (virtual seconds):
#   t=0..   screen on, nothing playing, route published "speaker"
#   t=300   screen off
#   t=600   Bluetooth music starts (STREAM_MUSIC -> bt_a2dp, AudioOut_85 running)
#   t=873   screen on (between two 5 s slices on purpose)
run() {
  S="$T/run_$1"; rm -rf "$S"; mkdir -p "$S/mod/config" "$S/mod/runtime" "$S/props" "$S/proc/50/task/50" "$S/proc/50/task/51" "$S/proc/50/task/52"
  cp "$ROOT/runtime/asb_audio_activity.sh" "$S/mod/runtime/" 2>/dev/null || true
  printf 'dsp_outputs=bt\ndsp_loudness=25\n' > "$S/mod/config/governor.conf"
  echo 1 > "$S/props/persist.asb.dsp.enable"; echo speaker > "$S/props/persist.asb.dsp.route"
  echo audioserver > "$S/proc/50/comm"; echo audioserver > "$S/proc/50/task/50/comm"
  echo AudioOut_D > "$S/proc/50/task/51/comm"; echo AudioOut_85 > "$S/proc/50/task/52/comm"
  echo "0 0 100" > "$S/proc/50/task/50/schedstat"; echo "0 0 100" > "$S/proc/50/task/51/schedstat"; echo "0 0 100" > "$S/proc/50/task/52/schedstat"
  [ "$1" = nodetect ] && rm -rf "$S/proc/50"
  cat > "$S/run.sh" <<EOF
S="$S"; MODDIR="\$S/mod"; SC="$1"
ASB_AUDIO_PROC="\$S/proc"; ASB_AUDIO_ASOUND="\$S/no_asound"; ASB_AUDIO_STATE="\$S/state"
export ASB_AUDIO_PROC ASB_AUDIO_ASOUND ASB_AUDIO_STATE
SECONDS=0; _runs=100
_scr() { if [ "\$SECONDS" -ge 300 ] && [ "\$SECONDS" -lt 873 ]; then echo 0; else echo 1; fi; }
_play() { [ "\$SECONDS" -ge 600 ]; }
_world() {
  printf 'screen=%s\n' "\$(_scr)" > "\$S/state"
  if _play && [ -d "\$S/proc/50" ]; then _runs=\$((_runs + 120)); echo "0 0 \$_runs" > "\$S/proc/50/task/52/schedstat"; fi
  if [ "\$SC" = desync ] && [ "\$SECONDS" -ge 1000 ] && [ ! -e "\$S/desynced" ]; then
    echo speaker > "\$S/props/persist.asb.dsp.route"; : > "\$S/desynced"
  fi
}
sleep() { SECONDS=\$((SECONDS + \$1)); _world; [ "\$SECONDS" -gt 1300 ] && exit 0; return 0; }
asb_screen_state() { [ "\$(_scr)" = 1 ] && echo true || echo false; }
asb_log() { :; }
getprop() { cat "\$S/props/\$1" 2>/dev/null; }
resetprop() { [ "\$1" = -n ] && shift; printf '%s' "\$2" > "\$S/props/\$1"; [ "\$1" = persist.asb.dsp.route ] && echo "\$SECONDS \$2" >> "\$S/routes"; return 0; }
setprop() { resetprop -n "\$@"; }
pkill() { return 0; }
killall() { return 0; }
dumpsys() {
  echo "\$SECONDS" >> "\$S/dumps"
  [ "\$1" = audio ] || return 0
  printf '%s\n' '- STREAM_VOICE_CALL:' '   Devices: earpiece(1)'
  if _play; then
    printf '%s\n' '- STREAM_MUSIC:' '   Muted: false' '   Devices: bt_a2dp(80)' '- STREAM_ALARM:' '   Devices: speaker(2)'
    printf '%s\n' '  AudioPlaybackConfiguration piid:10279 deviceIds:[1298] type:android.media.AudioTrack u/pid:10483/18501 state:started attr:AudioAttributes: usage=USAGE_MEDIA'
  else
    printf '%s\n' '- STREAM_MUSIC:' '   Muted: false' '   Devices: speaker(2)' '- STREAM_ALARM:' '   Devices: speaker(2)'
  fi
}
_world
EOF
  cat "$body" >> "$S/run.sh"
  sh "$S/run.sh" >/dev/null 2>&1
}
first_bt() { awk '$2 == "bt" && $1 >= '"${2:-0}"' { print $1; exit }' "$T/run_$1/routes" 2>/dev/null; }
dumps_between() { awk -v a="$2" -v b="$3" '$1 >= a && $1 < b { n++ } END { print n + 0 }' "$T/run_$1/dumps" 2>/dev/null; }

run detect
t="$(first_bt detect)"
[ -n "$t" ] || f "Bluetooth route never published (phone without PCM state)"
[ -n "$t" ] && [ "$t" -le 680 ] || f "Bluetooth playback started with the screen off at t=600 was published at t=${t:-never}, want by t=680 (screen still off)"
n="$(dumps_between detect 60 300)"
[ "$n" -le 2 ] || f "$n audio dumps in 4 idle screen-on minutes - nothing plays, the thread signal should hold them off"

run nodetect
t="$(first_bt nodetect)"
[ -n "$t" ] && [ "$t" -le 885 ] || f "screen came on at t=873 with the route stale, published at t=${t:-never}, want by t=885"

run desync
t="$(first_bt desync 1000)"
[ -n "$t" ] && [ "$t" -le 1060 ] || f "route overwritten to speaker at t=1000 while Bluetooth plays was not put back (t=${t:-never})"

[ "$fail" = 0 ] && echo "PASS dsp route wake: Bluetooth route followed with the screen off on a phone without PCM state, screen-on noticed within seconds, an overwritten route republished"
exit "$fail"
)

t_dsp_stereo_width_runtime() (
# Runtime (fix160): DSP stereo width ("Sound Space", dsp_width 0..10).
#
# Mid/side widening in the shared core (src/DSP_AIDL/asb_dsp_core.h), the object both the
# AIDL and the legacy effect run. The REAL header is compiled on the host and driven with
# sines:
#   - level 0 is bit-identical to a core that never heard of width;
#   - a mono or centred signal (L == R) comes out bit-identical at any level - voices and mono
#     recordings are not touched;
#   - the side signal grows by 1 + 0.1 * level above the 180 Hz corner (x2.0 at level 10) and
#     far less at 50 Hz, so the low end stays mono;
#   - only two-channel streams are processed;
#   - the limiter still holds the ceiling with +25 dB and full width, in float and int16;
#   - both effects and the attach daemon read the new property, and the build gate knows it.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL dsp stereo width: $*" >&2; exit 1; }
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP dsp stereo width: no C compiler"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep -q 'asb_core_set_width(&mCore, width, (uint32_t)rate);' "$ROOT/src/DSP_AIDL/asb_effect_aidl.cpp" || fail "AIDL effect does not apply the width"
grep -q 'int width  = asb_dsp_prop("width", 0);' "$ROOT/src/DSP_AIDL/asb_effect_aidl.cpp" || fail "AIDL effect does not read the width"
grep -q 'asb_core_set_width(&c->core, asb_dsp_prop("width", 0), rate);' "$ROOT/src/DSP/asb_dsp.c" || fail "legacy effect does not apply the width"
grep -q '__system_property_get("persist.asb.dsp.width", w);' "$ROOT/src/DSP_AIDL/asb_dsp_attach.cpp" || fail "a width edit does not trigger a push"
grep -q '" stereo_width="' "$ROOT/src/build_ndk_release.sh" || fail "build gate does not know the width marker"
cat > "$T/w.c" <<'X'
#include "asb_dsp_core.h"
#include <stdio.h>
#include <string.h>
#define N 9600
#define R 48000u
static float in[N * 6], o0[N * 6], o1[N * 6];
static void cfg(asb_core_t *c, int ch, int gain, int width) {
    memset(c, 0, sizeof(*c));
    asb_core_configure_ex(c, 1, gain, -30, 0, 60, -2400, ch, R, 1, 0, 300);
    asb_core_set_bass(c, 0, R);
    asb_core_set_voice(c, 0, R);
    if (width >= 0) asb_core_set_width(c, width, R);
    asb_core_reset(c);
}
static void sig(int ch, float f, float al, float ar) {
    for (int i = 0; i < N; i++) {
        float v = sinf(2.0f * 3.14159265f * f * (float)i / (float)R);
        for (int k = 0; k < ch; k++) in[i * ch + k] = (k == 0 ? al : (k == 1 ? ar : al)) * v;
    }
}
static double side_rms(const float *b) {
    double s = 0; for (int i = N / 2; i < N; i++) { double d = 0.5 * (b[i * 2] - b[i * 2 + 1]); s += d * d; } return s;
}
static float peak(const float *b, int n) { float m = 0; for (int i = 0; i < n; i++) if (fabsf(b[i]) > m) m = fabsf(b[i]); return m; }
static double ratio(float f, int level) {
    asb_core_t a, b;
    sig(2, f, 0.05f, -0.05f);
    cfg(&a, 2, 100, 0); asb_core_process_f32(&a, in, o0, N, 0);
    cfg(&b, 2, 100, level); asb_core_process_f32(&b, in, o1, N, 0);
    return sqrt(side_rms(o1) / side_rms(o0));
}
int main(void) {
    asb_core_t a, b; int bad = 0;
    sig(2, 1000.0f, 0.3f, 0.1f);
    cfg(&a, 2, 600, -1); asb_core_process_f32(&a, in, o0, N, 0);
    cfg(&b, 2, 600, 0);  asb_core_process_f32(&b, in, o1, N, 0);
    if (b.width_on || memcmp(o0, o1, sizeof(float) * N * 2)) { puts("FAIL level 0 changes the signal"); bad++; }
    sig(2, 1000.0f, 0.2f, 0.2f);
    cfg(&a, 2, 600, 0);  asb_core_process_f32(&a, in, o0, N, 0);
    cfg(&b, 2, 600, 10); asb_core_process_f32(&b, in, o1, N, 0);
    if (!b.width_on || memcmp(o0, o1, sizeof(float) * N * 2)) { puts("FAIL a centred signal is not bit-identical at level 10"); bad++; }
    double r10 = ratio(2000.0f, 10), r5 = ratio(2000.0f, 5), r1 = ratio(4000.0f, 1), rlo = ratio(50.0f, 10);
    printf("side x%.3f at 2 kHz level 10, x%.3f level 5, x%.3f 4 kHz level 1, x%.3f at 50 Hz level 10\n", r10, r5, r1, rlo);
    if (r10 < 1.90 || r10 > 2.02) { puts("FAIL level 10 is not about x2.0 on the side"); bad++; }
    if (r5 < 1.45 || r5 > 1.51) { puts("FAIL level 5 is not about x1.5"); bad++; }
    if (r1 < 1.08 || r1 > 1.11) { puts("FAIL level 1 is not about x1.1"); bad++; }
    if (rlo > 1.35) { puts("FAIL the low end is widened"); bad++; }
    cfg(&a, 1, 600, 10); if (a.width_on) { puts("FAIL width on a mono stream"); bad++; }
    cfg(&a, 6, 600, 10); if (a.width_on) { puts("FAIL width on a 5.1 stream"); bad++; }
    cfg(&a, 2, 600, 11); if (!a.width_on || a.wside > 1.0001f) { puts("FAIL level not clamped to 10"); bad++; }
    sig(2, 3000.0f, 0.9f, -0.9f);
    cfg(&a, 2, 2500, 10); asb_core_process_f32(&a, in, o1, N, 0);
    if (peak(o1, N * 2) > asb_core_mb_to_lin(-30) + 1e-4f) { printf("FAIL ceiling broken with full width: %.4f\n", peak(o1, N * 2)); bad++; }
    {
        static int16_t si[N * 2], so[N * 2];
        for (int i = 0; i < N; i++) { int16_t v = (int16_t)(12000.0f * sinf(2.0f * 3.14159265f * 1500.0f * (float)i / (float)R)); si[i * 2] = v; si[i * 2 + 1] = v; }
        cfg(&a, 2, 600, 10); asb_core_process_s16(&a, si, so, N, 0);
        for (int i = 0; i < N; i++) if (so[i * 2] != so[i * 2 + 1]) { puts("FAIL int16 centred signal split by width"); bad++; break; }
        for (int i = 0; i < N; i++) { int16_t v = (int16_t)(30000.0f * sinf(2.0f * 3.14159265f * 2500.0f * (float)i / (float)R)); si[i * 2] = v; si[i * 2 + 1] = (int16_t)-v; }
        cfg(&a, 2, 2500, 10); asb_core_process_s16(&a, si, so, N, 0);
        int lim = (int)lrintf(asb_core_mb_to_lin(-30) * 32767.0f) + 1;
        for (int i = 0; i < N * 2; i++) if (so[i] > lim || so[i] < -lim) { printf("FAIL int16 ceiling broken: %d\n", so[i]); bad++; break; }
    }
    return bad ? 1 : 0;
}
X
"$CC" -O2 -std=c11 -Wall -Wextra -I"$ROOT/src/DSP_AIDL" "$T/w.c" -lm -o "$T/w" 2> "$T/cc.log" || { cat "$T/cc.log" >&2; fail "core does not compile"; }
[ -s "$T/cc.log" ] && { cat "$T/cc.log" >&2; fail "core compiles with warnings"; }
out="$("$T/w")" || fail "$out"
echo "PASS dsp stereo width: $out; centred sound and level 0 bit-exact, mono/5.1 untouched, ceiling held"
)

t_dsp_voice_tone_runtime() (
# fix75: DSP voice tone (dsp_voice). The shared core adds +0.5 dB/step at 350 Hz and
# -0.6 dB/step at 3.2 kHz; measured here through the REAL legacy effect (asb_dsp.c) on
# sines below the compressor threshold, so only the EQ moves the level. Also checks the
# wiring config -> apply script -> vendor prop -> both effects -> WebUI -> freshness gate.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL dsp voice tone: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

for f in config/governor.conf config/governor.conf.shipped; do
  grep -qx 'dsp_voice=0' "$ROOT/$f" || fail "$f lacks dsp_voice=0"
done
grep -qx 'dsp_voice|advanced|webui_sensitive' "$ROOT/config/key_ownership.tsv" || fail "ownership registry"
[ "$(grep -c ' dsp_voice ' "$ROOT/common/install.sh")" = 2 ] || fail "installer does not carry dsp_voice over on update"
grep -q '_dspp voice "$_vox"' "$ROOT/runtime/asb_audio_apply.sh" || fail "apply script does not publish the voice prop"
grep -Eq 'bass_db voice( [a-z_]+)*; do' "$ROOT/runtime/asb_audio_apply.sh" || fail "voice prop not mirrored into the vendor namespace"
grep -q 'asb_core_set_voice(&c->core, asb_dsp_prop("voice", 0), rate);' "$ROOT/src/DSP/asb_dsp.c" || fail "legacy effect ignores voice"
grep -q 'asb_core_set_voice(&mCore, voice' "$ROOT/src/DSP_AIDL/asb_effect_aidl.cpp" || fail "AIDL effect ignores voice"
grep -q 'for _lit in " voice="[^;]*; do' "$ROOT/src/build_ndk_release.sh" || fail "build does not warn about a pre-voice AIDL prebuilt"
UI="$ROOT/webroot/index.html"
grep -q "{ key:'dsp_voice', type:'range', def:'0', min:0, max:10" "$UI" || fail "WebUI card missing"
grep -q "dsp_voice:APPLY_LIVE" "$UI" || fail "WebUI apply mode missing"
grep -q "var AUDIO_DSP_KEYS = \['dsp_loudness','dsp_bass','dsp_voice'" "$UI" || fail "WebUI does not push voice live"
grep -q "key:'dsp_voice', on:function(v){ return Number(v) > 0; }," "$UI" || fail "dependency on DSP Loudness not explained"
for l in ar de es fr hy id it pt ru tr uk zh; do
  grep -q '"dsp_voice"' "$ROOT/webroot/i18n/$l.json" || fail "no $l translation"
done

mkdir -p "$T/inc/sys"
cat > "$T/inc/sys/system_properties.h" <<'X'
#pragma once
#include <string.h>
#include <stdlib.h>
#define PROP_VALUE_MAX 92
static const char *g_voice = "0";
static int __system_property_get(const char *k, char *v) {
    if (!strcmp(k, "persist.vendor.asb.dsp.enable")) { strcpy(v, "1"); return 1; }
    if (!strcmp(k, "persist.vendor.asb.dsp.gain_mb")) { strcpy(v, "300"); return 3; }
    if (!strcmp(k, "persist.vendor.asb.dsp.voice")) { strcpy(v, g_voice); return (int)strlen(v); }
    v[0] = 0; return 0;
}
X
cat > "$T/drv.c" <<'X'
#include "asb_dsp.c"
#include <stdio.h>
#define N 48000
static float in[N * 2], out[N * 2];
static double level(float hz, const char *voice) {
    g_voice = voice;
    effect_handle_t h; const effect_uuid_t u = g_asb_descriptor.uuid;
    AELI.create_effect(&u, 0, 0, &h);
    effect_config_t cfg; memset(&cfg, 0, sizeof(cfg));
    cfg.outputCfg.samplingRate = 48000; cfg.outputCfg.channels = 3; cfg.outputCfg.format = AUDIO_FORMAT_PCM_FLOAT;
    int r = 0; uint32_t rs = 4;
    (*h)->command(h, EFFECT_CMD_SET_CONFIG, sizeof(cfg), &cfg, &rs, &r);
    (*h)->command(h, EFFECT_CMD_ENABLE, 0, NULL, &rs, &r);
    for (int i = 0; i < N; i++) in[2*i] = in[2*i+1] = 0.01f * sinf(2.0f * 3.14159265f * hz * (float)i / 48000.0f);
    audio_buffer_t a = { .frameCount = N, .f32 = in }, b = { .frameCount = N, .f32 = out };
    (*h)->process(h, &a, &b);
    double e = 0; for (int i = N; i < 2 * N; i++) e += (double)out[i] * out[i];   /* second half: settled */
    AELI.release_effect(h);
    return 10.0 * log10(e);
}
int main(void) {
    double b0 = level(350, "0"),  b10 = level(350, "10");
    double p0 = level(3200, "0"), p10 = level(3200, "10");
    double f0 = level(60, "0"),   f10 = level(60, "10");
    printf("350Hz %+.2f dB  3.2kHz %+.2f dB  60Hz %+.2f dB\n", b10 - b0, p10 - p0, f10 - f0);
    if (b10 - b0 < 4.0 || b10 - b0 > 5.5) return 1;
    if (p10 - p0 > -5.0 || p10 - p0 < -6.5) return 1;
    if (f10 - f0 > 1.0 || f10 - f0 < -1.0) return 1;   /* bass region left alone */
    return 0;
}
X
"$CC" -std=gnu11 -O1 -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Werror \
  -I"$T/inc" -I"$ROOT/src/DSP" -I"$ROOT/src/DSP_AIDL" "$T/drv.c" -lm -o "$T/drv" || fail "does not compile"
out="$("$T/drv")" || fail "response off target: $out"
echo "PASS DSP voice tone ($out)"
)

t_gms_freeze_list_runtime() (
# Runtime: gms_freeze touches GMS component names only - never words from a comment that
# slipped into a list - and cleans junk rows an older build left in its state file.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL gms freeze list: $*" >&2; exit 1; }
mkdir -p "$T/mod/config" "$T/bin"
printf 'gms_freeze=safe\n' > "$T/mod/config/governor.conf"
cat > "$T/bin/pm" <<'X'
#!/bin/sh
echo "$*" >> "$PM_LOG"
exit 0
X
chmod +x "$T/bin/pm"
printf '%s\n' 'no|enabled' 'needed|enabled' 'com.google.android.gms/.feedback.FeedbackAsyncService|enabled' > "$T/state"
PATH="$T/bin:$PATH" PM_LOG="$T/pm.log" MODDIR="$T/mod" ASB_GMS_STATE="$T/state" \
  sh "$ROOT/runtime/asb_gms_freeze.sh" > "$T/out" </dev/null
grep -q 'safe - 9 component' "$T/out" || { cat "$T/out"; fail "safe level must process exactly 9 components"; }
grep 'disable' "$T/pm.log" | grep -v 'com.google.android.gms/\.' && fail "pm disable called on a non-component"
grep -q '^enable no$\|^enable needed$' "$T/pm.log" && fail "junk rows were re-enabled instead of dropped"
grep -v '^com.google.android.gms/' "$T/state" && fail "junk rows survived in the state file"
[ "$(grep -c . "$T/state")" -eq 9 ] || fail "state must hold the 9 safe components"
echo "PASS gms freeze acts on component names only"
)

t_gms_trim_levels_runtime() (
# Runtime: lowering gms_trim undoes what strict did.
# strict removes GMS from the (persisted) Doze exemption list and denies RUN_ANY_IN_BACKGROUND;
# stock and lite used to leave both in place.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL gms trim levels: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/mod/runtime"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
W="$WLFILE"
case "$3" in
  '') cat "$W" 2>/dev/null ;;
  -*) grep -v ",${3#-}," "$W" > "$W.n"; mv "$W.n" "$W" ;;
  +*) echo "system,${3#+},10147" >> "$W" ;;
esac
S
printf '#!/bin/sh\necho "$*" >> "$OPLOG"\n' > "$T/bin/cmd"
printf '#!/bin/sh\n:\n' > "$T/bin/am"
printf '#!/bin/sh\necho package:com.google.android.gms\n' > "$T/bin/pm"
chmod +x "$T/bin/"*
run() {
  echo "gms_trim=$1" > "$T/mod/config/governor.conf"
  WLFILE="$T/wl" OPLOG="$T/ops" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_GMS_MARK="$T/mark" \
    sh "$ROOT/runtime/asb_gms_trim.sh" >/dev/null 2>&1
}
echo "system,com.google.android.gms,10147" > "$T/wl"
run strict
grep -q 'com.google.android.gms' "$T/wl" && f "strict did not remove GMS from the exemption list"
[ -f "$T/mark" ] || f "strict did not mark the removal"
: > "$T/ops"; run lite
grep -q ',com.google.android.gms,' "$T/wl" || f "lite left GMS outside the exemption list"
grep -q 'RUN_ANY_IN_BACKGROUND allow' "$T/ops" || f "lite kept strict's RUN_ANY_IN_BACKGROUND deny"
run strict; run stock
grep -q ',com.google.android.gms,' "$T/wl" || f "stock left GMS outside the exemption list"
[ "$(grep -c gms "$T/wl")" = 1 ] || f "GMS added twice"
# Old install: no marker, GMS missing at stock -> put back.
: > "$T/wl"; rm -f "$T/mark"; run stock
grep -q ',com.google.android.gms,' "$T/wl" || f "pre-marker install not healed at stock"
[ "$fail" = 0 ] && echo "PASS gms trim levels"
exit "$fail"
)

t_gnss_foreground_contract() (
# Contract: gnss_trim restricts BOTH location ops in self-healing FOREGROUND mode,
# records per-op state, and every restore path (off-switch, hourly loop, uninstall)
# parses both the legacy pkg|mode and the current pkg|op|mode record shapes.
#
# Why: two field-visible defects.
#   1. Only COARSE_LOCATION was set with mode "ignore". GNSS drain is a FINE fix, and
#      "ignore" is sticky - it survives the process being promoted. The restore loop ran
#      only from the screen-off hourly cycle, so a navigation app opened after an
#      overnight trim had no location until the next screen-off pass (user report: fix
#      lost mid-drive, recovered at reboot).
#   2. uninstall replayed every record as COARSE_LOCATION regardless of the op.
# MODE_FOREGROUND denies cached processes and allows promoted ones automatically -
# Android flips it with the process state, so no restore timing can strand an app.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GNSS="$ROOT/runtime/asb_gnss_trim.sh"
UNINSTALL="$ROOT/uninstall.sh"
fail() { echo "FAIL gnss foreground contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in ${1#$ROOT/}"; }
absent() { grep -Fq "$2" "$1" && fail "forbidden [$2] in ${1#$ROOT/}" || true; }

[ -f "$GNSS" ] || fail "asb_gnss_trim.sh not found"

# The trim loop covers both ops and uses the self-healing mode.
need "$GNSS" 'for _lop in COARSE_LOCATION FINE_LOCATION; do'
need "$GNSS" 'appops set "$_p" "$_lop" foreground'
absent "$GNSS" 'appops set "$_p" COARSE_LOCATION ignore'

# An app already on ignore/deny/foreground asked for it itself: never rewritten.
need "$GNSS" 'case "$_prev" in ignore|deny|foreground) continue ;; esac'

# State records are per-op: pkg|op|mode.
need "$GNSS" 'printf '"'"'%s|%s|%s\n'"'"' "$_p" "$_lop" "$_prev"'

# Both restore loops in the trim script parse the pipe-bearing record shape and
# sanitise the op name.
[ "$(grep -cF '*"|"*) _rop=' "$GNSS")" -ge 2 ] || fail "gnss restore loops do not parse pkg|op|mode"
[ "$(grep -cF 'COARSE_LOCATION|FINE_LOCATION' "$GNSS")" -ge 2 ] || fail "op sanitiser missing in gnss restores"

# Navigator/safety exclusions must survive any refactor of this file.
need "$GNSS" '*navi*|*waze*|*yandex*'
need "$GNSS" '*emergency*|*sos*|*safety*'

# uninstall.sh restores per-op too, and the record guard admits the pipe character.
need "$UNINSTALL" 'case "$_rop" in COARSE_LOCATION|FINE_LOCATION) : ;; *) _rop="COARSE_LOCATION" ;; esac'
need "$UNINSTALL" 'appops set "$_rp" "$_rop" "$_rm"'
[ "$(grep -cF 'appops set "$_rp" "$_rop" "$_rm"' "$UNINSTALL")" -ge 2 ] \
  || fail "uninstall has two gnss restore blocks; both must be op-aware"

echo "PASS gnss foreground contract"
)

t_gnss_trim_runtime() (
# Runtime: GNSS trim reads current location-dump formats and real process state.
#
# Android 12+ names location callers as "10234/com.foo[tag]", not "package=com.foo", and
# `dumpsys activity processes` prints "cached=false" on every record, so the old parse
# found nothing and the old state check said "cached" for apps in any state. Stubs replay
# both formats plus an event log that must be ignored.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL gnss runtime: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/mod/runtime" "$T/d"
cp "$ROOT/runtime/asb_procstate.sh" "$T/mod/runtime/"
echo "gnss_trim=1" > "$T/mod/config/governor.conf"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1" in
  deviceidle) echo false ;;
  location) cat <<'L'
  gps provider:
    registrations:
      10700/com.example.weather[loc] (fine) Request[@+10m0s HIGH_ACCURACY]
      10701/com.example.walk Request[@+1s HIGH_ACCURACY]
      10702/com.example.navi.app Request[@+1s HIGH_ACCURACY]
      10703/com.example.foobar Request[@+1m]
    package=com.example.legacy
  Event Log:
    10:00:01 +registration 10704/com.example.gone Request[...]
L
  ;;
  activity) cat <<'A'
  #40: fg     TOP  LCMNFU  ---- 1111:com.example.walk/u0a701
  #20: cch+5  CEM  ----    ---- 2222:com.example.weather/u0a700
  #19: cch+7  CEM  ----    ---- 3333:com.example.legacy/u0a705
  #18: cch+9  CEM  ----    ---- 4444:com.example.gone/u0a704
  #17: cch+9  CEM  ----    ---- 5555:com.example.navi.app/u0a702
A
  ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
printf 'package:com.example.weather\npackage:com.example.walk\npackage:com.example.navi.app\npackage:com.example.foo\npackage:com.example.legacy\npackage:com.example.gone\n'
S
cat > "$T/bin/appops" <<'S'
#!/bin/sh
case "$1" in
  get) echo "$3: allow" ;;
  set) echo "$*" >> "$OPLOG" ;;
esac
S
chmod +x "$T/bin/"*
OPLOG="$T/ops" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_GNSS_DIR="$T/d" \
  sh "$ROOT/runtime/asb_gnss_trim.sh" >/dev/null 2>&1
touch "$T/ops"
grep -q 'set com.example.weather FINE_LOCATION foreground' "$T/ops" || f "cached caller in uid/pkg form not trimmed"
grep -q 'set com.example.legacy COARSE_LOCATION foreground' "$T/ops" || f "legacy package= form not read"
grep -q 'com.example.walk' "$T/ops" && f "foreground app trimmed"
grep -q 'com.example.navi' "$T/ops" && f "navigation app trimmed"
grep -q 'com.example.gone' "$T/ops" && f "event-log entry treated as a live request"
grep -q 'com.example.foobar' "$T/ops" && f "substring third-party match"
[ "$fail" = 0 ] && echo "PASS gnss trim runtime"
exit "$fail"
)

t_keep_list_guards_runtime() (
# Runtime (fix154): an app ticked in the Doze picker is kept awake by every ASB tweak.
#
# The picker says "ticked apps stay exempt from Doze". Two other battery tweaks could still
# hold such an app back: the wakelock watcher (restricted standby bucket) when the Doze
# trim is off, and background trimming (the "rare" bucket and memory trims for heavy apps
# such as Facebook or Instagram). The REAL functions run on mocked am/dumpsys.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL keep list guards: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/d"
cat > "$T/bin/am" <<'S'
#!/bin/sh
case "$1" in
  get-standby-bucket) echo 40 ;;
  *) echo "$*" >> "$AM_LOG" ;;
esac
S
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1:${2:-}" in
  batterystats:*) printf '  All partial wake locks:\n  Wake lock u0a750 Sync: 55m 0s 1ms (9 times) realtime\n' ;;
  activity:*) echo '  #18: cch+ 5 CEM  ----    ---- 5680:com.facebook.katana/u0a750' ;;
  deviceidle:whitelist) echo 'system,com.google.android.gms,10146' ;;
  deviceidle:*) echo false ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
echo 'package:com.facebook.katana uid:10750'
S
printf '#!/bin/sh\necho "No operations."\n' > "$T/bin/appops"
printf '#!/bin/sh\necho 4242\n' > "$T/bin/pidof"
chmod +x "$T/bin/"*
echo com.facebook.katana > "$T/d/doze_whitelist_keep"
echo "wakelock_action=1" > "$T/mod/config/governor.conf"
printf 'awake_pct_screenoff=40\nawake_window_min=90\n' > "$T/state"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$ROOT/runtime/asb_wakelock_watch.sh" > "$T/out" 2>&1
grep -q 'com.facebook.katana restricted' "$T/am.log" 2>/dev/null && f "the wakelock watcher restricted an app ticked to stay awake"
rm -f "$T/d/doze_whitelist_keep"; : > "$T/am.log"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$ROOT/runtime/asb_wakelock_watch.sh" > "$T/out" 2>&1
grep -q 'com.facebook.katana restricted' "$T/am.log" || f "without the tick the holder is not restricted - the test no longer tells the two apart"
S="$ROOT/service.sh"
{ sed -n '/^asb_bg_bucket_set() {/,/^}/p' "$S"; sed -n '/^asb_bg_bucket_demote_idle() {/,/^}/p' "$S"; sed -n '/^asb_bg_trim_pkg() {/,/^}/p' "$S"; } > "$T/bg.sh"
grep -q 'ASB_DOZE_KEEP' "$T/bg.sh" || f "background trim functions not found"
echo com.facebook.katana > "$T/keep"; : > "$T/am.log"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" ASB_DOZE_KEEP="$T/keep" ASB_BG_BUCKETS_ORIG="$T/orig" sh -c '
  ASB_BG_BUCKETS_ORIG="$ASB_BG_BUCKETS_ORIG"; asb_bg_trim_is_top() { return 1; }; . "$1"
  asb_bg_bucket_demote_idle com.facebook.katana rare
  asb_bg_bucket_demote_idle com.instagram.android rare
  asb_bg_trim_pkg com.facebook.katana 40
  asb_bg_trim_pkg com.instagram.android 40' x "$T/bg.sh"
grep -q 'set-standby-bucket com.facebook.katana' "$T/am.log" && f "background trim demoted a ticked app"
grep -q 'send-trim-memory.*4242' "$T/am.log" || f "background trim stopped trimming other apps"
grep -q 'set-standby-bucket com.instagram.android rare' "$T/am.log" || f "background trim stopped demoting other apps"
[ "$(grep -c 'send-trim-memory' "$T/am.log")" = 1 ] || f "a ticked app got a memory trim: $(cat "$T/am.log")"
[ "$fail" = 0 ] && echo "PASS keep list guards: ticked apps are never restricted by the wakelock watcher nor trimmed in the background"
exit "$fail"
)

t_lpm_gate_contract() (
# Modem-wakeup-gate observability contract: the night gate must gate exactly the radio
# wake sources a fixture exposes, record+restore them all, and ALWAYS leave a result
# file behind - including the "ran but matched zero nodes" case, which on a CPH2745 is
# the difference between "tweak is working, kernel hides the nodes" and "tweak never ran".
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_lpm.sh"
DIAG="$ROOT/system/bin/asbdiag"
fail() { echo "FAIL lpm gate contract: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail 'runtime/asb_lpm.sh missing'
sh -n "$SRC"

# --- source pins ---
grep -qF 'ASB_LPM_SYSCLASS:-/sys/class' "$SRC" || fail 'sysfs root not injectable for fixtures'
grep -qF '/data/adb/asb/lpm_gate_result' "$SRC" || fail 'gate result file missing'
grep -qF '_g_ws=$((_g_ws + 1))' "$SRC" || fail 'wakeup-class counter missing'
grep -qF '_g_if=$((_g_if + 1))' "$SRC" || fail 'interface counter missing'
grep -qF '"$_SYSCLASS"/wakeup/wakeup*' "$SRC" || fail 'wakeup glob not using the injected root'
grep -qF '"$_SYSCLASS"/net/rmnet*' "$SRC" || fail 'rmnet glob not using the injected root'
grep -qF '"$_SYSCLASS"/net/wlan*' "$SRC" || fail 'wlan glob not using the injected root'
# The restore path must honour the same injected root, or fixtures test a different file.
grep -qF '"$_SYSCLASS/net/$_n/device/power/wakeup"' "$SRC" || fail 'restore path not using the injected root'

# --- diag pins: the result must be visible where a user looks ---
grep -qF 'lpm_gate_result' "$DIAG" || fail 'asbdiag never reads the gate result'
grep -qF 'last modem wakeup gate:' "$DIAG" || fail 'asbdiag gate NOTE missing'
grep -qF 'ran and found nothing to gate' "$DIAG" || fail 'asbdiag zero-match NOTE missing'
cmp -s "$DIAG" "$ROOT/tools/asb_diag.sh" || fail 'asbdiag and tools/asb_diag.sh diverged'

# --- executable fixture: the REAL gate/restore functions against a synthetic sysfs ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract the variable block plus both functions (two top-level closing braces).
awk '/^_ASB_WAKEUP_STATE=\/data\/adb\/asb\/lpm_wakeup_prev$/{f=1} f{print} f&&/^}$/{c++; if(c==2) exit}' "$SRC" \
  | sed "s|/data/adb/asb|$TMP/asb|g" > "$TMP/lpm.sh"
[ -s "$TMP/lpm.sh" ] || fail 'function block not found'
grep -q '_lpm_wakeup_gate()' "$TMP/lpm.sh" || fail 'gate function not extracted'
grep -q '_lpm_wakeup_restore()' "$TMP/lpm.sh" || fail 'restore function not extracted'

SYS="$TMP/sys/class"
mkdir -p "$SYS/wakeup/wakeup0/device/power" "$SYS/wakeup/wakeup1/device/power" \
         "$SYS/net/rmnet_data3/device/power" "$SYS/net/wlan0/device/power" \
         "$SYS/net/lo/device/power" "$TMP/asb"
printf 'IPA_CLIENT_APPS_WAN_LOW_LAT_CONS\n' > "$SYS/wakeup/wakeup0/name"
printf 'enabled\n' > "$SYS/wakeup/wakeup0/device/power/wakeup"
printf 'pm8xxx_rtc_alarm\n' > "$SYS/wakeup/wakeup1/name"
printf 'enabled\n' > "$SYS/wakeup/wakeup1/device/power/wakeup"
printf 'enabled\n' > "$SYS/net/rmnet_data3/device/power/wakeup"
printf 'enabled\n' > "$SYS/net/wlan0/device/power/wakeup"
printf 'enabled\n' > "$SYS/net/lo/device/power/wakeup"

export ASB_LPM_SYSCLASS="$SYS"
. "$TMP/lpm.sh"

# Gate: only the radio sources flip, everything is recorded, the result file appears.
_lpm_wakeup_gate disabled
[ "$(cat "$SYS/wakeup/wakeup0/device/power/wakeup")" = 'disabled' ] || fail 'IPA wakeup source not gated'
[ "$(cat "$SYS/wakeup/wakeup1/device/power/wakeup")" = 'enabled' ] || fail 'non-radio wakeup source was touched'
[ "$(cat "$SYS/net/rmnet_data3/device/power/wakeup")" = 'disabled' ] || fail 'rmnet interface not gated'
[ "$(cat "$SYS/net/wlan0/device/power/wakeup")" = 'disabled' ] || fail 'wlan interface not gated'
[ "$(cat "$SYS/net/lo/device/power/wakeup")" = 'enabled' ] || fail 'lo was touched'

ST="$TMP/asb/lpm_wakeup_prev"
[ -f "$ST" ] || fail 'wakeup state file not written'
[ "$(wc -l < "$ST" | tr -d ' ')" = '3' ] || fail 'state file must hold all 3 gated nodes'
grep -q '^rmnet_data3=enabled$' "$ST" || fail 'rmnet baseline not recorded'
grep -q '^wlan0=enabled$' "$ST" || fail 'wlan baseline not recorded'
grep -q '^/.*wakeup0.*/power/wakeup=enabled$' "$ST" || fail 'IPA device baseline not recorded as a path'

GR="$TMP/asb/lpm_gate_result"
[ -f "$GR" ] || fail 'gate result file not written'
grep -q 'action=disabled' "$GR" || fail 'result action wrong'
grep -q 'wakeup_nodes=1' "$GR" || fail 'result must count 1 wakeup-class node'
grep -q 'net_ifaces=2' "$GR" || fail 'result must count 2 interfaces'

# A second pass must not overwrite the real baselines with self-written values.
_lpm_wakeup_gate disabled
grep -q '^rmnet_data3=enabled$' "$ST" || fail 'second pass clobbered the rmnet baseline'
[ "$(wc -l < "$ST" | tr -d ' ')" = '3' ] || fail 'second pass duplicated state entries'

# Restore: everything back, state file gone.
_lpm_wakeup_restore
[ "$(cat "$SYS/wakeup/wakeup0/device/power/wakeup")" = 'enabled' ] || fail 'IPA wakeup source not restored'
[ "$(cat "$SYS/net/rmnet_data3/device/power/wakeup")" = 'enabled' ] || fail 'rmnet not restored'
[ "$(cat "$SYS/net/wlan0/device/power/wakeup")" = 'enabled' ] || fail 'wlan not restored'
[ ! -f "$ST" ] || fail 'state file not removed after restore'

# The CPH2745 case: a kernel that exposes NOTHING gateable. The gate must still leave a
# result file saying so - this is the whole point of the change.
SYS2="$TMP/sys2/class"
mkdir -p "$SYS2/net" "$SYS2/wakeup"
ASB_LPM_SYSCLASS="$SYS2"
export ASB_LPM_SYSCLASS
. "$TMP/lpm.sh"
_lpm_wakeup_gate disabled
[ -f "$GR" ] || fail 'zero-match pass left no result file'
grep -q 'wakeup_nodes=0' "$GR" || fail 'zero-match pass must report wakeup_nodes=0'
grep -q 'net_ifaces=0' "$GR" || fail 'zero-match pass must report net_ifaces=0'
[ ! -f "$ST" ] || fail 'zero-match pass must not invent a state file'

echo 'lpm gate contract: OK'
)

t_lte_bulk_runtime() (
# Runtime (fix131): a download is not light traffic. Field OP15 (25429): with "5G only when
# needed" the phone sat on LTE for 20-90 minutes at a time with the screen on, through a
# 17-minute download at 2-7 Mbit/s - the give-back wanted one window over 12 Mbit/s, which an
# LTE cell near its own limit never shows - and the screen-off mode switched to LTE in the
# middle of a 5-9 Mbit/s download. Checked here with the REAL script:
#   light mode: drop only under 2 Mbit/s; two windows in a row at 3 Mbit/s give 5G back;
#               one busy window alone does not; the LTE-held tick is 10 s;
#   screen off: a transfer window keeps 5G; a stream still switches; a transfer starting
#               on LTE gives 5G back and holds it; a light record kept at screen-off is
#               watched the same way.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
fail=0; f() { echo "FAIL lte bulk: $*" >&2; fail=1; }
cleanup() { for p in "$T/st/lte_screenoff.pid" "$T/st/lte_light.pid"; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/st" "$T/mod/config" "$T/net/rmnet_data2/statistics"
cat > "$T/bin/cmd" <<'S'
#!/bin/sh
case "$2" in
  get-allowed-network-types-for-users) cat "$MASK" ;;
  set-allowed-network-types-for-users) shift 2; [ "$1" = -s ] && shift 2; echo "$1" > "$MASK" ;;
esac
S
printf '#!/bin/sh\necho 1\n' > "$T/bin/settings"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
echo "id=1 simSlotIndex=0"
echo "mCallState=0"
cat "$WAKEF" 2>/dev/null
S
cat > "$T/bin/ip" <<'S'
#!/bin/sh
echo "1.1.1.1 via 10.0.0.1 dev rmnet_data2 src 10.0.0.2 uid 0"
S
printf '#!/bin/sh\necho 1\n' > "$T/bin/getprop"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st" \
       ASB_STATE_FILE="$T/state" WAKEF="$T/wake" ASB_NET_SYS="$T/net" ASB_LTE_SETTLE_S=0
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001; NR_OFF=1011111110000000001; NR_ON_DEC=916481
SAVE="$T/st/lte_screenoff.saved"
mask() { cat "$MASK"; }
cfg() { printf 'net_screen_off_lte=%s\nnet_lte_light=%s\n' "$1" "$2" > "$T/mod/config/governor.conf"; }
rx() { echo "$1" > "$T/net/rmnet_data2/statistics/rx_bytes"; echo 0 > "$T/net/rmnet_data2/statistics/tx_bytes"; }
sed '/^case "\$1" in$/,$d' "$L" > "$T/hdr.sh"
ticks() { sh -c '. "$1/hdr.sh"; shift; _lowN=0; _busyN=0; for k in "$@"; do _light_tick "$k"; done' _ "$T" "$@"; }
fresh() { sh "$L" restore >/dev/null 2>&1; rm -f "$SAVE" "$T/st/lte_light.hold" "$T/st/lte_screenoff.log"; echo "$NR_ON" > "$MASK"; }

# ---- light mode (screen on) ------------------------------------------------------------
cfg 0 1; printf 'screen=1\nsmart_app_hint=2\n' > "$T/state"; echo "mWakefulness=Awake" > "$WAKEF"
export ASB_LTE_LIGHT_LOW_TICKS=3
fresh; ticks 2500 2500 2500
[ "$(mask)" = "$NR_ON" ] || f "dropped 5G at 2.5 Mbit/s (the drop mark is 2 Mbit/s now)"
ticks 1500 1500 1500
[ "$(mask)" = "$NR_OFF" ] || f "three windows under 2 Mbit/s did not drop to LTE"
ticks 3500 800 3500 900
[ "$(mask)" = "$NR_OFF" ] || f "single busy windows (not in a row) gave 5G back"
ticks 3500 3500
[ "$(mask)" = "$NR_ON" ] || f "two busy windows in a row (a download held on LTE) did not give 5G back"
grep -q 'light: 3500 kbit/s sustained over 2 windows - 5G back' "$T/st/lte_screenoff.log" || f "sustained give-back not logged"
[ -s "$T/st/lte_light.hold" ] || f "no hold after the sustained give-back"
ltk="$(sh -c '. "$1/hdr.sh"; echo "$LIGHT_TICK_LTE_S"' _ "$T")"
[ "$ltk" = 10 ] || f "LTE-held tick is $ltk s, want 10"
ltk="$(ASB_LTE_LIGHT_TICK_S=1 sh -c '. "$1/hdr.sh"; echo "$LIGHT_TICK_LTE_S"' _ "$T")"
[ "$ltk" = 1 ] || f "LTE-held tick longer than the normal tick ($ltk)"

# ---- screen off ------------------------------------------------------------------------
# 1 s windows: stream mark 16 KiB/s (~128 kbit/s), transfer mark 3000 kbit/s (~375 KiB/s).
export ASB_LTE_DELAY_S=1 ASB_LTE_OFF_MIN_KIB=16 ASB_LTE_OFF_BULK_HOLD_S=2
cfg 1 0; echo screen=0 > "$T/state"; echo "mWakefulness=Asleep" > "$WAKEF"
fresh; b=1000000; rx $b
sh "$L" arm
# A transfer: ~8 Mbit/s for three windows - 5G stays.
i=0; while [ "$i" -lt 16 ] && ! grep -q 'is a transfer' "$T/st/lte_screenoff.log" 2>/dev/null; do
  b=$((b + 500000)); rx $b; sleep 0.5; i=$((i + 1)); done
for _ in 1 2 3 4; do b=$((b + 500000)); rx $b; sleep 0.5; done
[ -f "$SAVE" ] && f "switched to LTE in the middle of a transfer"
grep -q 'is a transfer - 5G kept' "$T/st/lte_screenoff.log" || f "kept-for-transfer not logged"
[ "$(grep -c 'is a transfer' "$T/st/lte_screenoff.log")" = 1 ] || f "transfer note logged more than once per screen-off"
# The transfer ends, a stream goes on (~100 KiB/s): LTE.
i=0; while [ "$i" -lt 12 ] && [ ! -f "$SAVE" ]; do b=$((b + 50000)); rx $b; sleep 0.5; i=$((i + 1)); done
[ -f "$SAVE" ] || f "a stream after the transfer did not switch to LTE"
[ "$(mask)" = "$NR_OFF" ] || f "mask not LTE for the stream"
# A transfer starts on LTE: 5G back, then held.
i=0; while [ "$i" -lt 12 ] && [ -f "$SAVE" ]; do b=$((b + 600000)); rx $b; sleep 0.5; i=$((i + 1)); done
[ -f "$SAVE" ] && f "a transfer on LTE did not give 5G back"
[ "$(mask)" = "$NR_ON" ] || f "mask not 5G after the transfer give-back"
grep -q 'bulk: .* kbit/s with the screen off - 5G back for at least 2s' "$T/st/lte_screenoff.log" || f "transfer give-back not logged"
# Inside the hold a stream does not switch back at once...
b=$((b + 50000)); rx $b; sleep 0.6
[ -f "$SAVE" ] && f "re-switched to LTE inside the hold"
# ...after it, it does.
i=0; while [ "$i" -lt 14 ] && [ ! -f "$SAVE" ]; do b=$((b + 50000)); rx $b; sleep 0.5; i=$((i + 1)); done
[ -f "$SAVE" ] || f "no LTE after the hold for a stream"
sh "$L" screen_on
[ -f "$T/st/lte_screenoff.pid" ] && f "screen_on left the screen-off watcher running"
[ "$(mask)" = "$NR_ON" ] || f "screen_on did not give a screen-off record back"

# A light record kept at screen-off (both modes on) is watched for transfers too.
cfg 1 1; fresh
printf '0|%s|light\n' "$NR_ON_DEC" > "$SAVE"; echo "$NR_OFF" > "$MASK"
b=5000000; rx $b
sh "$L" arm
[ -s "$T/st/lte_screenoff.pid" ] || f "no watcher over a light record kept at screen-off"
i=0; while [ "$i" -lt 12 ] && [ -f "$SAVE" ]; do b=$((b + 600000)); rx $b; sleep 0.5; i=$((i + 1)); done
[ -f "$SAVE" ] && f "a transfer over a kept light record did not give 5G back"
sh "$L" restore >/dev/null 2>&1

[ "$fail" = 0 ] && echo "PASS lte transfers keep 5G (light mode and screen off)"
exit "$fail"
)

t_lte_light_flap_runtime() (
# Runtime (fix154): "5G only when needed" stops flapping while the phone is in active use.
#
# Two field days on an OP15 (fix150, fix153): after every 10-minute hold the watcher went
# back to LTE as soon as three quiet minutes had passed, and while feeds were being scrolled
# 5G came back 40 s, 50 s, 121 s, 162 s, 253 s, 304 s, 334 s later - a network-type switch
# each way, every 12-15 minutes, for an LTE stint that saved nothing. Now a give-back that
# ends an LTE stint shorter than 5 minutes doubles the next hold (600 -> 1200 -> 2400 s,
# no further); a stint that lasted brings the hold back to 600 s. The REAL _light_tick runs
# on a mocked `cmd phone`.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL lte light flap: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
cat > "$T/bin/cmd" <<'S'
#!/bin/sh
case "$2" in
  get-allowed-network-types-for-users) cat "$MASK" ;;
  set-allowed-network-types-for-users) shift 2; [ "$1" = -s ] && shift 2; echo "$1" > "$MASK" ;;
esac
S
printf '#!/bin/sh\necho 1\n' > "$T/bin/settings"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
echo "id=1 simSlotIndex=0"
echo "mCallState=0"
echo "mWakefulness=Awake"
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st" \
       ASB_STATE_FILE="$T/state" ASB_LTE_LIGHT_LOW_TICKS=3
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001
SAVE="$T/st/lte_screenoff.saved"
printf 'net_screen_off_lte=1\nnet_lte_light=1\n' > "$T/mod/config/governor.conf"
printf 'screen=1\nsmart_app_hint=2\n' > "$T/state"
echo "$NR_ON" > "$MASK"
sed '/^case "\$1" in$/,$d' "$L" > "$T/hdr.sh"
ticks() { sh -c '. "$1/hdr.sh"; shift; _lowN=0; for k in "$@"; do _light_tick "$k"; done' _ "$T" "$@"; }
hold_left() { echo $(( $(cat "$T/st/lte_light.hold") - $(date +%s) )); }
stint() {   # seconds the LTE stint lasted before the heavy window
  rm -f "$T/st/lte_light.hold"
  ticks 100 100 100
  [ -f "$SAVE" ] || { f "light traffic did not choose LTE"; return; }
  echo $(( $(date +%s) - $1 )) > "$T/st/lte_screenoff.since"
  ticks 20000
  [ -f "$SAVE" ] && f "a heavy window did not give 5G back"
}
in_range() { [ "$1" -ge $(( $2 - 3 )) ] && [ "$1" -le "$2" ]; }
stint 40
in_range "$(hold_left)" 1200 || f "a 40 s stint did not double the hold: $(hold_left)"
grep -q '5G back for at least 1200s (LTE lasted 4[0-9]s)$' "$T/st/lte_screenoff.log" || f "log does not say why: $(tail -n 2 "$T/st/lte_screenoff.log")"
stint 100
in_range "$(hold_left)" 2400 || f "a second short stint did not double again: $(hold_left)"
stint 60
in_range "$(hold_left)" 2400 || f "the hold grew past its ceiling: $(hold_left)"
stint 900
in_range "$(hold_left)" 600 || f "a stint that lasted did not bring the hold back: $(hold_left)"
ticks 100 100 100
[ -f "$SAVE" ] && f "LTE chosen inside the hold"
[ "$fail" = 0 ] && echo "PASS lte light flap: a short LTE stint doubles the 5G hold up to 40 min, a long one resets it"
exit "$fail"
)

t_lte_light_runtime() (
# Runtime (fix114): "5G only when needed" with the screen on. Light mobile traffic drops the
# NR leg after LIGHT_LOW_TICKS windows; a heavy window gives it back and holds it; Wi-Fi,
# a game and a call leave 5G alone; screen-on keeps a light record but gives back a
# screen-off one; the toggle off or screen-off without the screen-off mode give it back.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
fail=0; f() { echo "FAIL lte light: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config" "$T/net/rmnet_data2/statistics" "$T/net/rmnet_data3/statistics"
cat > "$T/bin/cmd" <<'S'
#!/bin/sh
case "$2" in
  get-allowed-network-types-for-users) cat "$MASK" ;;
  set-allowed-network-types-for-users) shift 2; [ "$1" = -s ] && shift 2; echo "$1" > "$MASK" ;;
esac
S
printf '#!/bin/sh\necho 1\n' > "$T/bin/settings"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
echo "id=1 simSlotIndex=0"
cat "$CALLF" 2>/dev/null
echo "mWakefulness=Awake"
S
cat > "$T/bin/ip" <<'S'
#!/bin/sh
case "$*" in
  "route show table all") cat "$TABLESF" 2>/dev/null ;;
  *) echo "1.1.1.1 via 10.0.0.1 dev $(cat "$ROUTEF") src 10.0.0.2 uid 0" ;;
esac
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st" \
       ASB_STATE_FILE="$T/state" CALLF="$T/call" ROUTEF="$T/route" ASB_NET_SYS="$T/net" TABLESF="$T/tables" \
       ASB_LTE_LIGHT_LOW_TICKS=3
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001; NR_OFF=1011111110000000001   # binary, as cmd prints it; bit 19 (524288) is NR
NR_ON_DEC=916481                                          # the record keeps it in decimal
SAVE="$T/st/lte_screenoff.saved"
cfg() { printf 'net_screen_off_lte=%s\nnet_lte_light=%s\n' "$1" "$2" > "$T/mod/config/governor.conf"; }
fresh() { rm -f "$SAVE" "$T/st/lte_light.hold"; echo "$NR_ON" > "$MASK"; }
# Everything above the dispatcher, so _light_tick can be driven without the sleeping loop.
sed '/^case "\$1" in$/,$d' "$L" > "$T/hdr.sh"
ticks() { sh -c '. "$1/hdr.sh"; shift; _lowN=0; for k in "$@"; do _light_tick "$k"; done' _ "$T" "$@"; }
mask() { cat "$MASK"; }
cfg 1 1; echo rmnet_data2 > "$ROUTEF"; echo mCallState=0 > "$T/call"
printf 'screen=1\nsmart_app_hint=2\n' > "$T/state"
fresh

ticks 800 900
[ "$(mask)" = "$NR_ON" ] || f "dropped 5G before LOW_TICKS light windows"
ticks 800 900 700
[ "$(mask)" = "$NR_OFF" ] || f "three light windows did not drop the NR leg (mask $(mask))"
[ "$(cut -d'|' -f3 "$SAVE" 2>/dev/null)" = light ] || f "record does not say light: $(cat "$SAVE" 2>/dev/null)"
ticks 800 5000 800 700
[ "$(mask)" = "$NR_OFF" ] || f "a medium window (between the marks) gave 5G back"
sh "$L" screen_on; sh "$L" arm >/dev/null 2>&1
[ "$(mask)" = "$NR_OFF" ] || f "screen_on / screen-off with both modes on gave a light record back"

# Heavy window: 5G back at once and held.
ticks 20000
[ "$(mask)" = "$NR_ON" ] || f "a heavy window did not give 5G back"
[ -f "$SAVE" ] && f "record kept after the heavy-window restore"
[ -s "$T/st/lte_light.hold" ] || f "no hold after a heavy window"
ticks 100 100 100
[ "$(mask)" = "$NR_ON" ] || f "re-applied inside the hold"
rm -f "$T/st/lte_light.hold"

# A game in front, a call: no apply.
printf 'screen=1\nsmart_app_hint=4\n' > "$T/state"; ticks 100 100 100
[ "$(mask)" = "$NR_ON" ] || f "applied with a game in front"
printf 'screen=1\nsmart_app_hint=2\n' > "$T/state"
echo "mCallState=2" > "$T/call"; ticks 100 100 100
[ "$(mask)" = "$NR_ON" ] || f "applied during a call"
echo "mCallState=0" > "$T/call"

# A screen-off record is not the watcher's: never re-tagged, given back on screen-on.
printf '0|%s|off\n' "$NR_ON_DEC" > "$SAVE"; echo "$NR_OFF" > "$MASK"
ticks 30000 30000
[ "$(mask)" = "$NR_OFF" ] || f "the watcher touched a screen-off record"
sh "$L" screen_on; sh "$L" arm >/dev/null 2>&1; sh "$L" restore >/dev/null 2>&1
[ "$(mask)" = "$NR_ON" ] || f "screen_on did not give back a screen-off record"

# Old two-field records are screen-off ones.
printf '0|%s\n' "$NR_ON_DEC" > "$SAVE"; echo "$NR_OFF" > "$MASK"
[ "$(sh -c '. "$1/hdr.sh"; _saved_reason' _ "$T")" = off ] || f "two-field record not read as screen-off"
sh "$L" screen_on; sh "$L" restore >/dev/null 2>&1
[ "$(mask)" = "$NR_ON" ] || f "two-field record not given back on screen_on"

# Toggle off: screen_on gives a light record back.
fresh; ticks 100 100 100; cfg 1 0
sh "$L" screen_on
[ "$(mask)" = "$NR_ON" ] || f "light record kept with the toggle off"
# Screen off without the screen-off mode: a light record is given back.
cfg 0 1; fresh; ticks 100 100 100
[ "$(mask)" = "$NR_OFF" ] || f "light mode needs the screen-off mode to work"
sh "$L" arm >/dev/null 2>&1
[ "$(mask)" = "$NR_ON" ] || f "light record kept at screen-off with the screen-off mode off"
grep -q 'bad save' "$T/st/lte_screenoff.log" 2>/dev/null && f "a 3-field record was read as corrupt"

# Status shows the reason.
fresh; cfg 1 1; ticks 100 100 100
sh "$L" status | grep -qx 'reason=light' || f "status has no reason=light"
sh "$L" restore >/dev/null 2>&1

# Routes: Wi-Fi is not mobile; rmnet and a VPN over rmnet are.
on_mobile() { sh -c '. "$1/hdr.sh"; _on_mobile' _ "$T"; }
echo wlan0 > "$ROUTEF"; on_mobile && f "Wi-Fi route read as mobile"
echo rmnet_data3 > "$ROUTEF"; on_mobile || f "rmnet route not read as mobile"
# fix119: 464XLAT and VPNs. Android keeps defaults per network table; the main table has none.
echo v4-rmnet_data2 > "$ROUTEF"; on_mobile || f "CLAT (v4-rmnet) route not read as mobile"
echo tun0 > "$ROUTEF"
printf 'default via 10.0.0.1 dev rmnet_data2 table rmnet_data2 proto static\ndefault dev tun0 table tun0 proto static\n' > "$T/tables"
on_mobile || f "VPN over mobile data not read as mobile"
printf 'default via 192.168.1.1 dev wlan0 table wlan0 proto static\ndefault via 10.0.0.1 dev rmnet_data2 table rmnet_data2 proto static\ndefault dev tun0 table tun0 proto static\n' > "$T/tables"
on_mobile && f "VPN over Wi-Fi (mobile kept up for handover) read as mobile"
printf 'default via 192.168.1.1 dev wlan0 table wlan0 proto static\n' > "$T/tables"
on_mobile && f "VPN over Wi-Fi read as mobile"
: > "$T/tables"; on_mobile && f "VPN with no default anywhere read as mobile"

# Counters: summed over every rmnet_data*, safe past 2^31 (mksh is 32-bit).
echo 3000000000 > "$T/net/rmnet_data2/statistics/rx_bytes"; echo 1024 > "$T/net/rmnet_data2/statistics/tx_bytes"
echo 2048 > "$T/net/rmnet_data3/statistics/rx_bytes"; echo 0 > "$T/net/rmnet_data3/statistics/tx_bytes"
k="$(sh -c '. "$1/hdr.sh"; _rmnet_kib' _ "$T")"
[ "$k" = 2929690 ] || f "rmnet KiB with a >2^31 counter: $k (want 2929690)"

# The watcher itself: starts once on screen_on, stops on arm.
cfg 1 1; export ASB_LTE_LIGHT_TICK_S=30
sh "$L" screen_on; p1="$(cat "$T/st/lte_light.pid" 2>/dev/null)"
sh "$L" screen_on; p2="$(cat "$T/st/lte_light.pid" 2>/dev/null)"
[ -n "$p1" ] && [ "$p1" = "$p2" ] || f "screen_on started a second watcher ($p1 / $p2)"
sh "$L" arm >/dev/null 2>&1
[ -f "$T/st/lte_light.pid" ] && f "screen-off did not stop the watcher"
sleep 0.2
# A zombie still answers kill -0 where nothing reaps orphans (some CI inits): check the state.
if [ -n "$p1" ] && [ -d "/proc/$p1" ]; then
  case "$(awk '{print $3}' "/proc/$p1/stat" 2>/dev/null)" in
    Z|X|'') : ;;
    *) f "watcher still alive after arm"; kill "$p1" 2>/dev/null ;;
  esac
fi
sh "$L" restore >/dev/null 2>&1

# End to end with a 1 s window: idle counters drop 5G, a burst (~80 Mbit/s) gives it back.
export ASB_LTE_LIGHT_TICK_S=1 ASB_LTE_LIGHT_LOW_TICKS=2
fresh; echo rmnet_data2 > "$ROUTEF"
sh "$L" screen_on
i=0; while [ "$i" -lt 40 ] && [ "$(mask)" != "$NR_OFF" ]; do sleep 0.2; i=$((i + 1)); done
[ "$(mask)" = "$NR_OFF" ] || f "the watcher did not drop 5G on an idle link"
(
  b=3000000000
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    # awk, not $((...)): past 2^31 the shell's arithmetic is 32-bit under mksh (Android's sh).
    b="$(awk -v x="$b" 'BEGIN { printf "%d", x + 10000000 }')"; echo "$b" > "$T/net/rmnet_data2/statistics/rx_bytes"; sleep 0.2
  done
) &
i=0; while [ "$i" -lt 30 ] && [ "$(mask)" != "$NR_ON" ]; do sleep 0.2; i=$((i + 1)); done
wait
[ "$(mask)" = "$NR_ON" ] || f "the watcher did not give 5G back on a burst"
grep -q 'light: .* 5G back' "$T/st/lte_screenoff.log" 2>/dev/null || f "burst restore not logged"
sh "$L" restore >/dev/null 2>&1
rm -rf "$T"
[ "$fail" = 0 ] && echo "PASS lte light-traffic mode (5G only when needed)"
exit "$fail"
)

t_lte_screenoff_contract() (
# Contract for runtime/asb_lte_screenoff.sh - the opt-in "LTE while screen off" tweak.
#
# It changes the modem's allowed network types, so the safety rules are the whole point
# and every one of them is pinned here against a fake `cmd phone`:
#   - off by default, and a no-op while the toggle is 0;
#   - acts only with the screen off and never during a call;
#   - removes exactly the NR bit and saves the original mask;
#   - restore puts back the saved mask exactly and drops the save file;
#   - a ROM that ignores the write is restored and marked unsupported, after which
#     nothing further is attempted.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/runtime/asb_lte_screenoff.sh"
fail() { echo "FAIL lte_screenoff contract: $*"; exit 1; }
[ -f "$S" ] || fail "script missing"

grep -q '^net_screen_off_lte=0$' "$ROOT/config/governor.conf.shipped" || fail "shipped default is not 0"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/mod/config" "$T/state" "$T/dev"
cat > "$T/bin/settings" <<'EOF'
#!/bin/sh
echo 1
EOF
cat > "$T/bin/dumpsys" <<EOF
#!/bin/sh
case "\$1" in
  isub) echo "[SubscriptionInfoInternal: id=1 iccId=8939 simSlotIndex=1 displayName=SIM2]" ;;
  *)    echo "mCallState=\$(cat $T/callstate 2>/dev/null || echo 0)" ;;
esac
EOF
cat > "$T/bin/cmd" <<EOF
#!/bin/sh
shift
case "\$1" in
  get-allowed-network-types-for-users)
    echo "\$*" >> $T/calls
    m=\$(cat $T/mask); out=""
    # Real AOSP spellings, spaces included.
    for p in "GPRS:1" "EDGE:2" "UMTS:4" "CDMA - EvDo rev. 0:16" "HSPA+:16384" "LTE:4096" "GSM:32768" "LTE_CA:262144" "NR:524288"; do
      n=\${p%:*}; b=\${p##*:}; [ \$(( m & b )) -ne 0 ] && out="\${out:+\$out|}\$n"
    done
    echo "\$out" ;;
  set-allowed-network-types-for-users)
    echo "\$*" >> $T/calls
    [ -f $T/ignore_writes ] && exit 0
    for r in "\$@"; do :; done; v=0
    while [ -n "\$r" ]; do c="\${r%"\${r#?}"}"; r="\${r#?}"; v=\$(( v*2 + c )); done
    echo "\$v" > $T/mask ;;
esac
EOF
chmod +x "$T/bin/"*
sed "s|/data/adb/asb|$T/state|; s|/dev/.asb/state|$T/dev/state|" "$S" > "$T/run.sh"
export PATH="$T/bin:$PATH" MODDIR="$T/mod"
run() { sh "$T/run.sh" "$@" </dev/null >/dev/null 2>&1; }

ORIG=839703          # GPRS|EDGE|UMTS|EVDO_0|HSPA+|LTE|GSM|LTE_CA|NR
echo "$ORIG" > "$T/mask"; echo "screen=0" > "$T/dev/state"

echo "net_screen_off_lte=0" > "$T/mod/config/governor.conf"
run apply; [ "$(cat "$T/mask")" = "$ORIG" ] || fail "acted with the toggle off"

echo "net_screen_off_lte=1" > "$T/mod/config/governor.conf"
echo "screen=1" > "$T/dev/state"
run apply; [ "$(cat "$T/mask")" = "$ORIG" ] || fail "acted with the screen on"

echo "screen=0" > "$T/dev/state"; echo 2 > "$T/callstate"
run apply; [ "$(cat "$T/mask")" = "$ORIG" ] || fail "acted during a call"
rm -f "$T/callstate"

run apply
[ "$(cat "$T/mask")" = "$(( ORIG & ~524288 ))" ] || fail "did not remove exactly the NR bit"
[ "$(cat "$T/state/lte_screenoff.saved")" = "1|$ORIG|off" ] || fail "original mask not saved under the data SIM's SLOT (with the screen-off reason)"
grep -q -- '-s 1' "$T/calls" || fail "slot index not passed to cmd phone (subId 1 lives in slot 1)"

run restore
[ "$(cat "$T/mask")" = "$ORIG" ] || fail "restore did not put the original back"
[ ! -e "$T/state/lte_screenoff.saved" ] || fail "save file left after a good restore"

: > "$T/ignore_writes"
run apply
[ "$(cat "$T/mask")" = "$ORIG" ] || fail "mask changed although the ROM ignored the write"
[ -e "$T/state/lte_screenoff.unsupported" ] && fail "one ignored write already marked unsupported (needs three)"
run apply; run apply
[ -e "$T/state/lte_screenoff.unsupported" ] || fail "three ignored writes did not mark unsupported"
rm -f "$T/ignore_writes"
run apply
[ "$(cat "$T/mask")" = "$ORIG" ] || fail "acted again after being marked unsupported"

grep -q 'asb_lte_screenoff.sh" restore' "$ROOT/uninstall.sh" || fail "uninstall does not restore"
grep -q 'lte_screenoff.saved' "$ROOT/service.sh" || fail "no boot-time restore"

# A call on the second SIM blocks it too. The registry prints one mCallState per phone and
# the first version only looked at the first line.
rm -f "$T/state/lte_screenoff.unsupported"
cat > "$T/bin/dumpsys" <<'EOF2'
#!/bin/sh
echo "mCallState=0"
echo "mCallState=2"
EOF2
chmod +x "$T/bin/dumpsys"
run apply; [ "$(cat "$T/mask")" = "$ORIG" ] || fail "acted during a call on SIM 2"

# The uninstaller must restore before it deletes /data/adb/asb - the saved mask lives
# there - and must defer the restore when telephony is not up yet.
U="$ROOT/uninstall.sh"
_l_rest="$(grep -n 'asb_lte_screenoff.sh" restore' "$U" | head -1 | cut -d: -f1)"
_l_rm="$(grep -n '^rm -rf /data/adb/asb 2>/dev/null' "$U" | head -1 | cut -d: -f1)"
[ -n "$_l_rest" ] && [ -n "$_l_rm" ] && [ "$_l_rest" -lt "$_l_rm" ] \
  || fail "uninstall restores 5G after removing the saved mask"
grep -q 'ASB_LTE_STATE_DIR=' "$U" || fail "uninstall has no deferred restore"
grep -q 'STATE_DIR="${ASB_LTE_STATE_DIR:-/data/adb/asb}"' "$S" || fail "state dir not overridable"

grep -q '_tethering && ' "$S" || fail "applies while tethering"
grep -q 'tail -n 300 "$LOGF"' "$S" || fail "log is unbounded"
echo "PASS lte_screenoff contract"
)

t_lte_screenoff_quiet_runtime() (
# Runtime (fix122): screen-off LTE switches only when mobile data is moving (an idle phone
# keeps 5G - nothing to save, and the restore at the unlock is a data stall); it settles
# and re-checks the power manager before switching, so a timer running out as the phone
# wakes cannot apply under the user's thumb; a switch the screen interrupted is given back;
# MediaTek's ccmni links are counted; a phone with no counters keeps the old behaviour.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
fail=0; f() { echo "FAIL lte quiet: $*" >&2; fail=1; }
cleanup() { [ -f "$T/st/lte_screenoff.pid" ] && kill "$(cat "$T/st/lte_screenoff.pid")" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/st" "$T/mod/config" "$T/net/rmnet_data3/statistics"
echo net_screen_off_lte=1 > "$T/mod/config/governor.conf"
echo screen=0 > "$T/state"
cat > "$T/bin/cmd" <<'S'
#!/bin/sh
case "$2" in
  get-allowed-network-types-for-users) cat "$MASK" ;;
  set-allowed-network-types-for-users) shift 2; [ "$1" = -s ] && shift 2; echo "$1" > "$MASK"
    [ -f "$WAKE_ON_SET" ] && echo "mWakefulness=Awake" > "$WAKEF" ;;
esac
S
printf '#!/bin/sh\necho 1\n' > "$T/bin/settings"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
echo "id=1 simSlotIndex=0"
echo "mCallState=0"
cat "$WAKEF" 2>/dev/null
S
printf '#!/bin/sh\ncat "$DSF" 2>/dev/null\n' > "$T/bin/getprop"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st" \
       ASB_STATE_FILE="$T/state" WAKEF="$T/wake" DSF="$T/ds" ASB_NET_SYS="$T/net" \
       WAKE_ON_SET="$T/wake_on_set" ASB_LTE_DELAY_S=1 ASB_LTE_SETTLE_S=0 \
       ASB_LTE_OFF_BULK_KBPS=1000000
# ^ fix131: with 1 s windows the minimum stream here (512 KiB/s) is above the real transfer
#   mark; this file tests the quiet/settle logic, test_lte_bulk_runtime.sh tests transfers.
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001; NR_OFF=1011111110000000001
SAVE="$T/st/lte_screenoff.saved"
rx() { echo "$1" > "$T/net/rmnet_data3/statistics/rx_bytes"; echo 0 > "$T/net/rmnet_data3/statistics/tx_bytes"; }
reset() { sh "$L" restore >/dev/null 2>&1; rm -f "$SAVE" "$T/st/lte_screenoff.quiet" "$WAKE_ON_SET"; echo "$NR_ON" > "$MASK"
          echo "mWakefulness=Asleep" > "$WAKEF"; echo 1 > "$T/ds"; echo screen=0 > "$T/state"; }

# 1. Idle in the pocket: windows pass, 5G stays, the timer keeps watching.
reset; rx 1000000
sh "$L" arm; sleep 2.6
[ -f "$SAVE" ] && f "applied with no mobile data moving"
[ "$(cat "$MASK")" = "$NR_ON" ] || f "mask changed on an idle phone"
[ "$(cat "$T/st/lte_screenoff.quiet" 2>/dev/null)" -ge 1 ] 2>/dev/null || f "quiet windows not counted"
[ -s "$T/st/lte_screenoff.pid" ] && kill -0 "$(cat "$T/st/lte_screenoff.pid")" 2>/dev/null || f "timer stopped watching after a quiet window"
sh "$L" status | grep -q '^quiet_windows=[1-9]' || f "status does not report quiet windows"
# ...then a stream starts (2 MiB in a 1 s window): the next window switches.
rx 3200000; sleep 1.6
[ -f "$SAVE" ] || f "a stream with the screen off did not switch to LTE"
[ "$(cat "$MASK")" = "$NR_OFF" ] || f "mask not LTE after the stream window: $(cat "$MASK")"

# 2. Screen on mid-wait: the timer goes, nothing is switched.
reset; rx 1000000
sh "$L" arm; sleep 0.3; sh "$L" screen_on; rx 9000000; sleep 1.5
[ -f "$SAVE" ] && f "applied after the screen came on"
[ -f "$T/st/lte_screenoff.pid" ] && f "screen_on did not disarm the timer"

# 3. The wake race: Android already reports the display ON while the governor file says off.
reset; echo 2 > "$T/ds"
sh "$L" apply
[ -f "$SAVE" ] && f "applied while Android's display state is ON"
# ...and the power manager Awake during the settle (display state not yet moved).
reset; ( sleep 0.4; echo "mWakefulness=Awake" > "$WAKEF" ) &
ASB_LTE_SETTLE_S=1 sh "$L" apply; wait
[ -f "$SAVE" ] && f "applied although the power manager turned Awake during the settle"
[ "$(cat "$MASK")" = "$NR_ON" ] || f "mask changed in the wake race"

# 4. The screen comes on during the switch itself: 5G is given straight back.
reset; true > "$WAKE_ON_SET"
sh "$L" apply
[ -f "$SAVE" ] && f "record left after an interrupted switch"
[ "$(cat "$MASK")" = "$NR_ON" ] || f "5G not given back after the screen came on during the switch"
grep -q 'the screen came on during the switch' "$T/st/lte_screenoff.log" || f "interrupted switch not logged"

# 5. MediaTek: ccmni counted.
reset; rm -rf "$T/net/rmnet_data3"; mkdir -p "$T/net/ccmni1/statistics"
echo 5242880 > "$T/net/ccmni1/statistics/rx_bytes"; echo 1048576 > "$T/net/ccmni1/statistics/tx_bytes"
sed '/^case "\$1" in$/,$d' "$L" > "$T/hdr.sh"
kib="$(sh -c '. "$1"; _rmnet_kib' x "$T/hdr.sh")"
[ "$kib" = 6144 ] || f "ccmni traffic not counted (got '$kib' KiB)"

# 6. No counters at all: the old behaviour - apply after one window.
reset; rm -rf "$T/net/ccmni1"
sh "$L" arm; sleep 1.6
[ -f "$SAVE" ] || f "a phone without mobile counters never switches any more"

[ "$fail" = 0 ] && echo "PASS lte screen-off: only with data moving, settle and re-check, interrupted switch undone, ccmni"
exit "$fail"
)

t_lte_screenoff_restore_runtime() (
# Runtime: screen-off LTE always gives 5G back. A good record restores the exact mask; an
# unreadable one still returns the NR bit; a phone whose earlier restore dropped its record
# gets 5G back once.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL lte restore: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
echo net_screen_off_lte=1 > "$T/mod/config/governor.conf"
cat > "$T/bin/cmd" <<'S'
#!/bin/sh
case "$2" in
  get-allowed-network-types-for-users) cat "$MASK" ;;
  set-allowed-network-types-for-users) shift 2; [ "$1" = -s ] && shift 2; echo "$1" > "$MASK" ;;
esac
S
printf '#!/bin/sh\necho 1\n' > "$T/bin/settings"
printf '#!/bin/sh\necho "id=1 simSlotIndex=0"\n' > "$T/bin/dumpsys"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st"
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001     # 916481
NR_OFF=01011111110000000001    # 392193

echo "$NR_OFF" > "$MASK"; printf '0|916481\n' > "$T/st/lte_screenoff.saved"
sh "$L" restore
[ "$(cat "$MASK")" = "$NR_ON" ] || f "good record not restored: $(cat "$MASK")"
[ -f "$T/st/lte_screenoff.saved" ] && f "record kept after restore"

echo "$NR_OFF" > "$MASK"; printf 'garbage\n' > "$T/st/lte_screenoff.saved"
sh "$L" restore
[ "$(cat "$MASK")" = "$NR_ON" ] || f "unreadable record: NR not given back ($(cat "$MASK"))"

rm -f "$T/st/"*; echo "$NR_OFF" > "$MASK"
echo "10-08 01:07:30 restore: bad save file dropped" > "$T/st/lte_screenoff.log"
sh "$L" restore
[ "$(cat "$MASK")" = "$NR_ON" ] || f "dropped-record repair did not give 5G back"
echo "$NR_OFF" > "$MASK"; sh "$L" restore
[ "$(cat "$MASK")" = "$NR_OFF" ] || f "repair ran twice (a later user choice must stand)"
echo "$NR_OFF" > "$MASK"; [ "$(sh "$L" nr)" = no ] || f "nr does not report 5G missing"
echo "$NR_ON" > "$MASK"; [ "$(sh "$L" nr)" = yes ] || f "nr does not report 5G allowed"
grep -Fq 'asb_lte_screenoff.sh" nr' "$ROOT/action.sh" || f "action claims 5G allowed without checking"
[ "$fail" = 0 ] && echo "PASS lte screen-off restore runtime"
exit "$fail"
)

t_lte_screenoff_retry_runtime() (
# Runtime (fix86): a screen-off LTE apply skipped for a call or tethering re-arms itself
# instead of leaving 5G on for the rest of the night (OP15: skip at 03:12, nothing until 11:10).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
fail=0; f() { echo "FAIL lte retry: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/st" "$T/mod/config"
echo net_screen_off_lte=1 > "$T/mod/config/governor.conf"
echo screen=0 > "$T/state"
cat > "$T/bin/cmd" <<'S'
#!/bin/sh
case "$2" in
  get-allowed-network-types-for-users) cat "$MASK" ;;
  set-allowed-network-types-for-users) shift 2; [ "$1" = -s ] && shift 2; echo "$1" > "$MASK" ;;
esac
S
printf '#!/bin/sh\necho 1\n' > "$T/bin/settings"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
echo "id=1 simSlotIndex=0"
cat "$CALLF" 2>/dev/null
cat "$WAKEF" 2>/dev/null
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" MASK="$T/mask" MODDIR="$T/mod" ASB_LTE_STATE_DIR="$T/st" \
       ASB_STATE_FILE="$T/state" CALLF="$T/call" WAKEF="$T/wake" ASB_LTE_RETRY_S=3601 ASB_LTE_SETTLE_S=0
L="$ROOT/runtime/asb_lte_screenoff.sh"
NR_ON=11011111110000000001
echo "$NR_ON" > "$MASK"
echo "mCallState=2" > "$T/call"
sh "$L" apply
[ "$(cat "$T/st/lte_screenoff.retry" 2>/dev/null)" = 1 ] || f "skip did not count a retry"
[ -s "$T/st/lte_screenoff.pid" ] || f "skip did not re-arm a timer"
grep -q 'will retry every 3601s' "$T/st/lte_screenoff.log" || f "first skip not logged"
sh "$L" apply
[ "$(grep -c 'skipped' "$T/st/lte_screenoff.log")" = 1 ] || f "every retry is logged"
sh "$L" restore
[ -f "$T/st/lte_screenoff.retry" ] && f "screen-on did not clear the retry counter"
[ -f "$T/st/lte_screenoff.pid" ] && f "screen-on did not disarm the retry timer"
# call over: the apply goes through
echo "mCallState=0" > "$T/call"
sh "$L" apply
[ -f "$T/st/lte_screenoff.saved" ] || f "apply after the call did not happen"
sleep 0.3
ps -eo pid=,args= 2>/dev/null | grep -q "[s]leep 3601" && f "disarm left the timer sleep running"
# a stale state file (screen=1) must not block the apply when the power manager says asleep
sh "$L" restore; echo "$NR_ON" > "$MASK"; echo screen=1 > "$T/state"
echo "mWakefulness=Awake" > "$T/wake"; sh "$L" apply
[ -f "$T/st/lte_screenoff.saved" ] && f "applied while the screen is really on"
echo "mWakefulness=Asleep" > "$T/wake"; sh "$L" apply
[ -f "$T/st/lte_screenoff.saved" ] || f "stale screen=1 in the state file blocked the apply"
rm -rf "$T"
[ "$fail" = 0 ] && echo "PASS lte screen-off retries a skipped apply"
exit "$fail"
)

t_ltpo_contract() (
# Force-LTPO contract: the patch is device-local and fail-closed, the toggle defaults
# off, and every lifecycle owner (install, boot, late boot, uninstall, WebUI) reaches
# the one runtime script that owns the bind.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_ltpo_apply.sh"
WEB="$ROOT/webroot/index.html"
INSTALL="$ROOT/common/install.sh"
fail() { echo "FAIL ltpo contract: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail 'runtime/asb_ltpo_apply.sh missing'
sh -n "$SRC"

# --- WebUI wiring: card, default-off, system group, own icon, honest reboot label ---
grep -q "key:'ltpo_force', type:'bool', def:'0'" "$WEB" || fail 'ltpo_force card missing or default not off'
grep -q "ltpo_force:'ui'" "$WEB" || fail 'ltpo_force not in the System category group'
grep -q "ltpo_force:'system'" "$WEB" || fail 'ltpo_force missing category colour mapping'
grep -q "ltpo_force:'ltpo'" "$WEB" || fail 'ltpo_force missing its icon mapping'
grep -q "ltpo: '<rect" "$WEB" || fail 'ltpo icon glyph missing from TECH_ICON_PATHS'
grep -q "ltpo_force:APPLY_REBOOT" "$WEB" || fail 'ltpo_force must honestly label as reboot-to-apply'
grep -q "'ltpo_force'," "$WEB" || fail 'ltpo_force missing from SNAP_KEYS (export/restore)'
grep -q "runtime/asb_ltpo_apply.sh apply" "$WEB" || fail 'cfgSet never calls the apply script'

# --- i18n: every shipped locale carries name + desc ---
for f in "$ROOT"/webroot/i18n/*.json; do
  python3 -c "
import json,sys
d=json.load(open('$f'))
c=d.get('cfg',{}).get('ltpo_force')
sys.exit(0 if (c and c.get('name') and c.get('desc')) else 1)
" || fail "ltpo_force i18n missing in $(basename "$f")"
done

# --- install-time staging ---
grep -q 'asb_prepare_ltpo_patch()' "$INSTALL" || fail 'install staging function missing'
grep -q '^asb_prepare_ltpo_patch$' "$INSTALL" || fail 'staging function never called'
grep -q 'ltpo_patched' "$INSTALL" || fail 'payload staging path missing'
grep -q 'ltpo_bind_manifest.txt' "$INSTALL" || fail 'manifest write missing'
# The installer no longer announces LTPO: the tweak ships off, and a "patch ready" line
# during install reads as if something had been switched on. Staging itself still runs and
# is asserted above; the WebUI card reports the state when the user goes looking.
! grep -q 'ASB_L_LTPO_READY' "$ROOT/common/install.sh" || fail 'installer still prints an LTPO line'
# The payload must NOT live under a magic-mountable module path: that would be always-on.
if grep -q 'MODPATH/my_product' "$INSTALL"; then
  fail 'payload staged under a magic-mount path - that bypasses the toggle'
fi

# --- install patcher key set: grown from a real OP15 table, telemetry cut, no mvt ---
grep -q 'pdfr' "$INSTALL" || fail 'patcher does not know the OP15 power-saving keys'
grep -q 'refreshrate_director' "$INSTALL" || fail 'patcher misses refreshrate_director'
grep -q 'limit_fps_when_app_exit' "$INSTALL" || fail 'patcher misses limit_fps_when_app_exit'
grep -q 'vrr_info_record' "$INSTALL" || fail 'patcher does not cut display telemetry'
grep -q 'big_data' "$INSTALL" || fail 'patcher does not cut big_data telemetry'
grep -q 're_cache_miss' "$INSTALL" || fail 'patcher does not cut re_cache_miss telemetry'
# mvt reshapes render division and touch_frame_change buys feel with power: neither may
# ever be force-flipped, so outside the comment block those names must not appear.
if sed -n '/^asb_prepare_ltpo_patch()/,/^}/p' "$INSTALL" | grep -v '^  #' | grep -q 'mvt\|touch_frame_change'; then
  fail 'patcher flips mvt/touch_frame_change - those are a power/feel trade, not a win'
fi

# --- lifecycle owners ---
grep -q 'asb_ltpo_apply.sh" apply' "$ROOT/post-fs-data.sh" || fail 'post-fs-data never applies'
grep -q 'asb_ltpo_apply.sh" apply' "$ROOT/service.sh" || fail 'service.sh never rebinds late'
grep -q 'asb_ltpo_apply.sh" remove' "$ROOT/uninstall.sh" || fail 'uninstall never drops the bind'
grep -q 'ltpo_bind_manifest.txt' "$ROOT/post-fs-data.sh" || fail 'bootloop fuse does not clear the ltpo manifest'

# --- runtime guard pins: fail-closed allowlist, payload prefix, JSON balance ---
grep -q '/my_product/etc/oplus_vrr_config.json|' "$SRC" || fail 'target allowlist missing'
grep -q '"\$STATE_DIR/ltpo_patched/"\*)' "$SRC" || fail 'payload prefix check missing'
grep -q "tr -cd '{'" "$SRC" || fail 'JSON brace balance check missing'
grep -q '_cfg ltpo_force)' "$SRC" || fail 'toggle gate missing'
grep -q 'nsenter -t 1 -m -- mount --bind' "$SRC" || fail 'global-namespace bind missing'
grep -q 'ASB_LTPO_PROC_MOUNTS:-/proc/mounts' "$SRC" || fail 'mounts table not injectable for fixtures'

# --- runtime fixture: mocked mount/umount/nsenter, no real radio or mount ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mod/config" "$TMP/bin" "$TMP/state" "$TMP/live/my_product/etc"
printf 'name=AutoSystemBoost\n' > "$TMP/mod/module.prop"

# A stock table with the OEM switches OFF, like the field device shipped.
cat > "$TMP/live/my_product/etc/oplus_vrr_config.json" <<'EOF'
[
    {
        "filter_name": "oplus_adfr_config"
    },
    {
        "touch_idle": true, "hw_enable": false, "sw_enable": false, "adfr_enable": false,
        "timeout": 2500, "darkmode_enable": true
    },
    {
        "cvt": true
    }
]
EOF

cat > "$TMP/bin/mount" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ASB_LTPO_LOG"
EOF
cat > "$TMP/bin/umount" <<'EOF'
#!/bin/sh
printf 'umount %s\n' "$*" >> "$ASB_LTPO_LOG"
EOF
chmod 0755 "$TMP/bin/mount" "$TMP/bin/umount"
export PATH="$TMP/bin:$PATH"
export ASB_LTPO_LOG="$TMP/mount.log"
export ASB_LTPO_STATE_DIR="$TMP/state"
export ASB_LTPO_PROC_MOUNTS="$TMP/mounts"
export ASB_LTPO_LIVE_ROOT="$TMP/live"
: > "$TMP/mounts"

LIVE="$TMP/live/my_product/etc/oplus_vrr_config.json"
# The manifest/payload live under the injected state dir, so build the payload there.
mkdir -p "$TMP/state/ltpo_patched$TMP/live/my_product/etc"
PAYLOAD="$TMP/state/ltpo_patched${LIVE}"
sed 's/"hw_enable": false/"hw_enable": true/; s/"sw_enable": false/"sw_enable": true/' \
    "$LIVE" > "$PAYLOAD"
printf '%s|%s\n' "$LIVE" "$PAYLOAD" > "$TMP/state/ltpo_bind_manifest.txt"

run() { MODDIR="$TMP/mod" sh "$SRC" "$@"; }

# Toggle off: nothing mounts, even with a valid manifest.
printf 'ltpo_force=0\n' > "$TMP/mod/config/governor.conf"
run apply
[ ! -s "$ASB_LTPO_LOG" ] || fail 'mounted while the toggle was off'

# Toggle on + valid manifest: bind happens and ownership is recorded.
printf 'ltpo_force=1\n' > "$TMP/mod/config/governor.conf"
run apply
grep -q -- "--bind $PAYLOAD $LIVE" "$ASB_LTPO_LOG" || fail 'valid manifest was not bound'
[ -f "$TMP/state/ltpo_bind.active" ] || fail 'active marker not written'

# Toggle off with an active bind: it is removed (simulate the kernel view of the bind).
printf "%s %s ext4 rw 0 0\n" "$PAYLOAD" "$LIVE" > "$TMP/mounts"
printf 'ltpo_force=0\n' > "$TMP/mod/config/governor.conf"
run apply
grep -q "umount $LIVE" "$ASB_LTPO_LOG" || fail 'toggle-off did not unbind'
[ ! -f "$TMP/state/ltpo_bind.active" ] || fail 'active marker not cleared'

# Fail-closed: a malformed manifest line must never mount.
printf '%s|%s|extra\n' "$LIVE" "$PAYLOAD" > "$TMP/state/ltpo_bind_manifest.txt"
: > "$ASB_LTPO_LOG"
printf 'ltpo_force=1\n' > "$TMP/mod/config/governor.conf"
run apply
[ ! -s "$ASB_LTPO_LOG" ] || fail 'malformed manifest was mounted'

# Fail-closed: a payload outside the state dir must never mount.
printf '%s|%s\n' "$LIVE" "/etc/passwd" > "$TMP/state/ltpo_bind_manifest.txt"
: > "$ASB_LTPO_LOG"
run apply
[ ! -s "$ASB_LTPO_LOG" ] || fail 'out-of-bounds payload was mounted'

# Fail-closed: a target outside the allowlist must never mount.
printf '%s|%s\n' "/system/etc/hosts" "$PAYLOAD" > "$TMP/state/ltpo_bind_manifest.txt"
: > "$ASB_LTPO_LOG"
run apply
[ ! -s "$ASB_LTPO_LOG" ] || fail 'out-of-allowlist target was mounted'

# Fail-closed: a brace-unbalanced payload must never mount.
printf '%s|%s\n' "$LIVE" "$PAYLOAD" > "$TMP/state/ltpo_bind_manifest.txt"
printf '{ "broken": ' > "$PAYLOAD"
: > "$ASB_LTPO_LOG"
run apply
[ ! -s "$ASB_LTPO_LOG" ] || fail 'unbalanced JSON payload was mounted'

# remove: unbinds regardless of the toggle state.
sed 's/{ "broken": /{ "fixed": true }/' "$PAYLOAD" > "$PAYLOAD.fixed"
mv "$PAYLOAD.fixed" "$PAYLOAD"
# Rebuild a valid payload.
sed 's/"hw_enable": false/"hw_enable": true/' "$LIVE" > "$PAYLOAD"
printf "%s %s ext4 rw 0 0\n" "$PAYLOAD" "$LIVE" > "$TMP/mounts"
: > "$TMP/state/ltpo_bind.active"
: > "$ASB_LTPO_LOG"
printf 'ltpo_force=1\n' > "$TMP/mod/config/governor.conf"
run remove
grep -q "umount $LIVE" "$ASB_LTPO_LOG" || fail 'remove did not unbind'
[ ! -f "$TMP/state/ltpo_bind.active" ] || fail 'remove kept the active marker'

# status vocabulary stays stable for the WebUI/diag readers.
printf 'ltpo_force=0\n' > "$TMP/mod/config/governor.conf"
[ "$(run status)" = 'ltpo_off' ] || fail 'status off vocabulary changed'

# --- executable install-patcher fixture: the REAL staging function against fixture
# tables, with only the state root and live path rewritten to the sandbox ---
LT_DIR="$TMP/installer"
mkdir -p "$LT_DIR/asb" "$LT_DIR/live"
sed -n '/^asb_prepare_ltpo_patch()/,/^}/p' "$INSTALL" |
  sed "s|/data/adb/asb|$LT_DIR/asb|g; s|/my_product/etc/oplus_vrr_config.json|$LT_DIR/live/oplus_vrr_config.json|" \
  > "$LT_DIR/func.sh"
lt_patch() { # $1 = fixture table; prints the resulting ltpo_state
  rm -rf "$LT_DIR/asb"; mkdir -p "$LT_DIR/asb"
  cp "$1" "$LT_DIR/live/oplus_vrr_config.json"
  ( ui_print() { :; }; . "$LT_DIR/func.sh"; asb_prepare_ltpo_patch >/dev/null )
  cat "$LT_DIR/asb/ltpo_state" 2>/dev/null || echo missing
}
LT_PAY="$LT_DIR/asb/ltpo_patched$LT_DIR/live/oplus_vrr_config.json"

# OP15-style: every feature already on, telemetry on -> patch with ONLY telemetry cut.
cat > "$LT_DIR/case1.json" <<'JSON'
[
    { "filter_name": "oplus_adfr_config" },
    { "touch_idle": true, "hw_enable": true, "sw_enable": true, "adfr_enable": true, "pdfr": true },
    { "vrr_info_record": true },
    { "big_data": true, "re_cache_miss": true }
]
JSON
[ "$(lt_patch "$LT_DIR/case1.json")" = 'ready' ] || fail 'OP15-style table did not produce a telemetry-cut patch'
python3 - "$LT_PAY" <<'PY' || fail 'OP15-style payload is wrong'
import json, sys
d = json.load(open(sys.argv[1]))
flat = {}
[flat.update(e) for e in d if isinstance(e, dict)]
assert flat['hw_enable'] is True and flat['adfr_enable'] is True, 'features were changed'
assert flat['vrr_info_record'] is False, 'vrr_info_record not cut'
assert flat['big_data'] is False and flat['re_cache_miss'] is False, 'telemetry not cut'
PY

# Donor-style: features off, telemetry on -> everything lands in the right direction.
cat > "$LT_DIR/case2.json" <<'JSON'
[
    { "hw_enable": false, "sw_enable": false, "adfr_enable": false, "pdfr": false,
      "refreshrate_director": false, "limit_fps_when_app_exit": false, "feature_hybrid_acc" : false },
    { "hist_data_enable": true }
]
JSON
[ "$(lt_patch "$LT_DIR/case2.json")" = 'ready' ] || fail 'donor-style table was not patched'
python3 - "$LT_PAY" <<'PY' || fail 'donor-style payload is wrong'
import json, sys
d = json.load(open(sys.argv[1]))
flat = {}
[flat.update(e) for e in d if isinstance(e, dict)]
for k in ('hw_enable','sw_enable','adfr_enable','pdfr','refreshrate_director',
          'limit_fps_when_app_exit','feature_hybrid_acc'):
    assert flat[k] is True, f'{k} not enabled'
assert flat['hist_data_enable'] is False, 'hist_data_enable not cut'
PY

# Ideal table: features on AND telemetry off -> honestly "already", no manifest.
cat > "$LT_DIR/case3.json" <<'JSON'
[
    { "hw_enable": true, "sw_enable": true },
    { "vrr_info_record": false, "big_data": false }
]
JSON
[ "$(lt_patch "$LT_DIR/case3.json")" = 'already' ] || fail 'ideal table not reported as already'
[ ! -f "$LT_DIR/asb/ltpo_bind_manifest.txt" ] || fail 'ideal table still wrote a manifest'

# No table at all -> "unsupported".
rm -rf "$LT_DIR/asb"; mkdir -p "$LT_DIR/asb"; rm -f "$LT_DIR/live/oplus_vrr_config.json"
( ui_print() { :; }; . "$LT_DIR/func.sh"; asb_prepare_ltpo_patch >/dev/null )
[ "$(cat "$LT_DIR/asb/ltpo_state" 2>/dev/null)" = 'unsupported' ] || fail 'missing table not reported unsupported'

echo 'PASS: force-LTPO contract'
)

t_ltpo_range_runtime() (
# Runtime: ltpo_force=1 opens the Android refresh range at both ends (no floor, peak = the
# panel's highest mode), records what it found first, and gives exactly that back on off.
# A video lowering in progress is never recorded as the user's own peak.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL ltpo range: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/mod/runtime" "$T/d" "$T/s"
cp "$ROOT/runtime/asb_ltpo_apply.sh" "$T/mod/runtime/"
touch "$T/mod/module.prop"
cat > "$T/disp" <<'X'
      DisplayMode{id=1, width=1272, height=2772, peakRefreshRate=60.000004, vsyncRate=60.000004, group=0}
      DisplayMode{id=2, width=1272, height=2772, peakRefreshRate=90.0, vsyncRate=90.0, group=0}
      DisplayMode{id=4, width=1272, height=2772, peakRefreshRate=144.00002, vsyncRate=144.00002, group=0}
      DisplayMode{id=5, width=1272, height=2772, peakRefreshRate=165.0, vsyncRate=165.0, group=0}
X
cat > "$T/bin/settings" <<'S'
#!/bin/sh
case "$1" in
  get) [ -f "$SD/$3" ] && cat "$SD/$3" || echo null ;;
  put) echo "$4" > "$SD/$3" ;;
  delete) rm -f "$SD/$3" ;;
esac
S
chmod +x "$T/bin/settings"
export PATH="$T/bin:$PATH" SD="$T/s" MODDIR="$T/mod" ASB_LTPO_STATE_DIR="$T/d" ASB_LTPO_DISPLAY_DUMP="$T/disp"
A="$T/mod/runtime/asb_ltpo_apply.sh"
echo 120.0 > "$T/s/peak_refresh_rate"; echo 60.0 > "$T/s/min_refresh_rate"

echo ltpo_force=1 > "$T/mod/config/governor.conf"; sh "$A" apply
[ "$(cat "$T/s/peak_refresh_rate")" = 165.0 ] || f "peak not raised to the panel maximum: $(cat "$T/s/peak_refresh_rate")"
[ -f "$T/s/min_refresh_rate" ] && f "refresh floor not removed"
grep -qx 'peak=120.0' "$T/d/ltpo_range.orig" && grep -qx 'min=60.0' "$T/d/ltpo_range.orig" || f "baseline not recorded"
# Re-apply must not overwrite the baseline with ASB's own values.
sh "$A" apply
grep -qx 'peak=120.0' "$T/d/ltpo_range.orig" || f "baseline overwritten on re-apply"

# The asbdiag diagnostic line: the deleted floor must read as the open range, and the
# recorded originals must not glue onto an empty value - the fix192 field report printed
# "min= recorded=peak=120.0 min=__unset" on two different devices (fix196).
_rng="$(sh "$A" range)"
case "$_rng" in
  "max_mode=165 peak=165.0 min=none (floor open) original: peak=120.0 min=60.0") : ;;
  *) f "range diagnostic garbled: $_rng" ;;
esac

echo ltpo_force=0 > "$T/mod/config/governor.conf"; sh "$A" apply
[ "$(cat "$T/s/peak_refresh_rate")" = 120.0 ] && [ "$(cat "$T/s/min_refresh_rate")" = 60.0 ] || f "off did not restore peak/min"
[ -f "$T/d/ltpo_range.orig" ] && f "baseline kept after restore"

# Unset values come back as unset.
rm -f "$T/s/peak_refresh_rate" "$T/s/min_refresh_rate"
echo ltpo_force=1 > "$T/mod/config/governor.conf"; sh "$A" apply
grep -qx 'peak=__unset' "$T/d/ltpo_range.orig" || f "unset peak not recorded as unset"
echo ltpo_force=0 > "$T/mod/config/governor.conf"; sh "$A" apply
[ -f "$T/s/peak_refresh_rate" ] && f "unset peak not deleted on restore"

# Booting into a lowered video peak: the video record's original is the user's peak.
echo 60.0 > "$T/s/peak_refresh_rate"
printf 'orig=144.0\nset=60.0\ncontent=30\nsince=1\n' > "$T/d/ltpo_video.lowered"
echo ltpo_force=1 > "$T/mod/config/governor.conf"; sh "$A" apply
grep -qx 'peak=144.0' "$T/d/ltpo_range.orig" || f "a lowered video peak was recorded as the user's"
[ "$(cat "$T/s/peak_refresh_rate")" = 60.0 ] || f "range fought the video watcher while lowered"
grep -qx 'orig=165.0' "$T/d/ltpo_video.lowered" || f "open peak not handed to the video record"

# The diagnostic stays readable with an unset baseline too (nothing was ever recorded).
rm -f "$T/d/ltpo_video.lowered"
_rng="$(sh "$A" range)"
case "$_rng" in
  "max_mode=165 peak=60.0 min=none (floor open) original: peak=144.0 min=__unset") : ;;
  *) f "range diagnostic with a video-held peak garbled: $_rng" ;;
esac

[ "$fail" = 0 ] && echo "PASS ltpo range runtime"
exit "$fail"
)

t_ltpo_video_runtime() (
# Runtime: ltpo_video lowers the peak refresh only during quiet video playback and gives
# it back at once - on the first touch, when playback stops, when switched off, and after
# a crash. Stubs replay the field formats (SurfaceFlinger requestedFrameRate, display
# modes) and a touchscreen that "touches" when a flag file appears.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
fail=0; f() { echo "FAIL ltpo video: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/mod/runtime" "$T/d" "$T/snd/card0/pcm0p/sub0" "$T/bl/panel0"
cp "$ROOT/runtime/asb_ltpo_video.sh" "$T/mod/runtime/"
echo 900 > "$T/bl/panel0/brightness"
echo "state: RUNNING" > "$T/snd/card0/pcm0p/sub0/status"
printf 'screen=1\nstate=MODERATE\n' > "$T/rstate"
echo "165.0" > "$T/peak"
cat > "$T/sf" <<'X'
 │  └─ com.google.android.youtube/Shell$HomeActivity#3372 requestedFrameRate: {0.00 Hz FrameRateCompatibility::Default FrameRateCategory::NoPreference} pid=5401 uid=10658 z=0
 │     └─ 435dddb SurfaceView[com.google.andro[...]](BLAST)#3377 requestedFrameRate: {30.00 Hz FrameRateCompatibility::ExactOrMultiple FrameRateCategory::Default} pid=5401 uid=10658 z=0
 │  └─ StatusBar#105 requestedFrameRate: {0.00 Hz FrameRateCompatibility::Default FrameRateCategory::Normal} pid=10675 uid=10283 z=0
X
cat > "$T/disp" <<'X'
      DisplayMode{id=0, width=1272, height=2772, peakRefreshRate=120.00001, vsyncRate=120.00001, group=0}
      DisplayMode{id=1, width=1272, height=2772, peakRefreshRate=60.000004, vsyncRate=60.000004, group=0}
      DisplayMode{id=2, width=1272, height=2772, peakRefreshRate=90.0, vsyncRate=90.0, group=0}
      DisplayMode{id=5, width=1272, height=2772, peakRefreshRate=165.0, vsyncRate=165.0, group=0}
X
cat > "$T/bin/settings" <<'S'
#!/bin/sh
case "$1" in
  get) [ -f "$PEAK" ] && cat "$PEAK" || echo null ;;
  put) echo "$4" > "$PEAK" ;;
  delete) rm -f "$PEAK" ;;
esac
S
cat > "$T/bin/getevent" <<'S'
#!/bin/sh
if [ "$1" = -pl ]; then
  echo "add device 1: /dev/input/event9"; echo "    ABS (0003): ABS_MT_POSITION_X : value 0"; exit 0
fi
while [ ! -f "$TOUCH" ]; do sleep 0.1; done
rm -f "$TOUCH"
exit 0
S
cat > "$T/bin/getprop" <<'S'
#!/bin/sh
echo 1
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" PEAK="$T/peak" TOUCH="$T/touch" MODDIR="$T/mod" \
  ASB_LTPO_STATE_DIR="$T/d" ASB_LTPO_RSTATE="$T/rstate" ASB_LTPO_ASOUND="$T/snd" \
  ASB_LTPO_BACKLIGHT="$T/bl" ASB_LTPO_SF_DUMP="$T/sf" ASB_LTPO_DISPLAY_DUMP="$T/disp" ASB_LTPO_QUIET_S=1 \
  ASB_LTPO_REARM_QUIET_S=3
V="$T/mod/runtime/asb_ltpo_video.sh"
cleanup() { echo ltpo_video=0 > "$T/mod/config/governor.conf"; sh "$V" stop >/dev/null 2>&1; touch "$T/touch"; sleep 0.3; rm -rf "$T"; }
trap cleanup EXIT
wait_for() {   # $1 = expected peak, $2 = tenths of a second
  _i=0
  while [ "$_i" -lt "$2" ]; do
    [ "$(cat "$T/peak" 2>/dev/null)" = "$1" ] && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}

# Decision on the field formats.
[ "$(sh "$V" decide)" = 60 ] || f "30 fps ExactOrMultiple should pick 60 Hz, got $(sh "$V" decide)"
sed 's/30.00 Hz/24.00 Hz/' "$T/sf" > "$T/sf24"
[ "$(ASB_LTPO_SF_DUMP="$T/sf24" sh "$V" decide)" = none ] || f "24 fps must be left alone"
sed 's/FrameRateCategory::Normal/FrameRateCategory::High/' "$T/sf" > "$T/sfhi"
[ "$(ASB_LTPO_SF_DUMP="$T/sfhi" sh "$V" decide)" = veto_high ] || f "a High category must veto"

echo ltpo_video=1 > "$T/mod/config/governor.conf"
sh "$V" reconcile
wait_for 60.0 200 || f "did not lower during quiet playback (peak $(cat "$T/peak"))"
grep -q '^orig=165.0$' "$T/d/ltpo_video.lowered" 2>/dev/null || f "original not recorded before lowering"

# First touch: back at once, from the guard itself.
touch "$T/touch"
wait_for 165.0 10 || f "first touch did not restore within 1 s (peak $(cat "$T/peak"))"
# The guard writes the stamp right after the settings write the loop above saw; under a
# loaded parallel run that is a few milliseconds later - poll briefly instead of racing it.
_ta=0; while [ ! -s "$T/d/ltpo_video.touch_at" ] && [ "$_ta" -lt 20 ]; do sleep 0.05; _ta=$((_ta + 1)); done
[ -s "$T/d/ltpo_video.touch_at" ] || f "touch restore not time-stamped"
# fix136: right after a touch the next lower waits for the longer quiet (3 s here, 1 s
# otherwise), so reading comments under a video does not switch the panel every pause.
sleep 1.6
[ "$(cat "$T/peak")" = 165.0 ] || f "lowered again on the short quiet right after a touch"
# Quiet again: lowered again.
wait_for 60.0 200 || f "did not lower again after the touch went quiet"

# Playback stops: restored.
echo "state: SETUP" > "$T/snd/card0/pcm0p/sub0/status"
wait_for 165.0 150 || f "end of playback did not restore"
echo "state: RUNNING" > "$T/snd/card0/pcm0p/sub0/status"
wait_for 60.0 200 || f "did not lower when playback resumed"

# Someone else changes the peak while lowered: left as they set it.
echo "120.0" > "$T/peak"
sleep 2.5
[ "$(cat "$T/peak")" = 120.0 ] || f "a value set by someone else was overwritten"

# Switched off: stopped and restored.
_lp0="$(cat "$T/d/ltpo_video.pid" 2>/dev/null | tr -dc '0-9')"   # the watcher, before its pid file goes
echo ltpo_video=0 > "$T/mod/config/governor.conf"
sh "$V" reconcile
[ -f "$T/d/ltpo_video.lowered" ] && f "record kept after off"

# Crash/reboot mid-video: the record is repaired by reconcile without a watcher.
# "Without a watcher" is the premise (fix180): under a loaded regression host the stopped
# watcher could still be exiting - and restoring its own peak - when the record below was
# written, which failed this check once in a full run. Wait for it to be gone first.
# The pid file can be gone while the process is still restoring (fix184: the wait read the
# file and returned at once, and the check flaked again) - so wait on the pid taken before
# the switch-off as well.
_lw=0
while [ "$_lw" -lt 100 ] && _lp="$(cat "$T/d/ltpo_video.pid" 2>/dev/null | tr -dc '0-9')" && [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null; do
  sleep 0.1; _lw=$((_lw + 1))
done
while [ "$_lw" -lt 100 ] && [ -n "$_lp0" ] && kill -0 "$_lp0" 2>/dev/null; do
  sleep 0.1; _lw=$((_lw + 1))
done
printf 'orig=144.0\nset=60.0\ncontent=30\nsince=1\n' > "$T/d/ltpo_video.lowered"
echo "60.0" > "$T/peak"
sh "$V" reconcile
[ "$(cat "$T/peak")" = 144.0 ] || f "reconcile did not repair a lowered peak left by a crash"

# Cost: while not lowered, the SurfaceFlinger dump only happens after the touchscreen was
# quiet (scrolling a feed must not dump SF every 10 s on its compositing thread), and the
# peak setting is cached rather than read through `settings` on every touch.
_ql="$(grep -n '^    _quiet "$_dev" "$_qs"$' "$ROOT/runtime/asb_ltpo_video.sh" | head -1 | cut -d: -f1)"
_dl="$(grep -n '_sf_rates="$(_video_rates)"' "$ROOT/runtime/asb_ltpo_video.sh" | head -1 | cut -d: -f1)"
[ -n "$_ql" ] && [ -n "$_dl" ] && [ "$_ql" -lt "$_dl" ] || f "SurfaceFlinger is dumped before the touch-quiet check"
grep -q 'if \[ \$(( _tnow - _cur_ts )) -ge 30 \]; then _cur="\$(_get)"' "$ROOT/runtime/asb_ltpo_video.sh" || f "peak setting not cached"
grep -q 'LOWERED_RECHECK_S="${ASB_LTPO_RECHECK_S:-30}"' "$ROOT/runtime/asb_ltpo_video.sh" || f "lowered re-check interval not 30 s"
# fix136: never lower on a pick older than the quiet wait, nor with the audio already gone.
grep -q '{ \[ -n "$_sf_pick" \] && \[ "$_sf_ts" -lt "$_qt0" \]; }' "$ROOT/runtime/asb_ltpo_video.sh" || f "a stale SurfaceFlinger pick can still lower"
grep -q '^    _audio_live || continue$' "$ROOT/runtime/asb_ltpo_video.sh" || f "lowers without re-checking the audio"

grep -q 'asb_ltpo_video.sh" stop' "$ROOT/uninstall.sh" || f "uninstall does not stop the watcher"
grep -q 'asb_ltpo_video.sh" reconcile' "$ROOT/service.sh" || f "boot does not reconcile the watcher"

[ "$fail" = 0 ] && echo "PASS ltpo video runtime"
exit "$fail"
)

t_mmfeed_contract() (
# Multimedia-telemetry-off contract: the patch is device-local and fail-closed, the
# toggle defaults off, and every lifecycle owner (install, boot, late boot, uninstall,
# WebUI) reaches the one runtime script that owns the bind. Same shape as the
# force-LTPO contract, for the XML sibling.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_mmfeed_apply.sh"
WEB="$ROOT/webroot/index.html"
INSTALL="$ROOT/common/install.sh"
fail() { echo "FAIL mmfeed contract: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail 'runtime/asb_mmfeed_apply.sh missing'
sh -n "$SRC"

# --- WebUI wiring: card, default-off, system group, own icon, honest reboot label ---
grep -q "key:'mmfeed_off', type:'bool', def:'0'" "$WEB" || fail 'mmfeed_off card missing or default not off'
grep -q "mmfeed_off:'ui'" "$WEB" || fail 'mmfeed_off not in the System category group'
grep -q "mmfeed_off:'system'" "$WEB" || fail 'mmfeed_off missing category colour mapping'
grep -q "mmfeed_off:'mmfeed'" "$WEB" || fail 'mmfeed_off missing its icon mapping'
grep -q "mmfeed: '<path" "$WEB" || fail 'mmfeed icon glyph missing from TECH_ICON_PATHS'
grep -q "mmfeed_off:APPLY_REBOOT" "$WEB" || fail 'mmfeed_off must honestly label as reboot-to-apply'
grep -q "'mmfeed_off'," "$WEB" || fail 'mmfeed_off missing from SNAP_KEYS (export/restore)'
grep -q "runtime/asb_mmfeed_apply.sh apply" "$WEB" || fail 'cfgSet never calls the apply script'

# --- i18n: every shipped locale carries name + desc + the OEM-closed badge string ---
for f in "$ROOT"/webroot/i18n/*.json; do
  python3 -c "
import json,sys
d=json.load(open('$f'))
c=d.get('cfg',{}).get('mmfeed_off')
ok = c and c.get('name') and c.get('desc') and d.get('st_mmfeed_oem')
sys.exit(0 if ok else 1)
" || fail "mmfeed i18n missing in $(basename "$f")"
done

# --- install-time staging ---
grep -q 'asb_prepare_mmfeed_patch()' "$INSTALL" || fail 'install staging function missing'
grep -q '^asb_prepare_mmfeed_patch$' "$INSTALL" || fail 'staging function never called'
grep -q 'mmfeed_patched' "$INSTALL" || fail 'payload staging path missing'
grep -q 'mmfeed_bind_manifest.txt' "$INSTALL" || fail 'manifest write missing'
grep -q 'ASB_L_MMFEED_READY' "$ROOT/common/englishtext.sh" || fail 'English install string missing'
grep -q 'ASB_L_MMFEED_READY' "$ROOT/common/russiantext.sh" || fail 'Russian install string missing'
# The payload must NOT live under a magic-mountable module path: that would be always-on.
if grep -q 'MODPATH/my_product' "$INSTALL"; then
  fail 'payload staged under a magic-mount path - that bypasses the toggle'
fi

# --- lifecycle owners ---
grep -q 'asb_mmfeed_apply.sh" apply' "$ROOT/post-fs-data.sh" || fail 'post-fs-data never applies'
grep -q 'asb_mmfeed_apply.sh" apply' "$ROOT/service.sh" || fail 'service.sh never rebinds late'
grep -q 'asb_mmfeed_apply.sh" remove' "$ROOT/uninstall.sh" || fail 'uninstall never drops the bind'
grep -q 'mmfeed_bind_manifest.txt' "$ROOT/post-fs-data.sh" || fail 'bootloop fuse does not clear the mmfeed manifest'

# --- runtime guard pins: fail-closed allowlist, payload prefix, XML sanity ---
grep -q '/my_product/etc/Multimedia_Feedback_List.xml|' "$SRC" || fail 'target allowlist missing'
grep -q '"\$STATE_DIR/mmfeed_patched/"\*)' "$SRC" || fail 'payload prefix check missing'
grep -q '<isOpen>false</isOpen>' "$SRC" || fail 'isOpen sanity check missing'
grep -q '_cfg mmfeed_off)' "$SRC" || fail 'toggle gate missing'
grep -q 'nsenter -t 1 -m -- mount --bind' "$SRC" || fail 'global-namespace bind missing'
grep -q 'ASB_MMFEED_PROC_MOUNTS:-/proc/mounts' "$SRC" || fail 'mounts table not injectable for fixtures'

# --- runtime fixture: mocked mount/umount/nsenter, no real radio or mount ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mod/config" "$TMP/bin" "$TMP/state" "$TMP/live/my_product/etc"
printf 'name=AutoSystemBoost\n' > "$TMP/mod/module.prop"

# A stock feedback list with the collector OPEN, like the field device shipped.
cat > "$TMP/live/my_product/etc/Multimedia_Feedback_List.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" ?>
<filter-conf>
  <version>20240507</version>
  <isOpen>true</isOpen>
  <totalAudioLogs>20</totalAudioLogs>
  <filter-name>Multimedia_Feedback_List</filter-name>
</filter-conf>
EOF

cat > "$TMP/bin/mount" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ASB_MMFEED_LOG"
EOF
cat > "$TMP/bin/umount" <<'EOF'
#!/bin/sh
printf 'umount %s\n' "$*" >> "$ASB_MMFEED_LOG"
EOF
chmod 0755 "$TMP/bin/mount" "$TMP/bin/umount"
export PATH="$TMP/bin:$PATH"
export ASB_MMFEED_LOG="$TMP/mount.log"
export ASB_MMFEED_STATE_DIR="$TMP/state"
export ASB_MMFEED_PROC_MOUNTS="$TMP/mounts"
export ASB_MMFEED_LIVE_ROOT="$TMP/live"
: > "$TMP/mounts"

LIVE="$TMP/live/my_product/etc/Multimedia_Feedback_List.xml"
# The manifest/payload live under the injected state dir, so build the payload there.
mkdir -p "$TMP/state/mmfeed_patched$TMP/live/my_product/etc"
PAYLOAD="$TMP/state/mmfeed_patched${LIVE}"
sed 's|<isOpen>true</isOpen>|<isOpen>false</isOpen>|' "$LIVE" > "$PAYLOAD"
printf '%s|%s\n' "$LIVE" "$PAYLOAD" > "$TMP/state/mmfeed_bind_manifest.txt"

run() { MODDIR="$TMP/mod" sh "$SRC" "$@"; }

# Toggle off: nothing mounts, even with a valid manifest.
printf 'mmfeed_off=0\n' > "$TMP/mod/config/governor.conf"
run apply
[ ! -s "$ASB_MMFEED_LOG" ] || fail 'mounted while the toggle was off'

# Toggle on + valid manifest: bind happens and ownership is recorded.
printf 'mmfeed_off=1\n' > "$TMP/mod/config/governor.conf"
run apply
grep -q -- "--bind $PAYLOAD $LIVE" "$ASB_MMFEED_LOG" || fail 'valid manifest was not bound'
[ -f "$TMP/state/mmfeed_bind.active" ] || fail 'active marker not written'

# Toggle off with an active bind: it is removed (simulate the kernel view of the bind).
printf "%s %s ext4 rw 0 0\n" "$PAYLOAD" "$LIVE" > "$TMP/mounts"
printf 'mmfeed_off=0\n' > "$TMP/mod/config/governor.conf"
run apply
grep -q "umount $LIVE" "$ASB_MMFEED_LOG" || fail 'toggle-off did not unbind'
[ ! -f "$TMP/state/mmfeed_bind.active" ] || fail 'active marker not cleared'

# Fail-closed: a malformed manifest line must never mount.
printf '%s|%s|extra\n' "$LIVE" "$PAYLOAD" > "$TMP/state/mmfeed_bind_manifest.txt"
: > "$ASB_MMFEED_LOG"
printf 'mmfeed_off=1\n' > "$TMP/mod/config/governor.conf"
run apply
[ ! -s "$ASB_MMFEED_LOG" ] || fail 'malformed manifest was mounted'

# Fail-closed: a payload outside the state dir must never mount.
printf '%s|%s\n' "$LIVE" "/etc/passwd" > "$TMP/state/mmfeed_bind_manifest.txt"
: > "$ASB_MMFEED_LOG"
run apply
[ ! -s "$ASB_MMFEED_LOG" ] || fail 'out-of-bounds payload was mounted'

# Fail-closed: a target outside the allowlist must never mount.
printf '%s|%s\n' "/system/etc/hosts" "$PAYLOAD" > "$TMP/state/mmfeed_bind_manifest.txt"
: > "$ASB_MMFEED_LOG"
run apply
[ ! -s "$ASB_MMFEED_LOG" ] || fail 'out-of-allowlist target was mounted'

# Fail-closed: a payload that still says isOpen=true must never mount (it would be a
# no-op mount at best, and it means the patch step silently failed).
printf '%s|%s\n' "$LIVE" "$PAYLOAD" > "$TMP/state/mmfeed_bind_manifest.txt"
cp "$LIVE" "$PAYLOAD"
: > "$ASB_MMFEED_LOG"
run apply
[ ! -s "$ASB_MMFEED_LOG" ] || fail 'unpatched (isOpen=true) payload was mounted'

# remove: unbinds regardless of the toggle state.
sed 's|<isOpen>true</isOpen>|<isOpen>false</isOpen>|' "$LIVE" > "$PAYLOAD"
printf "%s %s ext4 rw 0 0\n" "$PAYLOAD" "$LIVE" > "$TMP/mounts"
: > "$TMP/state/mmfeed_bind.active"
: > "$ASB_MMFEED_LOG"
run remove
grep -q "umount $LIVE" "$ASB_MMFEED_LOG" || fail 'remove did not unbind'
[ ! -f "$TMP/state/mmfeed_bind.active" ] || fail 'remove kept the active marker'

# status vocabulary stays stable for the WebUI/diag readers.
printf 'mmfeed_off=0\n' > "$TMP/mod/config/governor.conf"
[ "$(run status)" = 'mmfeed_off' ] || fail 'status off vocabulary changed'

# --- executable install-patcher fixture: the REAL staging function against fixture
# files, with only the state root and live path rewritten to the sandbox ---
MF_DIR="$TMP/installer"
mkdir -p "$MF_DIR/asb" "$MF_DIR/live"
sed -n '/^asb_prepare_mmfeed_patch()/,/^}/p' "$INSTALL" |
  sed "s|/data/adb/asb|$MF_DIR/asb|g; s|/my_product/etc/Multimedia_Feedback_List.xml|$MF_DIR/live/Multimedia_Feedback_List.xml|" \
  > "$MF_DIR/func.sh"
mf_patch() { # $1 = fixture file (or 'MISSING'); prints the resulting mmfeed_state
  rm -rf "$MF_DIR/asb"; mkdir -p "$MF_DIR/asb"
  if [ "$1" != 'MISSING' ]; then cp "$1" "$MF_DIR/live/Multimedia_Feedback_List.xml";
  else rm -f "$MF_DIR/live/Multimedia_Feedback_List.xml"; fi
  ( ui_print() { :; }; . "$MF_DIR/func.sh"; asb_prepare_mmfeed_patch >/dev/null )
  cat "$MF_DIR/asb/mmfeed_state" 2>/dev/null || echo missing
}
MF_PAY="$MF_DIR/asb/mmfeed_patched$MF_DIR/live/Multimedia_Feedback_List.xml"

# OP15-style: collector open -> ready, payload closed, root element intact.
cat > "$MF_DIR/caseA.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" ?>
<filter-conf>
  <version>20240507</version>
  <isOpen>true</isOpen>
  <event id="10001" diagid="090001" ison="11" desc="audio adsp crash"/>
</filter-conf>
XML
[ "$(mf_patch "$MF_DIR/caseA.xml")" = 'ready' ] || fail 'open collector not patched'
grep -q '<isOpen>false</isOpen>' "$MF_PAY" || fail 'payload did not close the collector'
grep -q '</filter-conf>' "$MF_PAY" || fail 'payload lost the root element'
grep -q 'id="10001"' "$MF_PAY" || fail 'payload lost the event table'

# Already closed -> honestly "already", no manifest.
sed 's|<isOpen>true</isOpen>|<isOpen>false</isOpen>|' "$MF_DIR/caseA.xml" > "$MF_DIR/caseB.xml"
[ "$(mf_patch "$MF_DIR/caseB.xml")" = 'already' ] || fail 'closed list not reported as already'
[ ! -f "$MF_DIR/asb/mmfeed_bind_manifest.txt" ] || fail 'closed list still wrote a manifest'

# No isOpen tag at all -> unknown format, fail-closed "invalid".
cat > "$MF_DIR/caseC.xml" <<'XML'
<filter-conf><version>1</version></filter-conf>
XML
[ "$(mf_patch "$MF_DIR/caseC.xml")" = 'invalid' ] || fail 'formatless file not reported invalid'
[ ! -f "$MF_DIR/asb/mmfeed_bind_manifest.txt" ] || fail 'invalid file still wrote a manifest'

# No file at all -> "unsupported".
[ "$(mf_patch MISSING)" = 'unsupported' ] || fail 'missing file not reported unsupported'

echo 'PASS: multimedia-telemetry contract'
)

t_mobile_ifs_runtime() (
# Runtime (fix122): the governor counts mobile data on every rmnet_data* and ccmni* link,
# not a fixed rmnet_data0..2 + rmnet_ipa0 list - an OP15 moved its internet PDN to
# rmnet_data3 overnight and the radio went invisible; MediaTek names them ccmni*.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
M="$ROOT/src/asb_metrics.h"
fail() { echo "FAIL mobile ifs: $*" >&2; exit 1; }
grep -q '"rmnet_data0", "rmnet_data1", "rmnet_data2", "rmnet_ipa0"' "$M" && fail "fixed interface list still in use"
grep -q 'if (m->rmnet_rx_bps < 0) m->rmnet_rx_bps = 0;' "$M" || fail "a vanished link can make the rate negative"
CC=""; for c in gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS mobile ifs (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk() { mkdir -p "$T/net/$1/statistics"; echo "$2" > "$T/net/$1/statistics/rx_bytes"; echo "$3" > "$T/net/$1/statistics/tx_bytes"; }
mk rmnet_data0 100 200
mk rmnet_data3 5000000 70000
mk rmnet_ipa0 900000 900000          # transport underneath: must not be added
mk ccmni2 3000 4000
mk wlan0 99999999 99999999
mk r_rmnet_data0 7777 7777           # IWLAN reverse link: not a cellular data link
{
  cat <<X
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dirent.h>
#define ASB_NET_CLASS_DIR "$T/net"
static long sysfs_read_long(const char *path, long def) {
    FILE *f = fopen(path, "r"); long v = def;
    if (!f) return def;
    if (fscanf(f, "%ld", &v) != 1) v = def;
    fclose(f); return v;
}
X
  awk '/^#ifndef ASB_NET_CLASS_DIR/{on=1} on{print} on&&/^static long rmnet_read_total/{f=1} f&&/^}/{exit}' "$M"
  cat <<'X'
int main(void) {
    long rx = rmnet_read_total("rx_bytes"), tx = rmnet_read_total("tx_bytes");
    if (rx != 100 + 5000000 + 3000) { printf("rx %ld\n", rx); return 1; }
    if (tx != 200 + 70000 + 4000)   { printf("tx %ld\n", tx); return 1; }
    return 0;
}
X
} > "$T/t.c"
"$CC" -O2 -Wall -Werror -o "$T/t" "$T/t.c" || fail "fixture did not compile"
"$T/t" || fail "wrong interfaces counted"
echo "PASS mobile data counted on every rmnet_data*/ccmni* link (not ipa0, not wlan)"
)

t_net_congctl_probe_runtime() (
# Runtime (fix136): per-route congctl is decided on evidence, not on one probe.
#
# OP15 asbdiag on the fix133 build: "[N/A] net_congestion_wifi (no per-route congctl on this
# kernel)" above "link rmnet_data2: ... congctl=bbr" and "per-route congctl: SUPPORTED". The
# probe tried `ip route change ... congctl` on ONE default route; when that one route refused
# (being torn down, an attribute change will not take back), the whole kernel was filed as
# unsupported and the Wi-Fi choice was reported as impossible.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/runtime/asb_net_apply.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL net congctl probe: $*" >&2; exit 1; }
{ sed -n '/^_defaults() {/p' "$SRC"
  sed -n '/^_active_dev() {/,/^}/p' "$SRC"
  sed -n '/^_congctl_ok=""$/,/^}$/p' "$SRC"; } > "$TMP/probe.sh"
grep -q '_probe_congctl()' "$TMP/probe.sh" || fail "probe not extracted"
cat > "$TMP/ip" <<'S'
#!/bin/sh
case "$*" in
  "route show table all") cat "$ROUTES" ;;
  "route get 1.1.1.1") echo "1.1.1.1 via 100.65.185.32 dev rmnet_data2 table rmnet_data2 src 100.65.185.31 uid 0" ;;
  "route change "*) echo "$*" >> "$CHG"
                    case "$*" in *"table good"*) exit 0 ;; *) exit 2 ;; esac ;;
esac
S
chmod +x "$TMP/ip"
echo bbr > "$TMP/cc"
probe() {   # prints the verdict
  ( set +e; ASB_IP="$TMP/ip"; ROUTES="$TMP/routes"; CHG="$TMP/chg"; export ROUTES CHG
    . "$TMP/probe.sh"
    # the probe reads the global algorithm from /proc; point it at a fixture
    cat() { if [ "$1" = /proc/sys/net/ipv4/tcp_congestion_control ]; then command cat "$TMP/cc"; else command cat "$@"; fi; }
    _probe_congctl; printf '%s\n' "$_congctl_ok" )
}

# 1. A default route already carrying congctl: supported, nothing rewritten.
printf '%s\n' 'default via 100.65.185.32 dev rmnet_data2 table rmnet_data2 proto static congctl bbr' \
  'default via 192.168.1.1 dev wlan0 table wlan0 proto static' > "$TMP/routes"
: > "$TMP/chg"
[ "$(probe)" = 1 ] || fail "existing congctl not taken as evidence"
[ -s "$TMP/chg" ] && fail "routes rewritten although the evidence was there"

# 2. The active link's route refuses, another one takes it: supported.
printf '%s\n' 'default via 100.65.185.32 dev rmnet_data2 table bad proto static' \
  'default via 192.168.1.1 dev wlan0 table good proto static' > "$TMP/routes"
: > "$TMP/chg"
[ "$(probe)" = 1 ] || fail "one refusing route filed the kernel as unsupported"
head -1 "$TMP/chg" | grep -q 'dev rmnet_data2' || fail "active link not tried first"

# 3. Every candidate refuses: unsupported, after at most three tries.
printf '%s\n' 'default via 1.1.1.1 dev rmnet_data2 table bad1' 'default via 1.1.1.2 dev rmnet_data1 table bad2' \
  'default via 1.1.1.3 dev wlan0 table bad3' 'default via 1.1.1.4 dev rmnet_data3 table bad4' > "$TMP/routes"
: > "$TMP/chg"
[ "$(probe)" = 0 ] || fail "all refusing routes not filed as unsupported"
[ "$(grep -c '' "$TMP/chg")" -le 3 ] || fail "more than three routes rewritten by the probe"

# 4. No route at all: unknown (fix131), never unsupported.
: > "$TMP/routes"
[ "$(probe)" = unknown ] || fail "no route was not unknown"

# 5. A stale "unsupported" on a link that is down becomes pending once per-route works.
grep -q "case \"\$_pv\" in ''|\*=unsupported) _out=\"\$_out cc\[\$_pk\]=\$_pw-pending\" ;; esac" "$SRC" || fail "stale unsupported verdict never cleared"
grep -qF 'cc\[wifi*-pending*)' "$SRC" || fail "mapper has no pending for Wi-Fi congestion"
w="$(grep -nF 'cc\[wifi*-pending*)' "$SRC" | cut -d: -f1)"; g="$(grep -nF 'cc\[wifi*)' "$SRC" | head -1 | cut -d: -f1)"
[ "$w" -lt "$g" ] || fail "pending line after the generic ok line"
grep -q 'filed as unsupported by an apply whose probe failed' "$ROOT/tools/asb_diag.sh" || fail "asbdiag still calls it N/A against the evidence"
echo "PASS net congctl probe: evidence first, three candidates, unknown without a route, stale verdict cleared"
)

t_net_txqueue_runtime() (
# Runtime (fix151): "transmit queue" really sets the Wi-Fi queue, and gives it back.
#
# Five asbdiag reports with net_txqueue=short or shorter, one of them on Wi-Fi: wlan0=1024
# every time. The script ran `ip link set dev wlan0 txqueuelen N` with whatever `ip` came
# first on PATH; the root manager's BusyBox applet knows the keyword as "qlen" only, the error
# went to /dev/null and the queue never moved. The REAL script now writes tx_queue_len in
# sysfs (Android's iproute2 as the fallback); here it runs on a fake sysfs with an `ip` that
# refuses the keyword like BusyBox does.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_net_offload.sh"
fail() { echo "FAIL net txqueue: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mod/config" "$T/bin"
for i in wlan0 rmnet_data0 lo; do
  mkdir -p "$T/net/$i/queues/rx-0"
  echo 0 > "$T/net/$i/queues/rx-0/rps_cpus"
done
echo 1024 > "$T/net/wlan0/tx_queue_len"; echo 1000 > "$T/net/rmnet_data0/tx_queue_len"; echo 1000 > "$T/net/lo/tx_queue_len"
cat > "$T/bin/ip" <<'X'
#!/bin/sh
case "$*" in *txqueuelen*) echo "ip: invalid argument 'txqueuelen'" >&2; exit 1 ;; esac
exit 0
X
chmod +x "$T/bin/ip"
run() {
  printf 'net_rps=stock\nnet_txqueue=%s\n' "$1" > "$T/mod/config/governor.conf"
  PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_NET_SYSFS="$T/net" ASB_NET_OFFLOAD_STATE="$T/prev" sh "$SRC" >/dev/null 2>&1 || true
}
run short
[ "$(cat "$T/net/wlan0/tx_queue_len")" = 256 ] || fail "Wi-Fi queue not shortened: $(cat "$T/net/wlan0/tx_queue_len")"
[ "$(cat "$T/net/rmnet_data0/tx_queue_len")" = 1000 ] || fail "a mobile link was touched"
[ "$(cat "$T/net/lo/tx_queue_len")" = 1000 ] || fail "loopback was touched"
grep -qx 'TXQ:wlan0=1024' "$T/prev" || fail "the device's own value was not recorded"
run shorter
[ "$(cat "$T/net/wlan0/tx_queue_len")" = 128 ] || fail "shorter not applied"
run stock
[ "$(cat "$T/net/wlan0/tx_queue_len")" = 1024 ] || fail "stock did not give the queue back: $(cat "$T/net/wlan0/tx_queue_len")"
grep -qF '"$_tb" link set dev "$1" txqueuelen "$2"' "$SRC" || fail "no iproute2 fallback"
grep -q '^  for _tb in /system/bin/ip /system/xbin/ip /vendor/bin/ip; do$' "$SRC" || fail "fallback takes ip from PATH"
echo "PASS net txqueue: Wi-Fi queue set through sysfs whatever ip is on PATH, mobile links untouched, stock restores"
)

t_net_verdict_contract() (
# Congestion-verdict honesty contract: on a kernel without per-route congctl, a link kind
# whose request is satisfied by the GLOBAL knob must report ok, a kind asking for a
# different algorithm must report unsupported - and the verdict mapper must file both
# under the right WebUI key. Field case: OP15 day log showed net_congestion_mobile
# "not_applied" forever while mobile traffic genuinely ran the globally-applied bbr.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_net_apply.sh"
fail() { echo "FAIL net verdict contract: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail 'runtime/asb_net_apply.sh missing'
sh -n "$SRC"

# --- source pins: the emission sites and the mapper lines exist ---
grep -qF 'cc[$_k2]=$_cc(global)' "$SRC" || fail 'global-cover per-kind ok token missing'
grep -qF 'cc[$_k2]=$_k2want-unsupported' "$SRC" || fail 'per-kind unsupported token missing'
grep -qF 'cc[$_akind:$_act]=$_want(global-fallback)' "$SRC" || fail 'fallback token must name the kind'
grep -qF 'cc\[mobile*-unsupported*)' "$SRC" || fail 'mapper: mobile unsupported line missing'
grep -qF 'cc\[wifi*-unsupported*)' "$SRC" || fail 'mapper: wifi unsupported line missing'
# The old anonymous "active" token must not come back: the mapper cannot key on it.
if grep -qF 'cc[active:' "$SRC"; then
  fail 'anonymous cc[active:...] token is back - the badge cannot map it'
fi

# --- ordering pin: specific unsupported/unavailable lines precede the generic ok line,
# or every token would be swallowed by the wildcard first ---
for kind in wifi mobile; do
  u="$(grep -nF "cc\[${kind}*-unsupported*)" "$SRC" | head -1 | cut -d: -f1)"
  g="$(grep -nF "cc\[${kind}*)" "$SRC" | head -1 | cut -d: -f1)"
  [ -n "$u" ] || fail "mapper: $kind unsupported line missing"
  [ -n "$g" ] || fail "mapper: $kind generic line missing"
  [ "$u" -lt "$g" ] || fail "mapper: $kind unsupported line must precede the generic ok line"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- executable pin 1: the REAL emission loop, with only _cfg stubbed ---
sed -n '/# Per-link verdicts when the kernel cannot do per-route congctl/,/^          fi$/p' "$SRC" > "$TMP/emit.sh"
[ -s "$TMP/emit.sh" ] || fail 'emission block not found'
grep -qF 'cc[$_k2]=' "$TMP/emit.sh" || fail 'emission block extracted incomplete'

emit() { # $1 = applied global cc; $2 = cfg net_congestion_wifi; $3 = cfg net_congestion_mobile
  W="$2"; M="$3"
  ( _cc="$1"; _congctl_ok="${4:-0}"; _out="congestion=$1"
    _cfg() { case "$1" in
               net_congestion_wifi)   printf '%s' "$W" ;;
               net_congestion_mobile) printf '%s' "$M" ;;
             esac; }
    . "$TMP/emit.sh"
    printf '%s\n' "$_out" )
}

[ "$(emit bbr bbr bbr)" = 'congestion=bbr cc[wifi]=bbr(global) cc[mobile]=bbr(global)' ] \
  || fail 'matching per-link requests not credited to the global knob'
[ "$(emit bbr auto cubic)" = 'congestion=bbr cc[mobile]=cubic-unsupported' ] \
  || fail 'distinct per-link request not flagged unsupported (and auto must stay silent)'
[ "$(emit bbr '' '')" = 'congestion=bbr' ] \
  || fail 'unset per-link keys must not emit tokens'
# fix131: no route to probe = capability unknown - no "unsupported" filed for it.
[ "$(emit bbr cubic cubic unknown)" = 'congestion=bbr' ] \
  || fail 'an unprobed kernel was filed as having no per-route congctl'
grep -q '{ _congctl_ok=unknown; return 0; }' "$SRC" || fail 'probe without a route is not "unknown"'

# --- executable pin 2: the REAL verdict mapper against synthetic result lines ---
sed -n '/^  for _tok in \$_out; do$/,/^  done$/p' "$SRC" > "$TMP/map.sh"
[ -s "$TMP/map.sh" ] || fail 'verdict mapper block not found'
grep -q 'net_congestion_mobile' "$TMP/map.sh" || fail 'verdict mapper extracted incomplete'

map_verdicts() { ( _out="$1"; . "$TMP/map.sh" ); }

v="$(map_verdicts 'congestion=bbr cc[mobile]=bbr(global)')"
echo "$v" | grep -qx 'net_congestion=ok' || fail 'global congestion not ok'
echo "$v" | grep -qx 'net_congestion_mobile=ok' || fail 'global-covered mobile not ok'

v="$(map_verdicts 'congestion=bbr cc[mobile]=cubic-unsupported')"
echo "$v" | grep -qx 'net_congestion_mobile=unsupported' || fail 'unsupported mobile not mapped'

v="$(map_verdicts 'cc[mobile:rmnet_data3]=bbr(global-fallback)')"
echo "$v" | grep -qx 'net_congestion_mobile=ok' || fail 'fallback-served mobile not ok'

v="$(map_verdicts 'cc[wifi:wlan0]=bbr(global)')"
echo "$v" | grep -qx 'net_congestion_wifi=ok' || fail 'global-covered wifi not ok'

v="$(map_verdicts 'cc[wifi]=cubic-unavailable')"
echo "$v" | grep -qx 'net_congestion_wifi=unavailable' || fail 'unavailable wifi regressed'

v="$(map_verdicts 'qdisc[mobile:rmnet_data3]=fq_codel-noqueue-unsupported')"
echo "$v" | grep -qx 'net_qdisc_mobile=unsupported' || fail 'noqueue mobile not unsupported'

# Regression: the pre-V65-40 vocabulary must keep its meaning.
v="$(map_verdicts 'qdisc[mobile:rmnet_data3]=fq_codel-not-applied')"
echo "$v" | grep -qx 'net_qdisc_mobile=failed' || fail 'not-applied mobile regressed'
v="$(map_verdicts 'congestion=FAILED')"
echo "$v" | grep -qx 'net_congestion=failed' || fail 'global FAILED regressed'
v="$(map_verdicts 'qdisc=fq_codel-unavailable')"
echo "$v" | grep -qx 'net_qdisc=unavailable' || fail 'qdisc unavailable not mapped'

# --- tc binary resolution pins (CPH2745 field log: boot PATH gave a limited applet
# that rejected the qdisc grammar while /system/bin/tc worked) ---
grep -qF '_ASB_TC="${ASB_TC:-}"' "$SRC" || fail 'tc not injectable for fixtures'
grep -qF 'for _tcc in /system/bin/tc "$(command -v tc 2>/dev/null)"; do' "$SRC" \
  || fail 'tc resolution must prefer /system/bin/tc over PATH'
grep -qF '"$_ASB_TC" qdisc replace' "$SRC" || fail 'qdisc writes not using the resolved tc'
grep -qF '"$_ASB_TC" qdisc show' "$SRC" || fail 'qdisc reads not using the resolved tc'
grep -qF 'if [ -n "$_ASB_TC" ]; then' "$SRC" || fail 'qdisc section not gated on the resolved tc'
grep -qF 'qdisc=$_qd-unavailable' "$SRC" || fail 'missing-tc verdict missing'
grep -qF 'tc_binary_limited' "$SRC" || fail 'limited-tc classifier missing'
grep -qF 'qdisc=*-unavailable)' "$SRC" || fail 'mapper: qdisc unavailable line missing'
if grep -v '^[[:space:]]*#' "$SRC" | grep -qE '(^|[^"A-Za-z_])tc qdisc (replace|show)'; then
  fail 'a bare tc call survived - every qdisc call must use the resolved binary'
fi
# profile_core.sh has the same boot-context exposure and must resolve the same way.
PC="$ROOT/runtime/profile_core.sh"
grep -qF '_asb_tc="${ASB_TC:-}"' "$PC" || fail 'profile_core tc not injectable'
grep -qF '"$_asb_tc" qdisc replace' "$PC" || fail 'profile_core not using the resolved tc'

# Executable: the REAL tc selection block honours the fixture injector.
n="$(grep -nF '_ASB_TC="${ASB_TC:-}"' "$SRC" | head -1 | cut -d: -f1)"
[ -n "$n" ] || fail 'cannot locate tc selection block'
sed -n "${n},$((n + 6))p" "$SRC" > "$TMP/tcsel.sh"
grep -q '^fi$' "$TMP/tcsel.sh" || fail 'tc selection block extracted incomplete'
[ "$(ASB_TC=/bin/echo sh -c '. "$1"; printf %s "$_ASB_TC"' _ "$TMP/tcsel.sh")" = '/bin/echo' ] \
  || fail 'tc selection ignores the ASB_TC injector'

# --- verdict dedupe pins: one line per key, worst wins ---
grep -qF '# One line per key.' "$SRC" || fail 'verdict dedupe block missing'
sed -n '/# One line per key\./,/|| rm -f "\$_res_new\.d"/p' "$SRC" > "$TMP/dedupe.sh"
grep -q 'awk' "$TMP/dedupe.sh" || fail 'dedupe block extracted incomplete'
cat > "$TMP/res_in" <<'EOF'
net_congestion=ok
net_qdisc_mobile=failed
net_qdisc_mobile=ok
net_qdisc_mobile=failed
net_qdisc=ok
net_handover_active=off
EOF
( _res_new="$TMP/res_in"; . "$TMP/dedupe.sh"; cat "$TMP/res_in" ) > "$TMP/res_out"
cat > "$TMP/res_want" <<'EOF'
net_congestion=ok
net_qdisc_mobile=failed
net_qdisc=ok
net_handover_active=off
EOF
cmp -s "$TMP/res_want" "$TMP/res_out" || fail 'dedupe must keep one line per key, worst first-seen order'

# --- diag pins: a qdisc FAIL must SHOW the raw tc line, not point at a file the
# report does not contain; and the congestion N/A label must name the right mechanism ---
DIAG="$ROOT/system/bin/asbdiag"
grep -qF '_qraw="$(grep -m1 "want=${_nw} "' "$DIAG" || fail 'diag does not capture the raw qdisc failure line'
grep -qF 'qdisc_failures.log: $_qraw' "$DIAG" || fail 'diag does not print the raw qdisc failure line'
grep -qF 'net_congestion_*)' "$DIAG" || fail 'diag N/A branch does not split congestion from qdisc'
grep -qF 'no per-route congctl on this kernel' "$DIAG" || fail 'congestion N/A wording missing'
grep -qF 'tc_binary_limited)' "$DIAG" || fail 'diag limited-tc branch missing'
grep -qF 'no working tc binary found' "$DIAG" || fail 'diag qdisc-unavailable wording missing'
grep -qF 'tc binary:' "$DIAG" || fail 'diag tc identity line missing'
cmp -s "$DIAG" "$ROOT/tools/asb_diag.sh" || fail 'asbdiag and tools/asb_diag.sh diverged'

# Executable fixture: the REAL _qraw/_qw extraction against a synthetic failure log.
n="$(grep -n '_qraw=' "$DIAG" | head -1 | cut -d: -f1)"
[ -n "$n" ] || fail 'cannot locate _qraw extraction in diag'
sed -n "${n},$((n + 1))p" "$DIAG" | sed "s|/data/adb/asb|$TMP/asb|g" > "$TMP/raw.sh"
grep -q '_qraw=' "$TMP/raw.sh" && grep -q '_qw=' "$TMP/raw.sh" || fail 'raw extraction block incomplete'
mkdir -p "$TMP/asb"
cat > "$TMP/asb/qdisc_failures.log" <<'EOF'
2026-09-22 11:02:26 if=rmnet_ipa0 want=fq_codel why=tc_error err=RTNETLINK answers: Invalid argument
2026-09-22 11:02:27 if=wlan0 want=fq_codel why=root_qdisc_owned err=RTNETLINK answers: Device or resource busy
EOF
( _nw=fq_codel; . "$TMP/raw.sh"; printf '%s\n%s\n' "$_qraw" "$_qw" ) > "$TMP/raw.out"
head -1 "$TMP/raw.out" | grep -q 'if=rmnet_ipa0 .*why=tc_error' || fail 'raw line not captured verbatim'
[ "$(sed -n 2p "$TMP/raw.out")" = 'tc_error' ] || fail 'why not derived from the raw line'

echo 'net verdict contract: OK'
)

t_network_handover_contract() (
# Contract for explicit Wi-Fi -> mobile handover and the independent cellular/radio master.
# It locks the safety boundary ASB owns: profiles never imply a modem policy, LPM is the sole
# mobile_data_always_on writer, and save/night always outrank fast handover.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing $2 in ${1#$ROOT/}"; }

for f in "$ROOT/config/governor.conf" "$ROOT/config/governor.conf.shipped"; do
  need "$f" 'radio_policy_enable=0'
  need "$f" 'net_wifi_leave=off'
  need "$f" 'net_wifi_leave=off'
done

LPM="$ROOT/runtime/asb_lpm.sh"
FALLBACK="$ROOT/runtime/asb_wifi_fallback.sh"
GOV="$ROOT/src/asb_governor.c"
need "$LPM" '_radio_policy_enabled() { [ "$(_cfg radio_policy_enable)" = "1" ]; }'
need "$LPM" 'if ! _feat_on LPM || ! _radio_policy_enabled; then'
need "$LPM" 'if [ "$MODE" = "refresh" ]; then'
need "$LPM" 'case "$_saved_mode" in fast|normal|save|night)'
need "$LPM" 'case "$(_cfg net_wifi_leave)" in'
need "$LPM" 'case "$(_cfg net_wifi_leave)" in'
need "$LPM" 'HANDOVER_ACTIVE=1; HANDOVER_FAST=1'
need "$LPM" 'STATE_TAG="${MODE}|handover=${HANDOVER_FAST}|active=${HANDOVER_ACTIVE}"'
need "$LPM" '_sset mobile_data_always_on 0'
need "$LPM" '_sset mobile_data_always_on 1'
need "$FALLBACK" '_radio_policy_enabled() { [ "$(_cfg radio_policy_enable)" = 1 ]; }'
# fix134: every rung runs the leave watcher, cellular master or not.
need "$FALLBACK" '_enabled() { case "$(_cfg net_wifi_leave)" in weak|unusable|aggressive) return 0 ;; esac; return 1; }'
need "$FALLBACK" '_uses_validation() { case "$(_cfg net_wifi_leave)" in unusable|aggressive) return 0 ;; esac; return 1; }'
need "$FALLBACK" '_uses_validation || return 0'
need "$FALLBACK" 'RELEASE_MAX_S=300'
need "$FALLBACK" '_screen_on || return 0'
need "$FALLBACK" '_mobile_allowed || return 0'
need "$FALLBACK" '_wifi_default || return 0'
need "$FALLBACK" '_wifi_unvalidated || return 0'
need "$FALLBACK" 'RELEASE_S=30'
need "$FALLBACK" 'COOLDOWN_S=150'
need "$FALLBACK" '_valid_seconds "$_raw_interval" 1 120'
need "$FALLBACK" '_valid_seconds "$_raw_release" 1 120'
need "$FALLBACK" '_valid_seconds "$_raw_cooldown" 1 3600'

# Smart's economy bias must not re-enable a radio policy by itself. Confirmed games/camera can
# request fast only after the explicit master authorises LPM.
need "$GOV" 'int smart_battery_lean ='
need "$GOV" 'g_asb_cfg.smart_battery_bias >= 400'
need "$GOV" '!metrics.misc.camera_active && !metrics.bat.charging'
need "$GOV" 'g_smart_rt.app_hint < ASB_APP_GAMING'
need "$GOV" 'fsm.state == ASB_STATE_GAMING ||'
need "$GOV" '(fsm.state == ASB_STATE_HEAVY && !smart_battery_lean)'
need "$GOV" 'honours net_handover_fast inside asb_lpm.sh'

# No second helper may write mobile_data_always_on. The only intended owner is LPM; normal/fast/
# save/night capture and restore a single Android baseline.
writers="$(grep -RIl 'mobile_data_always_on' "$ROOT/runtime" --include='*.sh' | sort)"
printf '%s\n' "$writers" | grep -qx "$LPM" || fail 'mobile_data_always_on has a writer outside asb_lpm.sh'

WEB="$ROOT/webroot/index.html"
need "$WEB" "key:'radio_policy_enable'"
need "$WEB" "key:'net_wifi_leave'"
need "$WEB" "key:'net_wifi_leave'"
need "$WEB" "radio_policy_enable:'cellular_controls'"
need "$WEB" "net_wifi_leave:'wifileave'"
need "$WEB" "key === 'radio_policy_enable' || key === 'net_wifi_leave'"
need "$WEB" "'radio_policy_enable',"
need "$WEB" 'radio_policy_enable:APPLY_LIVE'
need "$WEB" '/runtime/asb_lpm.sh refresh'
need "$WEB" "raw.split('|')[0]"
need "$ROOT/common/install.sh" 'wifi_scan_throttle radio_policy_enable net_wifi_leave haptic_touch_strength'
need "$ROOT/runtime/asb_net_apply.sh" 'radio_policy=off wifi_fallback=$_wf'
need "$ROOT/runtime/asb_net_apply.sh" '_abw_prev=/data/adb/asb/avoid_bad_wifi.prev'
need "$ROOT/uninstall.sh" 'settings delete global network_avoid_bad_wifi'
need "$ROOT/service.sh" '[ -f /data/adb/asb/avoid_bad_wifi.prev ] && _asb_net_any=1'
need "$ROOT/action.sh" 'cellular/radio controls: off · profiles leave Android radio policy untouched'
need "$ROOT/tools/asb_diag.sh" 'profiles leave Android mobile-data context and TCP keepalives untouched'

# Every user-facing card/warning must be present in all 13 shipped languages; English fallback is
# not an acceptable substitute for a radio policy that may cost mobile data or battery.
_locale_n=0
for _locale in "$ROOT"/webroot/i18n/*.json; do
  _locale_n=$((_locale_n + 1))
  need "$_locale" '"radio_policy_enable"'
  need "$_locale" '"wb_radio_policy"'
  need "$_locale" '"net_wifi_leave"'
  need "$_locale" '"theme_dark"'
  need "$_locale" '"theme_light"'
  need "$_locale" '"name"'
  need "$_locale" '"desc"'
done
[ "$_locale_n" -eq 13 ] || fail "expected 13 locale files, got $_locale_n"

# Run LPM in a private module/state tree. The no-SIM/master-off case must not even establish a
# baseline or write a radio/global TCP setting when a profile changes.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/mod/runtime" "$TMP/mod/config" "$TMP/mod/profiles" "$TMP/bin" "$TMP/state"
sed -e "s#/data/adb/asb#$TMP/state#g" -e "s#/dev/.asb#$TMP/state#g" \
  "$LPM" > "$TMP/mod/runtime/asb_lpm.sh"
cat > "$TMP/mod/features.conf" <<'EOF'
LPM=1
EOF
cat > "$TMP/mod/config/governor.conf" <<'EOF'
radio_policy_enable=0
net_wifi_leave=off
net_wifi_leave=off
EOF
cat > "$TMP/mod/profiles/balanced.sh" <<'EOF'
NET_TCP_KEEPIDLE=300
EOF
cat > "$TMP/bin/settings" <<'EOF'
#!/bin/sh
case "$1" in
  get) echo 0 ;;
  put) printf '%s %s %s\n' "$1" "$3" "$4" >> "$ASB_HANDOVER_LOG" ;;
esac
EOF
chmod 0755 "$TMP/bin/settings"
export PATH="$TMP/bin:$PATH" ASB_HANDOVER_LOG="$TMP/settings.log"
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" normal
[ ! -e "$TMP/settings.log" ] || fail 'radio master OFF wrote mobile_data_always_on after profile transition'
[ ! -e "$TMP/state/lpm_base" ] || fail 'radio master OFF captured a modem baseline'

# Explicit master ON permits current LPM policy. Fast may warm context while awake; save wins.
printf 'radio_policy_enable=1\nnet_wifi_leave=weak\n' > "$TMP/mod/config/governor.conf"
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" normal
tail -n 1 "$TMP/settings.log" | grep -qx 'put mobile_data_always_on 1' || fail 'explicit radio master + fast handover did not warm mobile context'
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" save
tail -n 1 "$TMP/settings.log" | grep -qx 'put mobile_data_always_on 0' || fail 'save mode did not override fast handover'

# Turning the independent master OFF restores original Android baseline (mocked 0), removes LPM
# state and makes a later profile transition a no-op rather than a new implicit radio write.
printf 'radio_policy_enable=0\nnet_wifi_leave=1\nnet_wifi_leave=1\n' > "$TMP/mod/config/governor.conf"
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" refresh
tail -n 1 "$TMP/settings.log" | grep -qx 'put mobile_data_always_on 0' || fail 'radio master OFF did not restore captured Android baseline'
[ ! -e "$TMP/state/lpm_base" ] || fail 'radio master OFF retained LPM baseline state'
[ ! -e "$TMP/state/lpm_mode" ] || fail 'radio master OFF retained LPM mode state'
lines_before="$(wc -l < "$TMP/settings.log")"
MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_lpm.sh" normal
[ "$(wc -l < "$TMP/settings.log")" -eq "$lines_before" ] || fail 'profile transition wrote radio setting with master OFF'

echo 'PASS: network handover and independent radio policy contract'
)

t_phantom_stock_restore_runtime() (
# Runtime: phantom_procs strict/relaxed -> stock puts the original value back.
# The stock branch read profile_runtime_baseline.v1, but asb_settings_put records in
# baseline.txt, so the value was never found and the change was one-way.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL phantom restore: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/mod/runtime"
cp "$ROOT/runtime/asb_baseline.sh" "$T/mod/runtime/"
cat > "$T/bin/settings" <<'S'
#!/bin/sh
F="$SETF"
case "$1" in
  get) v="$(grep -m1 "^$2|$3|" "$F" 2>/dev/null | cut -d'|' -f3)"; echo "${v:-null}" ;;
  put) grep -v "^$2|$3|" "$F" > "$F.n" 2>/dev/null; echo "$2|$3|$4" >> "$F.n"; mv "$F.n" "$F" ;;
  delete) grep -v "^$2|$3|" "$F" > "$F.n" 2>/dev/null; mv "$F.n" "$F" ;;
esac
S
chmod +x "$T/bin/settings"
run() {
  echo "phantom_procs=$1" > "$T/mod/config/governor.conf"
  SETF="$T/set" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_BASELINE="$T/baseline.txt" \
    ASB_PROFILE_BASELINE="$T/pb" ASB_LEDGER="$T/ledger" sh "$ROOT/runtime/asb_system_tweaks.sh" >/dev/null 2>&1
}
echo "global|settings_enable_monitor_phantom_procs|true" > "$T/set"
run relaxed
grep -q '^global|settings_enable_monitor_phantom_procs|false$' "$T/set" || f "relaxed did not write false"
run stock
grep -q '^global|settings_enable_monitor_phantom_procs|true$' "$T/set" || f "stock did not restore the original value: $(cat "$T/set")"
# Unset before ASB -> stock deletes it again.
: > "$T/set"; rm -f "$T/baseline.txt"
run strict; run stock
grep -q 'settings_enable_monitor_phantom_procs' "$T/set" && f "stock left a key that was unset before ASB"
[ "$fail" = 0 ] && echo "PASS phantom stock restore"
exit "$fail"
)

t_phase_wakeholders_runtime() (
# Runtime (fix143): phase_wakeholders.txt names what held each screen-off phase awake INSIDE
# that phase, not batterystats' running totals.
#
# Capture 26147 printed "PowerManagerService.WakeLocks: 15m 2s" under a two-minute gap, with a
# header saying the figures were not the phase's own - and idle phases at 47-64% awake had no
# culprit. Apps: the step of batterystats' per-app partial wakelock timers (screen-off only)
# since the previous screen-off close. Kernel: /sys/class/wakeup at open and at close. The
# interim report's snapshot of the open phase no longer writes a block or dumps batterystats.
# The REAL ledger functions run here, with dumpsys and the wakeup class faked.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
C="$ROOT/tools/logkit/_asb_logkit_common.sh"
FD="$ROOT/tools/logkit/asb_log_full_day.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL phase wakeholders: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/out" "$T/wk/wakeup0" "$T/wk/wakeup1" "$T/wk/wakeup2"
: > "$T/dumpsys_calls"

cat > "$T/bin/dumpsys" <<'EOF'
#!/bin/sh
echo x >> "$FAKE_DIR/dumpsys_calls"
[ "$1" = batterystats ] && cat "$FAKE_DIR/bs"
exit 0
EOF
chmod +x "$T/bin/dumpsys"

# Helpers the scenario steps call: the fake batterystats and the fake wakeup class.
cat > "$T/defs.sh" <<'EOF'
bs() {   # pedometer time, system *alarm* time
  cat > "$T/bs" <<EOB
All kernel wake locks:
  Kernel Wake lock PowerManagerService.WakeLocks: 15m 2s 250ms (4 times) realtime
All partial wake locks:
  Wake lock u0a493 PedometerLib:tag: $1 (5 times) max=79609 actual=425546 realtime
  Wake lock u0a691 *job*e/@androidx.work.systemjobscheduler@com.anthropic.claude/androidx.work.impl.background.systemjob.SystemJobService: 3m 27s 118ms (1 times) max=246955 actual=246955 realtime
  Wake lock 1000 *alarm*: $2 (29 times) realtime

  u0a493:
    Wake lock PedometerLib:tag: $1 partial (5 times) max=79609 realtime
EOB
}
wk() {   # pms_ms uart_ms own_ms
  echo PowerManagerService.WakeLocks > "$T/wk/wakeup0/name"; echo "$1" > "$T/wk/wakeup0/total_time_ms"
  echo 1994000.qcom,qup_uart > "$T/wk/wakeup1/name"; echo "$2" > "$T/wk/wakeup1/total_time_ms"
  echo asb_logkit_123 > "$T/wk/wakeup2/name"; echo "$3" > "$T/wk/wakeup2/total_time_ms"
}
ph() { echo "$2" > "$T/up"; echo "$3" > "$T/mono"; lk_phase_ledger_open "$1"; }
cl() { echo "$1" > "$T/up"; echo "$2" > "$T/mono"; lk_phase_ledger_flush; }
EOF

# The ledger functions, as the full-day recorder defines them.
awk '/^[a-z_][a-z0-9_]*\(\) *\{/ { f = 1 } f { print } f && /^}/ { f = 0 }' "$FD" > "$T/fns.sh"

out="$(PATH="$T/bin:$PATH" FAKE_DIR="$T" LK_OUT_DIR="$T/out" LK_WAKEUP_CLASS="$T/wk" sh -c '
  . "$0" >/dev/null 2>&1
  T="$1"
  . "$T/fns.sh"; . "$T/defs.sh"
  lk_uptime_s() { cat "$T/up"; }
  lk_mono_s() { cat "$T/mono"; }
  lk_phase_rmnet_bytes() { echo "0 0"; }
  LK_WAKELOCK_NAME=asb_logkit_123
  # 1. the first screen-off close of the capture: running totals, said so
  bs "4m 59s 837ms" "10s 0ms"; wk 900000 300000 5000
  ph gap 1000 1000
  bs "5m 41s 533ms" "12s 500ms"; wk 930000 301000 9000
  cl 1060 1040
  # 2. a screen-on phase: no batterystats read at its close
  ph active 1060 1040; cl 2000 1980
  echo "calls after active: $(wc -l < "$T/dumpsys_calls")"
  # 3. a screen-off stretch that turns out longer than a gap
  wk 2000000 400000 20000
  ph gap 2000 1980
  echo 2030 > "$T/up"; echo 2010 > "$T/mono"
  lk_phase_ledger_snapshot_open      # the interim report: no block, no dumpsys
  echo "calls after snapshot: $(wc -l < "$T/dumpsys_calls")"
  LK_PH_START=$(( $(date +%s) - 200 ))
  bs "7m 46s 533ms" "13s 0ms"; wk 2130000 440000 90000
  cl 2200 2100
  # 4. screen-off audio keeps the baseline current without printing
  ph audio_bt 2200 2100
  bs "8m 46s 533ms" "1m 13s 0ms"
  cl 2500 2490
  ph idle 2500 2490
  bs "8m 50s 533ms" "1m 13s 300ms"; wk 2200000 445000 99000
  cl 2700 2600
  echo "--- holders"; cat "$LK_OUT_DIR/phase_wakeholders.txt"
  echo "--- files"; ls -a "$LK_OUT_DIR"
' "$C" "$T" 2>&1)"

h="$(printf '%s\n' "$out" | sed -n '/^--- holders$/,/^--- files$/p')"
printf '%s\n' "$out" | grep -q '^calls after active: 1$' || f "a screen-on close read batterystats, or the first screen-off close did not: $out"
printf '%s\n' "$out" | grep -q '^calls after snapshot: 1$' || f "the interim snapshot read batterystats: $out"
[ "$(printf '%s\n' "$h" | grep -c '^phase=')" = 3 ] || f "expected three blocks (gap, idle-relabelled gap, idle; none for audio_bt or the snapshot): $h"
printf '%s\n' "$h" | grep -q 'dur=2s\|dur=30s' && f "a block for the phase still open: $h"
# 1: running totals, labelled.
printf '%s\n' "$h" | grep -q "^  app:    5m 41s  PedometerLib:tag  (u0a493)  since Android's last unplug - no earlier reading in this capture$" \
  || f "first close not labelled as running totals: $h"
printf '%s\n' "$h" | grep -q '^  kernel: +0m 30s  PowerManagerService.WakeLocks$' || f "kernel step of the first gap: $h"
printf '%s\n' "$h" | grep -q 'asb_logkit' && f "the capture's own lock listed: $h"
# 3: the 200-second "gap" is an idle, and its steps are its own.
blk="$(printf '%s\n' "$h" | awk '/^phase=/{n++} n==2')"
printf '%s\n' "$blk" | head -1 | grep -q '^phase=idle awake=60% dur=200s  (time gained inside this phase)$' || f "relabel or header: $blk"
printf '%s\n' "$blk" | grep -q '^  app:    +2m 05s  PedometerLib:tag  (u0a493)$' || f "app step in the idle stretch: $blk"
printf '%s\n' "$blk" | grep -q 'SystemJobService' && f "an app with no step listed: $blk"
printf '%s\n' "$blk" | grep -q '^  kernel: +2m 10s  PowerManagerService.WakeLocks$' || f "kernel step (open->close): $blk"
printf '%s\n' "$blk" | grep -q '^  kernel: +0m 40s  1994000.qcom,qup_uart$' || f "second kernel step: $blk"
# 4: after the audio phase the idle shows only its own 4 s, not the minute the audio phase added.
blk="$(printf '%s\n' "$h" | awk '/^phase=/{n++} n==3')"
printf '%s\n' "$blk" | grep -q '^  app:    +0m 04s  PedometerLib:tag  (u0a493)$' || f "baseline not carried through the audio phase: $blk"
printf '%s\n' "$blk" | grep -q '\*alarm\*' && f "a sub-second step listed: $blk"
printf '%s\n' "$out" | sed -n '/^--- files$/,$p' | grep -q '^\.wh_a_prev$' || f "baseline not kept: $out"
printf '%s\n' "$out" | sed -n '/^--- files$/,$p' | grep -qE '^\.wh_(a|k)_now$' && f "scratch files left: $out"

[ "$fail" = 0 ] && echo "PASS phase wakeholders: app and kernel time gained inside each screen-off phase, no blocks from interim snapshots"
exit "$fail"
)

t_settings_rejected_runtime() (
# Runtime (fix129): a settings key the ROM refuses is not asked again on every boot.
#
# OP15 asbdiag: network_recommendations_enabled "not_writable (write rejected)" 16 times and
# cloud_dns_happy_eyeballs_priority_enabled 7 times - three `settings` calls each, every boot
# and every reinforce pass, for a write Android 16 will never take. The ledger now remembers
# the refusal per ROM build: the next attempt is recorded and skipped; a new install or an
# OTA tries again.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL settings rejected: $*" >&2; exit 1; }
mkdir -p "$T/bin" "$T/state" "$T/s"
cat > "$T/bin/settings" <<'X'
#!/bin/sh
echo "$*" >> "$FAKE/calls"
case "$1" in
  get) cat "$FAKE/s/$2.$3" 2>/dev/null || echo null ;;
  put) case "$3" in network_recommendations_enabled) echo "java.lang.IllegalArgumentException: write rejected" >&2; exit 1 ;; esac
       printf '%s\n' "$4" > "$FAKE/s/$2.$3" ;;
esac
X
printf '#!/bin/sh\ncat "$FAKE/fp" 2>/dev/null\n' > "$T/bin/getprop"
chmod +x "$T/bin/settings" "$T/bin/getprop"
echo "OnePlus/CPH2745/OP611FL1:16/A" > "$T/fp"
export PATH="$T/bin:$PATH" FAKE="$T" ASB_CONFIG_STATE="$T/state"
run() { sh -c '. "$1"; asb_ledger_settings "$2" "$3" "$4"; echo "rc=$?"' x "$ROOT/runtime/asb_apply_ledger.sh" "$@"; }

r="$(run global network_recommendations_enabled 0)"
[ "$r" = rc=1 ] || fail "rejected write reported as success: $r"
grep -qx 'global|network_recommendations_enabled|0|OnePlus/CPH2745/OP611FL1:16/A' "$T/state/settings_rejected" || fail "refusal not remembered"
: > "$T/calls"
r="$(run global network_recommendations_enabled 0)"
[ "$r" = rc=1 ] || fail "skipped write reported as success: $r"
[ -s "$T/calls" ] && fail "settings called again for a known refusal: $(cat "$T/calls")"
tail -1 "$T/state/apply_ledger" | grep -q 'not_writable|rejected before on this ROM build - not retried' || fail "skip not in the ledger"
# Other keys are unaffected.
r="$(run global wifi_scan_throttle_enabled 1)"
[ "$r" = rc=0 ] || fail "accepted write broken: $r"
# A different value, or a different ROM build, is tried again.
: > "$T/calls"; run global network_recommendations_enabled 1 >/dev/null
grep -q '^put global network_recommendations_enabled 1' "$T/calls" || fail "another value not tried"
echo "OnePlus/CPH2745/OP611FL1:16/B" > "$T/fp"
: > "$T/calls"; run global network_recommendations_enabled 0 >/dev/null
grep -q '^put global network_recommendations_enabled 0' "$T/calls" || fail "not retried after an OTA"
# fix221: the key that does not exist on the ROM (empty read-back before AND after the
# failed write - ColorOS 16 refuses to create unknown keys) is filed as unsupported,
# not as a refusal: it is not a permission problem, and asbdiag lists it apart.
tail -1 "$T/state/apply_ledger" | grep -q 'unsupported|key absent on this ROM' \
  || fail "absent key not filed as unsupported: $(tail -1 "$T/state/apply_ledger")"
# A key that EXISTS but refuses the write is still a refusal.
echo 1 > "$T/s/global.network_recommendations_enabled"
echo "OnePlus/CPH2745/OP611FL1:16/C" > "$T/fp"
run global network_recommendations_enabled 0 >/dev/null
tail -1 "$T/state/apply_ledger" | grep -q 'not_writable|write rejected' \
  || fail "existing-key refusal no longer filed as not_writable: $(tail -1 "$T/state/apply_ledger")"
rm -f "$T/s/global.network_recommendations_enabled"
# A value the ROM stored in another form did take: not remembered as a refusal.
cat > "$T/bin/settings" <<'X'
#!/bin/sh
echo "$*" >> "$FAKE/calls"
case "$1" in
  get) cat "$FAKE/s/$2.$3" 2>/dev/null || echo null ;;
  put) printf '%s\n' "${4%.0}" > "$FAKE/s/$2.$3"; [ "${4%.0}" = "$4" ] || exit 1 ;;
esac
X
chmod +x "$T/bin/settings"
run global some_scale 1.0 >/dev/null
grep -q '|some_scale|' "$T/state/settings_rejected" && fail "a normalised value was remembered as refused"
# A new install forgets the list.
grep -q '^rm -f /data/adb/asb/settings_rejected' "$ROOT/common/install.sh" || fail "install keeps old refusals"
echo "PASS settings rejected: a refused key is asked once per ROM build"
)

t_uevent_accounting_contract() (
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
grep -qF 'g_uev_by_src[cur != -1 ? ASB_UEV_DISPLAY : uevent_bucket(ubuf, un)]++' "$SRC" \
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
    /* A display event with no power marker - the kind sent as the screen powers on - is
     * "changed, re-read" (-2), not "off": reading it as off is why screen ON was never seen. */
    {
        char e7[] = "change@/devices/platform/soc/drm/card0\0ACTION=change\0SUBSYSTEM=drm\0HOTPLUG=1\0";
        CHECK(parse_uevent_screen_buf(e7, sizeof(e7) - 1) == -2, "drm event without marker must be 'changed' (-2)");
        CHECK(uevent_bucket(e7, sizeof(e7) - 1) == ASB_UEV_DISPLAY, "unmarked drm event still buckets as display");
    }
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
)

t_uevent_park_runtime() (
# Runtime (fix118): with Android's display state watched, the uevent socket stays parked.
#
# An OP15 night delivered 250-500 kernel uevents an hour to the governor (AOD pulses,
# battery, thermal, "other"), each one a wakeup to discard it. Once the display-state
# waiter is live it reports every wake, so the socket is parked with the screen off as well;
# the wake keys keep listening as the backstop and still leave epoll while the screen is
# on (the touch panel's node would wake the loop on every frame). Without the waiter the
# old behaviour is exact. Executable fixture: the REAL uev_park()/uev_unpark() and wake-key
# parking cut out of asb_governor.c, against a real epoll set.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL uevent park: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP uevent park: no C compiler"; exit 0; }
_a="$(grep -n '^static int           g_uev_parked = 0;' "$G" | cut -d: -f1)"
_b="$(awk '/^static void uev_unpark\(/{f=1} f&&/^}/{print NR; exit}' "$G")"
[ -n "$_a" ] && [ -n "$_b" ] || fail "park code not found"
sed -n "${_a},${_b}p" "$G" | sed -e '/^static void wake_keys_open(int epfd) {$/,/^}$/d' -e '/^static int touch_open(void) {$/,/^}$/d' > "$T/p.c"

cat > "$T/t.c" <<'X'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <linux/input.h>
static volatile int g_disp_waiter_up = 0;
#include "p.c"
static int in_epoll(int ep, int fd) {
    struct epoll_event e; memset(&e, 0, sizeof(e)); e.events = EPOLLIN; e.data.fd = fd;
    if (epoll_ctl(ep, EPOLL_CTL_MOD, fd, &e) == 0) return 1;
    return errno != ENOENT ? -1 : 0;
}
int main(void) {
    int bad = 0;
    #define CHECK(c, msg) do { if (!(c)) { printf("%s\n", msg); bad = 1; } } while (0)
    int ep = epoll_create1(0);
    int u[2], k[2]; if (pipe2(u, O_NONBLOCK) || pipe2(k, O_NONBLOCK)) return 1;
    int ue = u[0];
    struct epoll_event e; memset(&e, 0, sizeof(e)); e.events = EPOLLIN;
    e.data.fd = ue; epoll_ctl(ep, EPOLL_CTL_ADD, ue, &e);
    g_wake_key_fd[0] = k[0]; g_wake_key_touch[0] = 1; g_wake_key_n = 1;
    e.data.fd = k[0]; epoll_ctl(ep, EPOLL_CTL_ADD, k[0], &e);

    /* no waiter: screen on parks both, screen off unparks both (old behaviour) */
    uev_park(ep, ue);
    CHECK(g_uev_parked == 1 && in_epoll(ep, ue) == 0 && in_epoll(ep, k[0]) == 0, "screen on did not park socket+keys");
    uev_unpark(ep, ue);
    CHECK(g_uev_parked == 0 && in_epoll(ep, ue) == 1 && in_epoll(ep, k[0]) == 1, "screen off did not unpark socket+keys");

    /* waiter live: screen on parks both; screen off brings back the keys only */
    g_disp_waiter_up = 2;
    uev_park(ep, ue);
    CHECK(g_uev_parked == 1 && in_epoll(ep, ue) == 0 && in_epoll(ep, k[0]) == 0, "screen on (waiter) did not park");
    uev_unpark(ep, ue);
    CHECK(g_uev_parked == 1 && in_epoll(ep, ue) == 0, "screen off unparked the uevent socket although the waiter is live");
    CHECK(in_epoll(ep, k[0]) == 1, "screen off (waiter) left the wake keys out");
    uev_park(ep, ue);
    CHECK(in_epoll(ep, k[0]) == 0, "screen on (waiter) left the touch panel's wake-key node in epoll");
    uev_unpark(ep, ue);
    /* waiter gone: the next screen-off path gives the socket back */
    g_disp_waiter_up = -1;
    uev_unpark(ep, ue);
    CHECK(g_uev_parked == 0 && in_epoll(ep, ue) == 1, "socket not given back after the waiter went away");
    return bad;
}
X
"$CC" -std=gnu99 -Wall -Wno-unused-function -o "$T/t" "$T/t.c" -I"$T" 2>"$T/cc.err" || { cat "$T/cc.err" >&2; fail "fixture does not compile"; }
out="$("$T/t")" || fail "$out"
echo "PASS uevent park: socket parked while Android reports wakes, keys as backstop"
)

t_uninstall_dsp_prop_cleanup_contract() (
# Contract: uninstalling the module removes its own persistent properties and nothing else.
#
# A field report on V64 found persist.vendor.asb.dsp.* surviving uninstall under
# /data/property, because asb_audio_apply.sh writes them with its own resetprop helpers
# that bypass asb_persist_safe - so baseline.txt never saw them and nothing deleted them.
# The fix deletes the persist.asb.* / persist.vendor.asb.* namespaces wholesale.
#
# This test extracts the sed selector straight from uninstall.sh (not a copy of it) and
# runs it against a representative getprop dump, so the test fails the moment the
# selector in the script stops matching the namespace - or starts matching anything wider.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UNINSTALL="$ROOT/uninstall.sh"
fail() { echo "FAIL uninstall dsp cleanup: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }

[ -f "$UNINSTALL" ] || fail "uninstall.sh not found"

# The cleanup must exist, delete persistently (-p --delete, not just the in-memory value),
# and run while resetprop is still available.
need "$UNINSTALL" 'resetprop -p --delete'
need "$UNINSTALL" 'persist\.\(vendor\.\)'
need "$UNINSTALL" 'command -v resetprop'

# Pull the real selector line out of the script.
SED_LINE="$(grep -F 'sed -n' "$UNINSTALL" | grep -F 'persist' | head -1)"
[ -n "$SED_LINE" ] || fail "namespace selector sed line not found in uninstall.sh"
SED_EXPR="$(printf '%s\n' "$SED_LINE" | sed -n "s/.*sed -n '\([^']*\)'.*/\1/p")"
[ -n "$SED_EXPR" ] || fail "could not extract sed expression from: $SED_LINE"

# Representative getprop dump: both ASB namespaces, plus neighbours that must survive.
#  - persist.vendor.audio.*   : vendor audio props, restored via baseline, not ours to delete
#  - persist.asbd.evil        : a prop that merely starts with the same letters
#  - persist.sys.oplus.*      : OEM props handled by their own stale-prop list
DUMP='
[persist.asb.dsp.enable]: [1]
[persist.asb.dsp.route]: [bt]
[persist.asb.force_disableabsvol]: [1]
[persist.vendor.asb.dsp.gain_mb]: [2500]
[persist.vendor.asb.dsp.bass_db]: [4]
[persist.vendor.asb.dsp.comp_ratio_x10]: [60]
[persist.vendor.asb.dsp.ceiling_mb]: [1800]
[persist.vendor.audio.hifi]: [true]
[persist.vendor.audio.fluence.voicecall]: [true]
[persist.asbd.evil]: [1]
[persist.sys.oplus.athena.reclaim_enable]: [1]
[ro.build.fingerprint]: [x]
'
MATCHED="$(printf '%s\n' "$DUMP" | sed -n "$SED_EXPR")"

for _p in persist.asb.dsp.enable persist.asb.dsp.route persist.asb.force_disableabsvol \
          persist.vendor.asb.dsp.gain_mb persist.vendor.asb.dsp.bass_db \
          persist.vendor.asb.dsp.comp_ratio_x10 persist.vendor.asb.dsp.ceiling_mb; do
  printf '%s\n' "$MATCHED" | grep -Fqx "$_p" || fail "selector misses ASB prop: $_p"
done
for _p in persist.vendor.audio.hifi persist.vendor.audio.fluence.voicecall \
          persist.asbd.evil persist.sys.oplus.athena.reclaim_enable; do
  printf '%s\n' "$MATCHED" | grep -Fq "$_p" && fail "selector wrongly catches foreign prop: $_p"
done

# Every selected name must carry the asb. marker after the optional vendor. segment -
# belt-and-braces against a future edit widening the pattern.
printf '%s\n' "$MATCHED" | while IFS= read -r _m; do
  [ -n "$_m" ] || continue
  case "$_m" in
    persist.asb.*|persist.vendor.asb.*) ;;
    *) echo "FAIL uninstall dsp cleanup: matched non-ASB prop: $_m" >&2; exit 1 ;;
  esac
done

echo "PASS uninstall dsp cleanup contract"
)

t_v65_efficiency_contract() (
# Contract: the V65 efficiency pass must keep expensive boot operations opt-in and
# must not reintroduce high-frequency screen-off polling.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVICE="$ROOT/service.sh"
GOV="$ROOT/src/asb_governor.c"
fail() { echo "FAIL V65 efficiency contract: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in $1"; }
line_of() { grep -nF "$2" "$1" | head -1 | cut -d: -f1; }

# A full zram reset performs swapoff/writeback.  It must never run solely because
# the VM feature is enabled on a device that already owns a usable zram policy.
need "$SERVICE" 'allow_zram_rebuild'
zram_guard="$(line_of "$SERVICE" 'allow_zram_rebuild')"
zram_swapoff="$(line_of "$SERVICE" 'swapoff /dev/block/zram0')"
[ -n "$zram_guard" ] && [ -n "$zram_swapoff" ] && [ "$zram_guard" -lt "$zram_swapoff" ] \
  || fail 'zram rebuild is not guarded before swapoff'

# Destructive background trimming and init service stops can induce package/service
# restarts.  They must have explicit local opt-in gates.
need "$SERVICE" 'allow_disruptive_bg_trim'
need "$SERVICE" 'allow_service_stops'

# The observer must not run package-manager/dumpsys/appops work while the screen is
# on, and the screen-off interval must be at least an hour between expensive passes.
# Wall-clock gates (an awake-time sleep of 1800 s took ~12 h on a phone that sleeps well):
# watchdogs every 30 min, the expensive screen-off pass at most once per hour.
need "$SERVICE" '[ $(( _ho_now - _wd_last )) -ge 1800 ] 2>/dev/null || continue'
need "$SERVICE" '[ $(( _ho_now - _ho_last )) -ge 3600 ] 2>/dev/null || continue'

# DSP route correction is a fallback poll; normal setting changes still signal the
# attacher immediately.  A 60-second cadence prevents permanent 20-second IPC churn.
need "$SERVICE" 'sleep 60'
need "$SERVICE" 'pkill -USR1 -f asb_dsp_attach'

# The deferred core worker must avoid the broad profile fan-out and use only its
# narrow CPU setup path, preventing duplicate CPU/GPU/VM/network/Wi-Fi/UX writes.
core_start="$(line_of "$SERVICE" 'asb_apply_deferred_core_boot() {')"
core_end="$(line_of "$SERVICE" 'apply_doze() {')"
[ -n "$core_start" ] && [ -n "$core_end" ] || fail 'could not locate deferred core worker'
if sed -n "${core_start},${core_end}p" "$SERVICE" | grep -Eq '^[[:space:]]*asb_apply_profile_once([[:space:]]|$)'; then
  fail 'deferred core worker still uses broad profile fan-out'
fi
need "$SERVICE" 'asb_feature_enabled CPU && asb_cpu_cluster_init'
# On devices with the native Smart governor, boot must return after native ownership is
# confirmed; the legacy multi-write shell convergence is available only as an explicit opt-in.
need "$SERVICE" 'allow_boot_shell_policy'
need "$SERVICE" 'post_boot_core_policy_native_only'
boot_guard="$(line_of "$SERVICE" 'allow_boot_shell_policy')"
boot_load="$(sed -n "${core_start},${core_end}p" "$SERVICE" | grep -nE '^[[:space:]]*asb_load_profile([[:space:]]|$)' | head -1 | cut -d: -f1)"
[ -n "$boot_guard" ] && [ -n "$boot_load" ] || fail 'boot shell-policy guard missing'

# Native screen-off cadence must remain materially slower than the active loop.
# The 45-second deep-idle and 60-second verified Quiet Night intervals leave display/socket
# events epoll-driven; they must not regress to the older high-frequency idle sampling.
need "$GOV" '#define TIMER_IDLE_S   10'
need "$GOV" '#define TIMER_DEEP_S   45'
need "$ROOT/config/governor.conf" 'quiet_tick_s=60'
need "$GOV" 'screen-on, socket and display uevents remain independently epoll-driven'
need "$GOV" 'expected_samples = dur / (TIMER_DEEP_S'

echo 'PASS V65 efficiency contract'
)

t_wakelock_fitness_runtime() (
# Runtime: wakelock_fitness=limit denies WAKE_LOCK to fitness apps seen holding one, and
# protect gives back exactly the mode each had before. Watch companions are never touched,
# and the choice works without wakelock_action and below the awake-share bar.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wakelock fitness: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/d"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1" in
  batterystats) cat <<'B'
  All partial wake locks:
  Wake lock u0a493 PedometerLib:tag: 4m 4s 955ms (3 times) max=150727 actual=296015 realtime
  Wake lock u0a432 *job*e/@androidx.work.systemjobscheduler@com.duolingo/androidx.work.impl.background.systemjob.SystemJobService: 3m 10s 2ms (9 times) realtime
  Wake lock u0a700 SyncLoop: 1h 2m 0s 1ms (40 times) realtime
  Wake lock u0a800 Tiny: 30s 1ms (2 times) realtime
  Wake lock u0a147 CollectionLib-SigCollector: 9m 868ms (3 times) realtime
  Wake lock 1000 *alarm*: 5m 1ms (3 times) realtime
  Total WiFi Multicast wakelock time: 1h 2m 3s 4ms
B
  ;;
  power) cat <<'P'
    PARTIAL_WAKE_LOCK                 '*job*r/com.example.player/x.Job' ACQ=-2m2s223ms LONG (uid=1000 pid=6599 ws=WorkSource{ chains=WorkChain{(10901), (1000, JobScheduler)}})
    PARTIAL_WAKE_LOCK                 'Short' ACQ=-3s (uid=10800 pid=1)
P
  ;;
  activity) cat <<'A'
  #45: fg     TOP  LCMNFU  ---- 1234:com.android.launcher/u0a12
  #30: prcp   FGS  ----    ---- 4567:com.example.player/u0a901
  #20: cch+ 5 CEM  ----    ---- 5678:com.example.sync/u0a700
A
  ;;
  deviceidle) echo false ;;
  wifi) cat <<'W'
Multicast Locks held:
    Multicaster{mdns-discovery uid=10700}
    Multicaster{CastDiscovery uid=10950}
    Multicaster{NearbyMediums uid=1000}
W
  ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
cat <<'L'
package:com.sec.android.app.shealth uid:10493
package:com.duolingo uid:10432
package:com.example.sync uid:10700
package:com.example.tiny uid:10800
package:com.example.player uid:10901
package:com.example.cast uid:10950
L
S
cat > "$T/bin/am" <<'S'
#!/bin/sh
echo "$*" >> "$AM_LOG"
S
cat > "$T/bin/appops" <<'S'
#!/bin/sh
# Stateful: get answers what set stored, so the recorded "previous mode" is real.
echo "appops $*" >> "$AM_LOG"
case "$1" in
  get) m="$(sed -n "s/^$2 $3 //p" "$OPS" 2>/dev/null | tail -1)"
       if [ -n "$m" ]; then echo "$3: $m; time=+1h"; else echo "No operations."; fi ;;
  set) echo "$2 $3 $4" >> "$OPS" ;;
esac
S
chmod +x "$T/bin/"*
cat >> "$T/bin/pm" <<'S'
echo "package:com.google.android.apps.wearables.watch uid:10960"
echo "package:com.strava.idle uid:10961"
S
# A watch companion holding a long wakelock too.
sed -i 's/^  Wake lock u0a700 SyncLoop/  Wake lock u0a960 WatchSync: 5m 0s 1ms (4 times) realtime\n  Wake lock u0a700 SyncLoop/' "$T/bin/dumpsys"
run() {
  printf 'wakelock_action=0\nwakelock_fitness=%s\n' "$1" > "$T/mod/config/governor.conf"
  printf 'awake_pct_screenoff=5\nawake_window_min=90\n' > "$T/state"
  OPS="$T/ops" AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
    sh "$SRC" >/dev/null 2>&1
}
A="$T/d/wakelock_apps"

run protect
grep -q 'WAKE_LOCK' "$T/am.log" 2>/dev/null && f "protect touched WAKE_LOCK"
grep -q '^com.sec.android.app.shealth|244|0|protected$' "$A" || f "pedometer not protected under protect"

# The user had already set the pedometer to allow explicitly: that mode must come back.
echo "com.sec.android.app.shealth WAKE_LOCK allow" > "$T/ops"
run limit
grep -q 'appops set com.sec.android.app.shealth WAKE_LOCK ignore' "$T/am.log" || f "limit did not deny the pedometer"
# Proactive: an installed fitness app that held nothing is limited too.
grep -q 'appops set com.strava.idle WAKE_LOCK ignore' "$T/am.log" || f "installed fitness app not limited proactively"
grep -q '^com.sec.android.app.shealth|244|0|limited$' "$A" || f "verdict not limited"
grep -qx 'com.sec.android.app.shealth|allow' "$T/d/wakelock_fitness_limited" || f "previous mode not recorded"
grep -q 'wearables.watch WAKE_LOCK' "$T/am.log" && f "watch companion touched"
grep -q 'set-standby-bucket' "$T/am.log" && f "generic restriction ran with wakelock_action=0"
run limit
[ "$(grep -c 'set com.sec.android.app.shealth WAKE_LOCK ignore' "$T/am.log")" = 1 ] || f "denied twice"

: > "$T/am.log"
run protect
grep -q 'appops set com.sec.android.app.shealth WAKE_LOCK allow' "$T/am.log" || f "protect did not restore the recorded mode"
[ -f "$T/d/wakelock_fitness_limited" ] && f "record kept after protect"

# An app someone else already set to ignore is not ours to record or undo.
echo "com.sec.android.app.shealth WAKE_LOCK ignore" > "$T/ops"; : > "$T/am.log"
run limit
grep -q "^com.sec.android.app.shealth|" "$T/d/wakelock_fitness_limited" 2>/dev/null && f "recorded an app that was already ignored"
grep -q 'set com.sec.android.app.shealth WAKE_LOCK' "$T/am.log" && f "re-set an externally ignored app"

# Enforcement is verified. A lock PowerManager still honours (LONG, not DISABLED) after the
# op was set means the ROM ignores the op: reported as limit_ignored, never as "limited".
echo "com.sec.android.app.shealth WAKE_LOCK allow" > "$T/ops"; rm -f "$T/d/wakelock_fitness_limited" "$T/d/wakelock_fitness_ignored"
run limit
grep -q '^com.sec.android.app.shealth|244|0|limited$' "$A" || f "first pass after limiting must say limited"
sed -i "s/^    PARTIAL_WAKE_LOCK                 'Short'/    PARTIAL_WAKE_LOCK                 'PedometerLib:tag' ACQ=-17m49s LONG (uid=10493 pid=21501)\n    PARTIAL_WAKE_LOCK                 'Short'/" "$T/bin/dumpsys"
run limit
grep -q '^com.sec.android.app.shealth|244|1|limit_ignored$' "$A" || f "a still-honoured lock after the op was not reported: $(grep shealth "$A")"
grep -qx 'com.sec.android.app.shealth' "$T/d/wakelock_fitness_ignored" || f "ignored state not recorded"
# A DISABLED lock does not hold the CPU and is not a holder.
sed -i "s/'PedometerLib:tag' ACQ=-17m49s LONG (uid=10493 pid=21501)/'PedometerLib:tag' ACQ=-17m49s LONG DISABLED (uid=10493 pid=21501)/" "$T/bin/dumpsys"
rm -f "$T/d/wakelock_fitness_ignored"
run limit
grep -q '^com.sec.android.app.shealth|244|0|limited$' "$A" || f "a DISABLED lock was counted as held: $(grep shealth "$A")"
# fix100: the system resets the op (app update, permission reset, boot sweep). The limit
# is re-asserted, the ORIGINAL mode stays on record, and a lock held while the op was
# lapsed is not taken as proof that Android ignores the op.
sed -i "s/'PedometerLib:tag' ACQ=-17m49s LONG DISABLED (uid=10493 pid=21501)/'PedometerLib:tag' ACQ=-17m49s LONG (uid=10493 pid=21501)/" "$T/bin/dumpsys"
echo "com.sec.android.app.shealth WAKE_LOCK default" >> "$T/ops"; : > "$T/am.log"
run limit
grep -q 'appops set com.sec.android.app.shealth WAKE_LOCK ignore' "$T/am.log" || f "lapsed limit not re-applied"
grep -qx 'com.sec.android.app.shealth|allow' "$T/d/wakelock_fitness_limited" || f "original mode lost on re-apply"
grep -q '^com.sec.android.app.shealth|244|1|limited$' "$A" || f "lapsed-op hold misread: $(grep shealth "$A")"
grep -qx 'com.sec.android.app.shealth' "$T/d/wakelock_fitness_ignored" 2>/dev/null && f "enforcement verdict drawn on a lapsed op"
run protect
[ -f "$T/d/wakelock_fitness_ignored" ] && f "ignored record kept after protect"
grep -q 'appops set com.sec.android.app.shealth WAKE_LOCK allow' "$T/am.log" || f "protect after re-apply did not restore allow"
# fix143: "fitness" mode, run by service.sh minutes after boot. OPlus' boot sweep reset the
# op; the limit comes back without the hourly pass, without batterystats, and a verdict
# drawn while the op had lapsed is shown as limited again.
run limit
grep -qx 'com.sec.android.app.shealth|allow' "$T/d/wakelock_fitness_limited" || f "setup: not limited"
echo "com.sec.android.app.shealth" > "$T/d/wakelock_fitness_ignored"
echo "com.sec.android.app.shealth|244|1|limit_ignored" > "$A"
echo "com.sec.android.app.shealth WAKE_LOCK default" >> "$T/ops"; : > "$T/am.log"
mkdir -p "$T/bin2"
printf '#!/bin/sh\necho "dumpsys $*" >> "$AM_LOG"\n' > "$T/bin2/dumpsys"; chmod +x "$T/bin2/dumpsys"
fit() {
  printf 'wakelock_action=0\nwakelock_fitness=%s\n' "$1" > "$T/mod/config/governor.conf"
  OPS="$T/ops" AM_LOG="$T/am.log" PATH="$T/bin2:$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
    sh "$SRC" fitness >/dev/null 2>&1
}
fit limit
grep -q 'appops set com.sec.android.app.shealth WAKE_LOCK ignore' "$T/am.log" || f "fitness mode did not re-assert the lapsed limit"
grep -q '^dumpsys' "$T/am.log" && f "fitness mode measured (dumpsys): $(cat "$T/am.log")"
grep -qx 'com.sec.android.app.shealth|allow' "$T/d/wakelock_fitness_limited" || f "fitness mode lost the original mode"
grep -qx 'com.sec.android.app.shealth' "$T/d/wakelock_fitness_ignored" 2>/dev/null && f "lapsed-op verdict kept after re-assert"
grep -qx 'com.sec.android.app.shealth|244|1|limited' "$A" || f "report verdict not corrected: $(cat "$A")"
[ -e "$T/d/wakelock_fitness_limited.reapplied" ] && f "reapplied marker left behind"
: > "$T/am.log"; fit limit
grep -q 'appops set' "$T/am.log" && f "fitness mode re-set an op already in force"
: > "$T/am.log"; fit protect
grep -q 'appops set' "$T/am.log" && f "fitness mode acted with wakelock_fitness=protect"
grep -q 'asb_wakelock_watch.sh" fitness' "$ROOT/service.sh" || f "service.sh does not run the fitness pass after boot"
run protect

grep -q 'limit_ignored)' "$ROOT/action.sh" || f "action has no wording for limit_ignored"
grep -q 'limit_ignored)' "$ROOT/tools/asb_diag.sh" || f "asbdiag has no wording for limit_ignored"
for _l in "$ROOT"/runtime/i18n/action_*.sh; do grep -q '^T_WLV_LIMIT_IGNORED=' "$_l" || f "$(basename "$_l") lacks T_WLV_LIMIT_IGNORED"; done

grep -q 'wakelock_fitness_limited' "$ROOT/uninstall.sh" || f "uninstall does not restore limited fitness apps"

[ "$fail" = 0 ] && echo "PASS wakelock fitness runtime"
exit "$fail"
)

t_wakelock_messenger_guard_runtime() (
# Runtime (fix136): the wakelock watcher never restricts a messenger or an app the user has
# exempted from battery optimisation, and gives back one an earlier pass restricted.
#
# The OP15 capture of this round carries org.thoughtcrime.securesms in wakelock_restricted:
# Signal, moved to the restricted standby bucket by ASB - its package id has no "signal" in
# it, so the protected-name list never matched, and a messenger lost timely delivery.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wakelock messenger guard: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/d"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1:${2:-}" in
  batterystats:*) cat <<'B'
  All partial wake locks:
  Wake lock u0a291 WebSocket: 40m 1s 2ms (12 times) realtime
  Wake lock u0a700 SyncLoop: 1h 2m 0s 1ms (40 times) realtime
  Wake lock u0a750 Keepalive: 35m 0s 1ms (9 times) realtime
  Wake lock u0a760 ImapIdle: 20m 0s 1ms (9 times) realtime
B
  ;;
  power:*) : ;;
  activity:*) cat <<'A'
  #20: cch+ 5 CEM  ----    ---- 5678:com.example.sync/u0a700
  #19: cch+ 5 CEM  ----    ---- 5679:org.thoughtcrime.securesms/u0a291
  #18: cch+ 5 CEM  ----    ---- 5680:com.user.exempt/u0a750
  #17: cch+ 5 CEM  ----    ---- 5681:com.google.android.gm/u0a760
A
  ;;
  deviceidle:whitelist) cat <<'W'
system-excidle,com.android.providers.downloads,10035
system,com.google.android.gms,10146
user,com.user.exempt,10750
W
  ;;
  deviceidle:*) echo false ;;
  wifi:*) : ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
cat <<'L'
package:org.thoughtcrime.securesms uid:10291
package:com.example.sync uid:10700
package:com.user.exempt uid:10750
package:com.google.android.gm uid:10760
L
S
cat > "$T/bin/am" <<'S'
#!/bin/sh
echo "$*" >> "$AM_LOG"
S
cat > "$T/bin/appops" <<'S'
#!/bin/sh
echo "No operations."
S
chmod +x "$T/bin/"*
echo "wakelock_action=1" > "$T/mod/config/governor.conf"
printf 'awake_pct_screenoff=40\nawake_window_min=90\n' > "$T/state"
# What an earlier build left behind: Signal restricted.
echo org.thoughtcrime.securesms > "$T/d/wakelock_restricted"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$SRC" > "$T/out" 2>&1

grep -qx 'set-standby-bucket org.thoughtcrime.securesms active' "$T/am.log" || f "Signal not given back"
grep -q 'set-standby-bucket org.thoughtcrime.securesms restricted' "$T/am.log" && f "Signal restricted again"
grep -q 'set-standby-bucket com.user.exempt restricted' "$T/am.log" && f "an app the user exempted from battery optimisation was restricted"
grep -q 'set-standby-bucket com.google.android.gm restricted' "$T/am.log" && f "Gmail restricted"
grep -qx 'set-standby-bucket com.example.sync restricted' "$T/am.log" || f "an ordinary cached holder was no longer restricted"
grep -qxF org.thoughtcrime.securesms "$T/d/wakelock_restricted" && f "Signal still on the restricted record"
grep -qxF com.example.sync "$T/d/wakelock_restricted" || f "the ordinary holder was not recorded for uninstall"
grep -q '^org.thoughtcrime.securesms|.*|protected$' "$T/d/wakelock_apps" || f "Signal not reported as protected"
grep -q '^com.user.exempt|.*|protected$' "$T/d/wakelock_apps" || f "exempt app not reported as protected"

# A pass that does not act (awake share under the bar) still releases a wrong restriction.
echo org.thoughtcrime.securesms > "$T/d/wakelock_restricted"; : > "$T/am.log"
printf 'awake_pct_screenoff=10\nawake_window_min=90\n' > "$T/state"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$SRC" >/dev/null 2>&1
grep -qx 'set-standby-bucket org.thoughtcrime.securesms active' "$T/am.log" || f "not released on a quiet pass"
[ -e "$T/d/wakelock_restricted" ] && f "empty record left behind"

# fix137: restrictions made under the earlier, looser rule are handed back once - an ordinary
# app included - and the marker keeps it to once.
rm -f "$T/d/wakelock_rules_v137"; echo com.example.other > "$T/d/wakelock_restricted"; : > "$T/am.log"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$SRC" >/dev/null 2>&1
grep -qx 'set-standby-bucket com.example.other active' "$T/am.log" || f "old-rule restriction not handed back"
[ -f "$T/d/wakelock_rules_v137" ] || f "migration marker not written"
echo com.example.other > "$T/d/wakelock_restricted"; : > "$T/am.log"
AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
  sh "$SRC" >/dev/null 2>&1
grep -q 'com.example.other active' "$T/am.log" && f "migration ran twice"

# fix141: apps installed on the OP15 of capture 2830 that the list missed, and Telegram
# clients without "telegram" in their id. A game or a shop stays restrictable.
sed -n '/^_wl_protected() {$/,/^}$/p' "$SRC" > "$T/prot.sh"
. "$T/prot.sh"
for p in com.mywickr.wickr2 com.truecaller com.exteragram.messenger com.radolyn.ayugram tw.nekomimi.nekogram \
         com.samsung.accessory.paranmgr com.sony.songpal.mdr com.tranzmate org.thoughtcrime.securesms; do
  _wl_protected "$p" || f "$p not protected"
done
for p in com.activision.callofduty.shooter com.alibaba.aliexpresshd com.anthropic.claude; do
  _wl_protected "$p" && f "$p protected (it is not a messenger, call, mail, map or wearable app)"
done

[ "$fail" = 0 ] || exit 1
echo "PASS wakelock messenger guard: Signal & co. and battery-exempt apps are never restricted, old restrictions released"
)

t_wakelock_trimmed_exempt_runtime() (
# Runtime (fix152): an app the Doze trim took off the exemption list is still the user's
# exempted app to the wakelock watcher.
#
# The watcher never restricts an app on Android's exemption list (fix136): the user put it
# there. The Doze trim removes exactly those apps from the list at night, so with both
# tweaks on, a VPN or a mail client the user had marked unrestricted lost that protection
# and could be moved to the restricted standby bucket - a much harsher state than Doze. The
# REAL watcher runs on mocked dumpsys / pm / am; the trim's record names the app. (A notes
# sync app, not a VPN: since fix177 a VPN is protected by name.)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wakelock trimmed exempt: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/d"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1:${2:-}" in
  batterystats:*) cat <<'B'
  All partial wake locks:
  Wake lock u0a700 SyncLoop: 1h 2m 0s 1ms (40 times) realtime
  Wake lock u0a750 Tunnel: 55m 0s 1ms (9 times) realtime
B
  ;;
  power:*) : ;;
  activity:*) cat <<'A'
  #20: cch+ 5 CEM  ----    ---- 5678:com.example.sync/u0a700
  #18: cch+ 5 CEM  ----    ---- 5680:com.user.notesync/u0a750
A
  ;;
  deviceidle:whitelist) cat <<'W'
system-excidle,com.android.providers.downloads,10035
system,com.google.android.gms,10146
W
  ;;
  deviceidle:*) echo false ;;
  wifi:*) : ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
cat <<'L'
package:com.example.sync uid:10700
package:com.user.notesync uid:10750
L
S
cat > "$T/bin/am" <<'S'
#!/bin/sh
echo "$*" >> "$AM_LOG"
S
cat > "$T/bin/appops" <<'S'
#!/bin/sh
echo "No operations."
S
chmod +x "$T/bin/"*
echo "wakelock_action=1" > "$T/mod/config/governor.conf"
printf 'awake_pct_screenoff=40\nawake_window_min=90\n' > "$T/state"
printf '%s\n' com.user.notesync 'bad;name' > "$T/d/doze_whitelist_removed"
run() { AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" sh "$SRC" > "$T/out" 2>&1; }
run
grep -q 'set-standby-bucket com.user.notesync restricted' "$T/am.log" && f "an app the Doze trim took off the list was restricted"
grep -qx 'set-standby-bucket com.example.sync restricted' "$T/am.log" || f "an ordinary cached holder was no longer restricted"
echo com.user.notesync > "$T/d/wakelock_restricted"; : > "$T/am.log"
run
grep -qx 'set-standby-bucket com.user.notesync active' "$T/am.log" || f "an earlier restriction of a trimmed app was not given back"
rm -f "$T/d/doze_whitelist_removed"; : > "$T/am.log"; rm -f "$T/d/wakelock_restricted"
run
grep -q 'set-standby-bucket com.user.notesync restricted' "$T/am.log" || f "without the trim record the guard protects nothing - the test no longer tells the two apart"
[ "$fail" = 0 ] && echo "PASS wakelock trimmed exempt: apps the Doze trim removed keep the user's exemption in the wakelock watcher"
exit "$fail"
)

t_wakelock_netpath_fgs_runtime() (
# Runtime (fix177): a VPN / proxy and an app running a foreground service are never moved to
# the restricted bucket, and one an earlier pass restricted is given back.
#
# Capture 3970 (CPH2747, fix169): com.amurcanov.tgwsproxy - a Telegram WebSocket proxy - held
# its service wakelock in 78% of the screen-off samples and was restricted, under a report
# line saying "a proxy, a VPN" is left alone. The REAL watcher runs on mocked dumpsys/pm/am.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wakelock net path / FGS: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/d"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1:${2:-}" in
  batterystats:*) cat <<'B'
  All partial wake locks:
  Wake lock u0a700 SyncLoop: 1h 2m 0s 1ms (40 times) realtime
  Wake lock u0a751 TgWsProxy::ServiceWakeLock: 32m 12s 1ms (9 times) realtime
  Wake lock u0a752 AudioMix: 40m 0s 1ms (3 times) realtime
B
  ;;
  power:*) : ;;
  activity:lru) cat <<'A'
  #20: cch+ 5 CEM  ----    ---- 5678:com.example.sync/u0a700
  #18: cch+ 5 CEM  ----    ---- 5680:com.amurcanov.tgwsproxy/u0a751
  #17: cch+ 5 CEM  ----    ---- 5681:com.badmanners.murglar2/u0a752
A
  ;;
  activity:services)
    [ "${3:-}" = com.badmanners.murglar2 ] && echo '    isForeground=true foregroundId=7 types=0x00000002'
    : ;;
  deviceidle:*) echo false ;;
  wifi:*) : ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
cat <<'L'
package:com.example.sync uid:10700
package:com.amurcanov.tgwsproxy uid:10751
package:com.badmanners.murglar2 uid:10752
L
S
printf '#!/bin/sh\necho "$*" >> "$AM_LOG"\n' > "$T/bin/am"
printf '#!/bin/sh\necho "No operations."\n' > "$T/bin/appops"
chmod +x "$T/bin/"*
echo "wakelock_action=1" > "$T/mod/config/governor.conf"
printf 'awake_pct_screenoff=40\nawake_window_min=90\n' > "$T/state"
run() { AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" sh "$SRC" > "$T/out" 2>&1; }
run
grep -q 'set-standby-bucket com.amurcanov.tgwsproxy restricted' "$T/am.log" && f "the proxy was restricted"
grep -q 'set-standby-bucket com.badmanners.murglar2 restricted' "$T/am.log" && f "an app with a running foreground service was restricted"
grep -qx 'set-standby-bucket com.example.sync restricted' "$T/am.log" || f "an ordinary cached holder was no longer restricted - the test tells nothing apart"
grep -q '^com.amurcanov.tgwsproxy|.*|protected$' "$T/d/wakelock_apps" || f "proxy verdict: $(grep tgws "$T/d/wakelock_apps")"
grep -q '^com.badmanners.murglar2|.*|in_use$' "$T/d/wakelock_apps" || f "FGS verdict: $(grep murglar "$T/d/wakelock_apps")"
# Given back: both were restricted by a fix169 pass.
printf '%s\n' com.amurcanov.tgwsproxy com.badmanners.murglar2 > "$T/d/wakelock_restricted"; : > "$T/am.log"
run
grep -qx 'set-standby-bucket com.amurcanov.tgwsproxy active' "$T/am.log" || f "the restricted proxy was not given back"
grep -qx 'set-standby-bucket com.badmanners.murglar2 active' "$T/am.log" || f "the restricted player with a foreground service was not given back"
for p in com.wireguard.android org.amnezia.vpn com.github.shadowsocks com.github.kr328.clash \
         org.torproject.android com.adguard.android io.nekohasekai.sfa app.hiddify.com \
         com.cloudflare.onedotonedotone com.romanvht.byedpi; do
  ( . /dev/null; sed -n '/^_wl_protected()/,/^}/p' "$SRC" > "$T/p.sh"; echo "_wl_protected $p" >> "$T/p.sh"; sh "$T/p.sh" ) \
    || f "$p is not protected"
done
for p in com.example.sync com.instagram.android ru.wildberries.partners; do
  ( sed -n '/^_wl_protected()/,/^}/p' "$SRC" > "$T/p.sh"; echo "_wl_protected $p" >> "$T/p.sh"; sh "$T/p.sh" ) \
    && f "$p is protected - the net-path list is too broad"
done
[ "$fail" = 0 ] && echo "PASS wakelock net path / FGS: proxies, VPNs and apps with a foreground service are never restricted, earlier restrictions given back"
exit "$fail"
)

t_wakelock_fitness_status_runtime() (
# Runtime (fix177): "no fitness apps" on a phone with Samsung Health and Renpho.
#
# The WebUI badge counted the two ledger files; with limit chosen and the ledger empty it read
# "no fitness apps". The watcher now answers fitness-status itself (installed, limit in force
# as Android reads it, ledger, ROM-ignored, refused), and reads the package's own WAKE_LOCK
# line: appops get prints a "Uid mode:" line FIRST when a per-uid mode is set, and that line
# was taken for the package's mode. A uid mode that overrides the limit is set too, on its own
# ledger, and handed back on protect and uninstall. The REAL watcher runs on a stateful appops.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wakelock fitness status: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/d"
printf '#!/bin/sh\ncase "$1" in deviceidle) echo false ;; esac\n' > "$T/bin/dumpsys"
cat > "$T/bin/pm" <<'S'
#!/bin/sh
cat <<'L'
package:com.sec.android.app.shealth uid:10493
package:com.renpho.health uid:10489
package:com.example.notes uid:10500
L
S
printf '#!/bin/sh\necho "$*" >> "$AM_LOG"\n' > "$T/bin/am"
cat > "$T/bin/appops" <<'S'
#!/bin/sh
# Stateful, with uid modes: "get" prints the uid line first, as AppOpsService does.
echo "appops $*" >> "$AM_LOG"
case "$1" in
  get) u="$(sed -n "s/^uid $2 $3 //p" "$OPS" 2>/dev/null | tail -1)"
       m="$(sed -n "s/^$2 $3 //p" "$OPS" 2>/dev/null | tail -1)"
       [ -n "$u" ] && echo "Uid mode: $3: $u"
       if [ -n "$m" ]; then echo "$3: $m; time=+1h"; elif [ -z "$u" ]; then echo "No operations."; fi ;;
  set) if [ "$2" = --uid ]; then echo "uid $3 $4 $5" >> "$OPS"; else echo "$2 $3 $4" >> "$OPS"; fi ;;
esac
S
chmod +x "$T/bin/"*
env_run() { OPS="$T/ops" AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" "$@"; }
st() { env_run sh "$SRC" fitness-status 2>/dev/null; }
fit() { printf 'wakelock_action=0\nwakelock_fitness=%s\n' "$1" > "$T/mod/config/governor.conf"; env_run sh "$SRC" fitness >/dev/null 2>&1; }
printf 'wakelock_action=0\nwakelock_fitness=limit\n' > "$T/mod/config/governor.conf"
: > "$T/ops"
o="$(st)"
printf '%s\n' "$o" | grep -qx 'installed=2' || f "installed count: $o"
printf '%s\n' "$o" | grep -qx 'preset=0' || f "preset count before limiting: $o"
printf '%s\n' "$o" | grep -qx 'names=com.sec.android.app.shealth,com.renpho.health' || f "names: $o"
grep -q 'appops set' "$T/am.log" 2>/dev/null && f "fitness-status changed an app-op"
# A uid mode "allow" sits above the package line (the suspected owner's case).
printf 'uid com.sec.android.app.shealth WAKE_LOCK allow\n' > "$T/ops"; : > "$T/am.log"
fit limit
grep -qx 'com.sec.android.app.shealth|default' "$T/d/wakelock_fitness_limited" || f "a uid line hid the package mode / limit not recorded: $(cat "$T/d/wakelock_fitness_limited" 2>/dev/null)"
grep -q 'appops set --uid com.sec.android.app.shealth WAKE_LOCK ignore' "$T/am.log" || f "the overriding uid mode was left at allow"
grep -qx 'com.sec.android.app.shealth|allow' "$T/d/wakelock_fitness_uidmode" || f "uid mode not recorded for hand-back"
grep -qx 'com.renpho.health|default' "$T/d/wakelock_fitness_limited" || f "Renpho not limited"
o="$(st)"
printf '%s\n' "$o" | grep -qx 'preset=0' || f "recorded apps counted as preset: $o"
printf '%s\n' "$o" | grep -qx 'limited=2' || f "ledger count: $o"
: > "$T/am.log"; st >/dev/null
grep -q 'appops get com.sec.android.app.shealth' "$T/am.log" && f "fitness-status asked appops about a recorded app"
: > "$T/am.log"; fit limit
grep -q 'appops set' "$T/am.log" && f "re-set ops already in force"
# protect hands back both the package and the uid mode.
: > "$T/am.log"
printf 'wakelock_action=0\nwakelock_fitness=protect\n' > "$T/mod/config/governor.conf"
env_run sh "$SRC" >/dev/null 2>&1
grep -q 'appops set --uid com.sec.android.app.shealth WAKE_LOCK allow' "$T/am.log" || f "protect did not give the uid mode back"
grep -q 'appops set com.sec.android.app.shealth WAKE_LOCK default' "$T/am.log" || f "protect did not give the package mode back"
[ -e "$T/d/wakelock_fitness_uidmode" ] && f "uid ledger kept after protect"
# Already ignored by someone else: not recorded, not re-set - but counted as in force.
printf 'com.sec.android.app.shealth WAKE_LOCK ignore\ncom.renpho.health WAKE_LOCK ignore\n' > "$T/ops"; : > "$T/am.log"
fit limit
[ -s "$T/d/wakelock_fitness_limited" ] && f "recorded apps someone else had ignored"
grep -q 'appops set' "$T/am.log" && f "re-set an externally ignored app"
printf '%s\n' "$(st)" | grep -qx 'preset=2' || f "an op in force with no record not counted: $(st)"
# A ROM that will not store the op: rolled back, said, counted as refused.
printf '#!/bin/sh\necho "appops $*" >> "$AM_LOG"\n[ "$1" = get ] && echo "No operations."\n:\n' > "$T/bin/appops"; chmod +x "$T/bin/appops"
rm -f "$T/d/wakelock_fitness_limited"; : > "$T/am.log"
fit limit
printf '%s\n' "$(st)" | grep -qx 'refused=2' || f "refused not counted: $(st)"
grep -q 'appops set com.sec.android.app.shealth WAKE_LOCK default' "$T/am.log" || f "a refused op was not rolled back"
printf 'wakelock_action=0\nwakelock_fitness=protect\n' > "$T/mod/config/governor.conf"
env_run sh "$SRC" >/dev/null 2>&1
[ -e "$T/d/wakelock_fitness_refused" ] && f "refused record kept after protect"
grep -q 'wakelock_fitness_uidmode' "$ROOT/uninstall.sh" || f "uninstall does not hand back uid modes"
grep -q "appops set --uid \"\$_fp\" WAKE_LOCK" "$ROOT/uninstall.sh" || f "uninstall uid restore"
grep -q 'asb_wakelock_watch.sh fitness-status' "$ROOT/webroot/index.html" || f "WebUI badge does not ask the watcher"
grep -q "_wlFitProbed && _wlFitInstalled === 0" "$ROOT/webroot/index.html" || f "'no fitness apps' not tied to the installed count"
[ "$fail" = 0 ] && echo "PASS wakelock fitness status: installed apps are counted, a uid line no longer hides the package mode, refused ops are rolled back and said"
exit "$fail"
)

t_wakelock_watch_runtime() (
# Runtime: the wakelock watcher resolves holders by uid on current Android formats.
#
# dumpsys power writes "(uid=10493 pid=...)" and batterystats "Wake lock u0a493 Tag: ...";
# the parsers this guards once read the tag as a package and never matched anything.
# Stubs replay those exact formats and check the ranking, the protected classes, the
# in-use exemption, the WorkSource attribution and that nothing acts while switched off.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wakelock runtime: $*" >&2; fail=1; }
mkdir -p "$T/bin" "$T/mod/config" "$T/d"
cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1" in
  batterystats) cat <<'B'
  All partial wake locks:
  Wake lock u0a493 PedometerLib:tag: 4m 4s 955ms (3 times) max=150727 actual=296015 realtime
  Wake lock u0a432 *job*e/@androidx.work.systemjobscheduler@com.duolingo/androidx.work.impl.background.systemjob.SystemJobService: 3m 10s 2ms (9 times) realtime
  Wake lock u0a700 SyncLoop: 1h 2m 0s 1ms (40 times) realtime
  Wake lock u0a800 Tiny: 30s 1ms (2 times) realtime
  Wake lock u0a147 CollectionLib-SigCollector: 9m 868ms (3 times) realtime
  Wake lock 1000 *alarm*: 5m 1ms (3 times) realtime
  Total WiFi Multicast wakelock time: 1h 2m 3s 4ms
B
  ;;
  power) cat <<'P'
    PARTIAL_WAKE_LOCK                 '*job*r/com.example.player/x.Job' ACQ=-2m2s223ms LONG (uid=1000 pid=6599 ws=WorkSource{ chains=WorkChain{(10901), (1000, JobScheduler)}})
    PARTIAL_WAKE_LOCK                 'Short' ACQ=-3s (uid=10800 pid=1)
P
  ;;
  activity) cat <<'A'
  #45: fg     TOP  LCMNFU  ---- 1234:com.android.launcher/u0a12
  #30: prcp   FGS  ----    ---- 4567:com.example.player/u0a901
  #20: cch+ 5 CEM  ----    ---- 5678:com.example.sync/u0a700
A
  ;;
  deviceidle) echo false ;;
  wifi) cat <<'W'
Multicast Locks held:
    Multicaster{mdns-discovery uid=10700}
    Multicaster{CastDiscovery uid=10950}
    Multicaster{NearbyMediums uid=1000}
W
  ;;
esac
S
cat > "$T/bin/pm" <<'S'
#!/bin/sh
cat <<'L'
package:com.sec.android.app.shealth uid:10493
package:com.duolingo uid:10432
package:com.example.sync uid:10700
package:com.example.tiny uid:10800
package:com.example.player uid:10901
package:com.example.cast uid:10950
L
S
cat > "$T/bin/am" <<'S'
#!/bin/sh
# get-standby-bucket answers from a fixture (fix137: used-today apps are left alone);
# everything else is logged as an action.
if [ "$1" = get-standby-bucket ]; then
  sed -n "s/^$2 //p" "$AM_LOG.buckets" 2>/dev/null | head -1
  exit 0
fi
echo "$*" >> "$AM_LOG"
S
cat > "$T/bin/appops" <<'S'
#!/bin/sh
# Stateful (fix100): get answers what set stored, so a denial that is still in force is
# not re-asserted, and a reset one is.
echo "appops $*" >> "$AM_LOG"
case "$1" in
  get) m="$(sed -n "s/^$2 $3 //p" "$AM_LOG.ops" 2>/dev/null | tail -1)"
       if [ -n "$m" ]; then echo "$3: $m; time=+1h"; else echo "No operations."; fi ;;
  set) echo "$2 $3 $4" >> "$AM_LOG.ops" ;;
esac
S
chmod +x "$T/bin/"*
run() {
  echo "wakelock_action=$1" > "$T/mod/config/governor.conf"
  printf 'awake_pct_screenoff=%s\nawake_window_min=90\n' "$2" > "$T/state"
  AM_LOG="$T/am.log" PATH="$T/bin:$PATH" MODDIR="$T/mod" ASB_WL_DIR="$T/d" ASB_WL_STATE="$T/state" \
    sh "$SRC" >/dev/null 2>&1
}

# Switched off: ranks and reports, changes nothing.
run 0 60
A="$T/d/wakelock_apps"
[ -s "$A" ] || f "no wakelock_apps written while report-only"
[ ! -s "$T/am.log" ] || f "acted while wakelock_action=0"
head -1 "$A" | grep -q '^com.example.sync|3720|0|report$' || f "top row wrong: $(head -1 "$A")"
grep -q '^com.sec.android.app.shealth|244|0|protected$' "$A" || f "pedometer not ranked as protected"
grep -q '^com.duolingo|190|0|report$' "$A" || f "job wakelock not charged to its app"
grep -q '^com.example.player|0|1|in_use$' "$A" || f "WorkSource LONG holder not attributed or not exempt"
grep -q 'com.example.tiny' "$A" && f "a 30 s holder must not be listed"
grep -q 'gms\|1000' "$A" && f "system or non-third-party uid listed"

M="$T/d/wakelock_multicast"
grep -qx 'total|3723' "$M" || f "multicast total over an hour not parsed: $(head -1 "$M")"
grep -qx 'com.example.sync|report' "$M" || f "cached multicast holder not resolved by uid"
grep -qx 'com.example.cast|protected' "$M" || f "cast app not protected"
grep -qx 'uid 1000|system' "$M" || f "system multicast holder not named"

# Switched on, awake share below the 25% bar: still nothing.
run 1 20
[ ! -s "$T/am.log" ] || f "acted below the awake bar"

# Switched on and over the bar: only the eligible apps are restricted, once.
printf 'com.example.sync 40\ncom.duolingo 40\n' > "$T/am.log.buckets"
run 1 40
grep -q 'set-standby-bucket com.example.sync restricted' "$T/am.log" || f "cached heavy holder not restricted"
# fix137: a 3 m 10 s job is ordinary background work - named, not restricted.
grep -q 'set-standby-bucket com.duolingo restricted' "$T/am.log" && f "a three-minute job holder was restricted"
grep -q '^com.duolingo|190|0|report$' "$A" || f "short job holder not reported"
grep -q 'shealth\|player' "$T/am.log" && f "protected or in-use app restricted"
grep -q 'appops set com.example.sync WIFI_MULTICAST ignore' "$T/am.log" || f "cached multicast holder not denied"
grep -q 'appops set com.example.cast' "$T/am.log" && f "cast app denied multicast"
grep -qx 'com.example.sync|restricted' "$M" || f "multicast verdict not restricted"
run 1 40
[ "$(grep -c 'set-standby-bucket com.example.sync' "$T/am.log")" = 1 ] && [ "$(grep -c 'appops set com.example.sync' "$T/am.log")" = 1 ] || f "restricted the same app twice"
# The system resets the op: the next pass re-asserts the denial instead of trusting the record.
echo "com.example.sync WIFI_MULTICAST default" >> "$T/am.log.ops"
run 1 40
[ "$(grep -c 'appops set com.example.sync WIFI_MULTICAST ignore' "$T/am.log")" = 2 ] || f "reset multicast denial not re-applied"
grep -q '^com.example.sync|3720|0|restricted$' "$A" || f "verdict not updated to restricted"

# fix137: an app Android says was used today (active/working_set) is never restricted.
: > "$T/am.log"; rm -f "$T/d/wakelock_restricted"
printf 'com.example.sync 10\n' > "$T/am.log.buckets"
run 1 40
grep -q 'set-standby-bucket com.example.sync restricted' "$T/am.log" && f "an app used today was restricted"
grep -q '^com.example.sync|3720|0|used_today$' "$A" || f "used-today verdict not reported"
printf 'com.example.sync 40\n' > "$T/am.log.buckets"
run 1 40

# Switched off again: everything ASB restricted is handed back and the records cleared.
: > "$T/am.log"
run 0 40
grep -q 'set-standby-bucket com.example.sync active' "$T/am.log" || f "off did not release the restricted bucket"
grep -q 'appops set com.example.sync WIFI_MULTICAST allow' "$T/am.log" || f "off did not give multicast back"
[ -f "$T/d/wakelock_restricted" ] && f "restricted record kept after off"

[ "$fail" = 0 ] && echo "PASS wakelock watcher runtime"
exit "$fail"
)

t_wakelock_watch_safety_contract() (
# Contract: screen-off wake mitigation must remain conservative and must never silently
# restrict notification-bearing messaging packages observed in real wake-source context.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wakelock_watch.sh"
fail() { echo "FAIL wakelock watcher safety: $*" >&2; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "missing [$2]"; }
absent() { ! grep -Eq -- "$2" "$1" || fail "unsafe pattern [$2]"; }

[ -f "$SRC" ] || fail 'missing runtime watcher'
sh -n "$SRC" || fail 'shell syntax'

# Measurement may run, but state-changing action remains opt-in and only after a truly long,
# demonstrably awake screen-off window; this excludes ordinary foreground/wake transients.
need "$SRC" 'case "$(_cfg wakelock_action)" in'
need "$SRC" '[ "${_win:-0}" -ge 45 ]'
need "$SRC" '[ "${_awake:-0}" -ge 25 ]'
need "$SRC" 'pm list packages -3'
need "$SRC" 'am set-standby-bucket "$_p" restricted'
absent "$SRC" 'am[[:space:]]+(force-stop|kill|crash)'

# A comment promises messaging protection. Match packages that do not literally contain
# "messaging" as well, including WhatsApp observed in Debug 6 and major common messengers.
for protected in '*whatsapp*' '*telegram*' '*signal*' '*viber*' '*discord*' '*wechat*'; do
  need "$SRC" "$protected"
done
need "$SRC" 'never auto-restrict them here'

# Kernel/system wake sources and multicast remain report-only; no attempt is made to release
# another component's wakelock directly.
need "$SRC" 'Never a kernel source, never a'
need "$SRC" 'asb_wl_relax_multicast'
absent "$SRC" 'wake_unlock'

echo 'PASS wakelock watcher safety contract'
)

t_webui_audio_release_runtime() (
# Runtime (fix130): the WebUI lets go of the audio output between sounds.
#
# The UI sounds shared one AudioContext that, once created, stayed running for the life of
# the page - an open output stream rendering silence while someone read the Monitor. An
# OP15 capture found AudioMix held for the root manager's WebView. The REAL sound block is
# cut out of index.html and run on a fake AudioContext and a fake clock: suspended 1.5 s
# after the last note, not before; a long sound (the saucer) holds it; a hidden page lets go
# at once; the next tap resumes.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
W="$ROOT/webroot/index.html"
fail() { echo "FAIL webui audio release: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP webui audio release: no node"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
_s="$(grep -n '^let _uiAudioCtx = null;$' "$W" | head -1 | cut -d: -f1)"
_e="$(grep -n '^  } catch (e) { /\* no WebAudio: stay silent \*/ }' "$W" | head -1 | cut -d: -f1)"
[ -n "$_s" ] && [ -n "$_e" ] || fail "sound block not found"
{ sed -n "${_s},${_e}p" "$W"; echo "}"; } > "$T/s.js"
grep -q 'uiAudioRelease(ctx, now + DUR + 1)' "$W" || fail "the saucer does not hold the context"
sed -n '/^const UI_SONIC = {/,/^};/p' "$W" > "$T/u.js"
[ -s "$T/u.js" ] || fail "UI_SONIC not found"
cat > "$T/run.js" <<'X'
const fs = require('fs');
let now = 0; const timers = [];
global.setTimeout = (fn, ms) => { const t = { at: now + ms / 1000, fn, live: true }; timers.push(t); return t; };
global.clearTimeout = (t) => { if (t) t.live = false; };
function advance(s) {
  const end = now + s;
  for (;;) {
    const due = timers.filter(t => t.live && t.at <= end).sort((a, b) => a.at - b.at)[0];
    if (!due) break;
    now = due.at; due.live = false; due.fn();
  }
  now = end;
}
const listeners = {};
global.document = { hidden: false, addEventListener: (k, f) => { listeners[k] = f; } };
let suspends = 0, resumes = 0;
class FakeCtx {
  constructor() { this.state = 'running'; this.destination = {}; }
  get currentTime() { return now; }
  suspend() { this.state = 'suspended'; suspends++; }
  resume() { this.state = 'running'; resumes++; }
  createOscillator() { return { frequency: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {}, start() {}, stop() {} }; }
  createGain() { return { gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {} }; }
}
global.window = { AudioContext: FakeCtx };
eval(fs.readFileSync(process.argv[2], 'utf8') + fs.readFileSync(process.argv[3], 'utf8') +
  `
  const out = [];
  uiSound('nav');
  advance(1.0); out.push('t1=' + suspends);
  advance(1.0); out.push('t2=' + suspends);
  uiSound('success'); out.push('resumed=' + resumes);
  uiAudioRelease(_uiAudioCtx, now + 11);
  uiSound('nav');
  advance(5); out.push('t3=' + suspends);
  advance(8); out.push('t4=' + suspends);
  uiSound('nav'); document.hidden = true; listeners.visibilitychange(); out.push('hidden=' + _uiAudioCtx.state);
  console.log(out.join(' '));
`);
X
r="$(node "$T/run.js" "$T/u.js" "$T/s.js")"
[ "$r" = "t1=0 t2=1 resumed=1 t3=1 t4=2 hidden=suspended" ] || fail "release timing wrong: $r"
echo "PASS webui audio release: suspended 1.5 s after the last sound, held for long sounds, released when hidden"
)

t_wifi_default_vpn_runtime() (
# Runtime (fix148): "leave bad Wi-Fi" sees Wi-Fi under a VPN.
#
# CPH2769 capture 13290: a proxy app held the default route all day ("1.1.1.1 dev tun0 table
# tun0"), Wi-Fi was up beneath it, and the watcher reported "waiting_for_wifi_default_route"
# the whole time - it never looked at the Wi-Fi it was meant to judge. The tunnel rides on the
# system default network, which netd names in its rule for unmarked local traffic with no uid
# range. The REAL function runs here against a stubbed ip(8).
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; f() { echo "FAIL wifi default vpn: $*" >&2; fail=1; }
awk '/^_wifi_default\(\) \{/ { p = 1 } p { print } p && /^}/ { exit }' "$ROOT/runtime/asb_wifi_fallback.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || { echo "FAIL wifi default vpn: _wifi_default not found" >&2; exit 1; }
mkdir -p "$T/bin"
cat > "$T/bin/ip" <<'X'
#!/bin/sh
case "$1 $2" in
  "route get") cat "$T/route" ;;
  "rule show") cat "$T/rules" ;;
esac
X
chmod 0755 "$T/bin/ip"
case_() {   # route rules-file-content -> 0/1
  printf '%s\n' "$1" > "$T/route"; printf '%s\n' "$2" > "$T/rules"
  T="$T" PATH="$T/bin:$PATH" sh -c '. "$1"; _wifi_default' x "$T/fn.sh" && echo yes || echo no
}
RULES_WIFI='0:	from all lookup local
13000:	from all fwmark 0x0/0x20000 iif lo uidrange 0-99999 lookup tun0
16000:	from all fwmark 0x10064/0x1ffff iif lo lookup wlan0
22000:	from all fwmark 0x0/0x10000 lookup legacy_system
25000:	from all fwmark 0x0/0xffff iif lo uidrange 10500-10500 lookup rmnet_data2
31000:	from all fwmark 0x0/0xffff iif lo lookup wlan0
32000:	from all unreachable'
RULES_MOBILE="$(printf '%s\n' "$RULES_WIFI" | sed 's/^31000:.*/31000:	from all fwmark 0x0\/0xffff iif lo lookup rmnet_data2/')"
[ "$(case_ '1.1.1.1 via 192.168.1.1 dev wlan0 table wlan0 src 192.168.1.9' "$RULES_MOBILE")" = yes ] || f "plain Wi-Fi route"
[ "$(case_ '1.1.1.1 dev tun0 table tun0 src 26.26.26.1 uid 0' "$RULES_WIFI")" = yes ] || f "VPN over Wi-Fi not seen as Wi-Fi"
[ "$(case_ '1.1.1.1 dev tun0 table tun0 src 26.26.26.1 uid 0' "$RULES_MOBILE")" = no ] || f "VPN over mobile data taken for Wi-Fi"
[ "$(case_ '1.1.1.1 via 10.0.0.1 dev rmnet_data2 table rmnet_data2' "$RULES_WIFI")" = no ] || f "mobile route taken for Wi-Fi (the rule is only asked behind a tunnel)"
# A per-app default (uidrange) pointing at Wi-Fi is not the system default.
RULES_APP="$(printf '%s\n' "$RULES_MOBILE" | sed 's/uidrange 10500-10500 lookup rmnet_data2/uidrange 10500-10500 lookup wlan0/')"
[ "$(case_ '1.1.1.1 dev tun0 table tun0' "$RULES_APP")" = no ] || f "a per-app Wi-Fi default read as the system default"
# The 5G-only-when-needed / screen-off LTE check asks the same rule behind a tunnel: a Wi-Fi
# that is connected but not the default keeps a default route in its own table.
awk '/^_on_mobile\(\) \{/ { p = 1 } p { print } p && /^}/ { exit }' "$ROOT/runtime/asb_lte_screenoff.sh" > "$T/om.sh"
cat > "$T/bin/ip" <<'X'
#!/bin/sh
case "$1 $2" in
  "route get") cat "$T/route" ;;
  "rule show") cat "$T/rules" ;;
  "route show") printf '%s\n' 'default via 192.168.1.1 dev wlan0 table wlan0 proto static' 'default via 10.0.0.1 dev rmnet_data2 table rmnet_data2 proto static' ;;
esac
X
chmod 0755 "$T/bin/ip"
om() { printf '%s\n' "$1" > "$T/route"; printf '%s\n' "$2" > "$T/rules"
  T="$T" PATH="$T/bin:$PATH" sh -c '_IPB=ip; . "$1"; _on_mobile' x "$T/om.sh" && echo yes || echo no; }
[ "$(om '1.1.1.1 dev tun0 table tun0' "$RULES_MOBILE")" = yes ] || f "LTE check: VPN over mobile with Wi-Fi connected read as Wi-Fi"
[ "$(om '1.1.1.1 dev tun0 table tun0' "$RULES_WIFI")" = no ] || f "LTE check: VPN over Wi-Fi read as mobile"
[ "$fail" = 0 ] && echo "PASS wifi default vpn: Wi-Fi under a tunnel recognised from netd's default-network rule"
exit "$fail"
)

t_wifi_leave_fast_confirm_runtime() (
# Runtime (fix151): once Wi-Fi starts failing, the watcher looks again in 3 s, not 8.
#
# Tester on fix150: "it leaves Wi-Fi about 10 s sooner than before, but not all the way - it
# still holds a dead access point for about 10 s". Three weak passes 8 s apart are 16-24 s
# from the first weak reading to the release. The confirmation itself is unchanged (three
# readings in a row); only the wait between them is short once a streak has begun. A strong
# link that lost validation on "unusable" keeps the 8 s cadence: that is the captive-portal
# grace. The REAL watcher runs on mocked Android commands and a sleep that records its
# argument.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wifi_fallback.sh"
fail() { echo "FAIL wifi leave fast confirm: $*" >&2; exit 1; }
T="$(mktemp -d)"
REAL_SLEEP="$(command -v sleep)"
cleanup() { [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/mod/runtime" "$T/mod/config" "$T/bin" "$T/state"
cp "$SRC" "$T/mod/runtime/asb_wifi_fallback.sh"
cat > "$T/bin/dumpsys" <<'X'
#!/bin/sh
case "$1" in power) echo 'mWakefulness=Awake' ;; wifi) cat "$ASB_WIFI_DUMP" ;; esac
X
cat > "$T/bin/settings" <<'X'
#!/bin/sh
case "$1:$2:$3" in get:global:airplane_mode_on) echo 0 ;; get:global:mobile_data) echo 1 ;; get:*) echo null ;; esac
X
cat > "$T/bin/ip" <<'X'
#!/bin/sh
[ "$1" = route ] && [ "$2" = get ] && echo '1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.9'
X
cat > "$T/bin/svc" <<'X'
#!/bin/sh
printf '%s\n' "$*" >> "$ASB_SVC_LOG"
X
cat > "$T/bin/sleep" <<X
#!/bin/sh
printf '%s\n' "\$1" >> "$T/sleeps"
exec "$REAL_SLEEP" 0.02
X
chmod 0755 "$T/bin/"*
export PATH="$T/bin:$PATH" ASB_WIFI_DUMP="$T/wifi.dump" ASB_SVC_LOG="$T/svc.log"
export ASB_WIFI_FALLBACK_STATE_DIR="$T/state" ASB_GOV_STATE="$T/gov"
printf 'state=MODERATE\nscreen=1\n' > "$T/gov"
watch_until_disable() {   # rung dump-rssi dump-validated
  printf 'radio_policy_enable=0\nnet_wifi_leave=%s\nnet_wifi_leave_dbm=-80\n' "$1" > "$T/mod/config/governor.conf"
  printf 'mWifiInfo SSID: "home", RSSI: %s, Link speed: 6Mbps\nNetworkInfo: VALIDATED=%s\n' "$2" "$3" > "$T/wifi.dump"
  rm -f "$T/svc.log" "$T/sleeps" "$T/state/"wifi_fallback.* 2>/dev/null; rm -rf "$T/state/wifi_fallback.watch.lock"
  MODDIR="$T/mod" sh "$T/mod/runtime/asb_wifi_fallback.sh" watch </dev/null >/dev/null 2>&1 &
  WPID=$!
  if [ "$1" != weak ]; then
    printf 'mWifiInfo SSID: "home", RSSI: %s, Link speed: 6Mbps\nNetworkInfo: VALIDATED=true\n' "$2" > "$T/wifi.dump"
    n=0; while ! grep -q 'fallback armed' "$T/state/wifi_fallback.log" 2>/dev/null && [ "$n" -lt 200 ]; do "$REAL_SLEEP" 0.05; n=$((n + 1)); done
    : > "$T/sleeps"
    printf 'mWifiInfo SSID: "home", RSSI: %s, Link speed: 6Mbps\nNetworkInfo: VALIDATED=%s\n' "$2" "$3" > "$T/wifi.dump"
  fi
  n=0; while ! grep -qx 'wifi disable' "$T/svc.log" 2>/dev/null && [ "$n" -lt 300 ]; do "$REAL_SLEEP" 0.05; n=$((n + 1)); done
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null || true; WPID=""
  grep -qx 'wifi disable' "$T/svc.log" 2>/dev/null
}
# 1. Walking out of range: -85 dBm, still validated. Passes 3 s apart, then the release.
watch_until_disable weak -85 true || fail "weak rung did not leave a -85 dBm link"
[ "$(head -2 "$T/sleeps" | tr '\n' ' ')" = "3 3 " ] || fail "out-of-range passes not 3 s apart: $(tr '\n' ' ' < "$T/sleeps")"
grep -q 'out of range (rssi=-85) pass 2/3' "$T/state/wifi_fallback.log" || fail "the confirmation got shorter than three readings"
# 2. aggressive, strong link without internet: also 3 s apart.
watch_until_disable aggressive -50 false || fail "aggressive rung did not leave an unvalidated link"
grep -q 'unvalidated Wi-Fi pass 1/3' "$T/state/wifi_fallback.log" || fail "aggressive skipped its confirmation"
grep -qx 3 "$T/sleeps" || fail "aggressive confirmation not fast: $(tr '\n' ' ' < "$T/sleeps")"
# 3. unusable, strong link without internet (a captive portal, a dead router): the 8 s grace stays.
watch_until_disable unusable -50 false || fail "unusable rung did not leave an unvalidated link"
grep -qx 3 "$T/sleeps" && fail "unusable lost its captive-portal grace: $(tr '\n' ' ' < "$T/sleeps")"
echo "PASS wifi leave fast confirm: 3 s between failing readings (out of range, aggressive), 8 s grace on unusable"
)

t_wifi_leave_rungs_runtime() (
# Runtime (fix134): "Leave bad Wi-Fi" works on every rung, with or without the cellular master.
#
# Field report on V65-debug6: "leave bad Wi-Fi does not seem to work - tried different
# settings, it holds the Wi-Fi to the last". The watcher only ran on "aggressive" AND only
# with radio_policy_enable=1; "weak" (card: "leave when the signal falls below -80 dBm")
# never left anything, and "unusable" never even wrote Android's avoid-bad-Wi-Fi switch from
# the card. The REAL script runs here against mocked Android commands.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/runtime/asb_wifi_fallback.sh"
fail() { echo "FAIL wifi leave rungs: $*" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'MODDIR="$TMP/mod" sh "$TMP/mod/runtime/asb_wifi_fallback.sh" stop >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/mod/runtime" "$TMP/mod/config" "$TMP/bin" "$TMP/state"
cp "$SRC" "$TMP/mod/runtime/asb_wifi_fallback.sh"
cat > "$TMP/bin/dumpsys" <<'EOF'
#!/bin/sh
case "$1" in
  power) printf '%s\n' 'mWakefulness=Awake' ;;
  wifi) cat "$ASB_WIFI_DUMP" ;;
esac
EOF
cat > "$TMP/bin/settings" <<'EOF'
#!/bin/sh
case "$1:$2:$3" in
  get:global:airplane_mode_on) echo 0 ;;
  get:global:mobile_data) echo 1 ;;
  get:*) echo null ;;
esac
EOF
cat > "$TMP/bin/ip" <<'EOF'
#!/bin/sh
[ "$1" = route ] && [ "$2" = get ] && printf '%s\n' '1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.9'
EOF
cat > "$TMP/bin/svc" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ASB_SVC_LOG"
EOF
chmod 0755 "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" ASB_WIFI_DUMP="$TMP/wifi.dump" ASB_SVC_LOG="$TMP/svc.log"
export ASB_WIFI_FALLBACK_STATE_DIR="$TMP/state" ASB_GOV_STATE="$TMP/gov_state"
run() {
  MODDIR="$TMP/mod" ASB_WIFI_FALLBACK_INTERVAL_S=1 ASB_WIFI_FALLBACK_RELEASE_S=2 \
    ASB_WIFI_FALLBACK_COOLDOWN_S=2 ASB_WIFI_FALLBACK_IDLE_INTERVAL_S=1 \
    sh "$TMP/mod/runtime/asb_wifi_fallback.sh" "$@"
}
count() { local c; c="$(grep -cx "$1" "$TMP/svc.log" 2>/dev/null || true)"; echo "${c:-0}"; }
wait_count() {   # line, at least n, tries (0.1 s)
  local n=0; while [ "$(count "$1")" -lt "$2" ] && [ "$n" -lt "${3:-150}" ]; do sleep 0.1; n=$((n + 1)); done
  [ "$(count "$1")" -ge "$2" ]
}
dump() { printf 'mWifiInfo SSID: "home", RSSI: %s, Link speed: 6Mbps\nNetworkInfo: VALIDATED=%s\n' "$1" "$2" > "$TMP/wifi.dump"; }
screen() { printf 'state=MODERATE\nscreen=%s\n' "$1" > "$TMP/gov_state"; }
# /proc/net/wireless on the host has no wlan line, so the RSSI comes from the dump fallback.

# 1. weak, cellular master OFF: a validated link at -85 dBm is left after three weak passes.
printf 'radio_policy_enable=0\nnet_wifi_leave=weak\nnet_wifi_leave_dbm=-80\n' > "$TMP/mod/config/governor.conf"
screen 1; dump -85 true
run reconcile
wait_count 'wifi disable' 1 || fail "weak rung with the master off never left a -85 dBm link"
wait_count 'wifi enable' 1 || fail "Wi-Fi not given back after the release window"
grep -q 'out of range (rssi=-85) - releasing Wi-Fi default route for 2s' "$TMP/state/wifi_fallback.log" \
  || fail "first release window is not RELEASE_S"

# 2. It comes straight back to the same weak link: the next window doubles.
wait_count 'wifi disable' 2 || fail "second release did not happen"
grep -q 'releasing Wi-Fi default route for 4s' "$TMP/state/wifi_fallback.log" || fail "release window did not double"

# 3. A new threshold applies without restarting the watcher (it was frozen at the first pass).
printf 'radio_policy_enable=0\nnet_wifi_leave=weak\nnet_wifi_leave_dbm=-90\n' > "$TMP/mod/config/governor.conf"
wait_count 'wifi enable' 2 || fail "second window not closed"
before="$(count 'wifi disable')"
sleep 4
[ "$(count 'wifi disable')" -eq "$before" ] || fail "-85 dBm released with the threshold at -90 (stale threshold)"

# 4. Screen off (governor says so): nothing is decided.
printf 'radio_policy_enable=0\nnet_wifi_leave=weak\nnet_wifi_leave_dbm=-80\n' > "$TMP/mod/config/governor.conf"
screen 0
sleep 4
[ "$(count 'wifi disable')" -eq "$before" ] || fail "released with the screen off"
# A stale governor state (older than 5 min) is not trusted: dumpsys answers (Awake).
touch -d '@1' "$TMP/gov_state" 2>/dev/null || touch -t 197001010000 "$TMP/gov_state"
wait_count 'wifi disable' $((before + 1)) || fail "a stale screen=0 kept the watcher blind"
screen 1

# 5. weak never reads validation; a strong link is kept.
run stop
rm -f "$TMP/svc.log" "$TMP/state/wifi_fallback.log"
dump -50 false
run reconcile
sleep 4
[ ! -s "$TMP/svc.log" ] || fail "weak rung acted on validation"
run stop

# 6. unusable, master OFF: an attachment that validated and then lost validation is released.
printf 'radio_policy_enable=0\nnet_wifi_leave=unusable\nnet_wifi_leave_dbm=-80\n' > "$TMP/mod/config/governor.conf"
rm -f "$TMP/svc.log" "$TMP/state/wifi_fallback.log"
dump -50 true
run reconcile
n=0; while ! grep -q 'fallback armed' "$TMP/state/wifi_fallback.log" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
dump -50 false
wait_count 'wifi disable' 1 200 || fail "unusable rung did not release an unvalidated link"
grep -q 'released unvalidated Wi-Fi default route' "$TMP/state/wifi_fallback.log" || fail "validation release not logged"

# 7. off stops the watcher.
printf 'radio_policy_enable=0\nnet_wifi_leave=off\n' > "$TMP/mod/config/governor.conf"
run reconcile
n=0; while [ -e "$TMP/state/wifi_fallback.pid" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ ! -e "$TMP/state/wifi_fallback.pid" ] || fail "off did not stop the watcher"
[ "$(run status)" = off ] || fail "status after off: $(run status)"
echo "PASS wifi leave rungs: weak/unusable work without the cellular master, windows escalate, threshold is live"
)

t_wifi_scan_rungs_contract() (
# Contract: the five wifi_scan_throttle rungs write a valid boolean plus an interval,
# and auto/unknown values write nothing.
#
# Field bug: the shipped default wifi_scan_throttle=2 fell into the "2|*)" branch, which
# wrote the rung number into the BOOLEAN key wifi_scan_throttle_enabled. A framework
# consumer reading getInt(...)==1 then saw throttling as disabled, so the default install
# ran Wi-Fi scanning unthrottled - the status screen on the reference device showed
# exactly that - while no wifi_scan_interval_ms was ever written for the rung either.
# A device that had previously been on rung 0 kept its day-long interval with throttling
# merely "on". Both keys must now be written together, per rung, and nothing at all for
# auto.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
NET="$ROOT/runtime/asb_net_apply.sh"
ACTION="$ROOT/action.sh"
CONF="$ROOT/config/governor.conf.shipped"
fail() { echo "FAIL wifi scan rungs: $*" >&2; exit 1; }
need() { grep -Fq "$2" "$1" || fail "missing [$2] in ${1#$ROOT/}"; }
absent() { grep -Fq "$2" "$1" && fail "forbidden [$2] in ${1#$ROOT/}" || true; }

[ -f "$NET" ] || fail "asb_net_apply.sh not found"

# Every rung writes the boolean and the interval together.
need "$NET" '_wt_write 1 86400000'   # 0: no background scanning
need "$NET" '_wt_write 1 600000'     # 1: every 10 minutes
need "$NET" '_wt_write 1 300000'     # 2: every 5 minutes (framework default)
need "$NET" '_wt_write 1 120000'     # 3: every 2 minutes
need "$NET" '_wt_write 0 300000'     # 4: unthrottled, interval reset for re-enable

# The rung number must never be written into the boolean key.
absent "$NET" 'wifi_scan_throttle_enabled "$_wt"'
absent "$NET" 'wifi_scan_throttle_enabled 2 '

# auto and unrecognised values touch nothing.
need "$NET" '*) : ;;'

# The write is verified by read-back, failures included.
need "$NET" 'scan_throttle=FAILED'
need "$NET" 'settings get global wifi_scan_throttle_enabled'

# The shipped default stays 2, and the documented scale matches the code.
need "$CONF" 'wifi_scan_throttle=2'
need "$CONF" '2 = every 5 minutes (framework default)'

# action.sh labels describe the rungs as they actually behave: 0 stops background
# scanning, 4 is the unthrottled one, the shipped default is named.
need "$ACTION" 'background scanning off'
need "$ACTION" 'every 5 min (framework default)'
need "$ACTION" 'unthrottled (roams sooner, costs battery)'

echo "PASS wifi scan rungs contract"
)

t_thermal_keepalive_runtime() (
# Runtime (fix166): a sleeping phone still reads its temperature now and then.
#
# Capture 29835: a 9 s face unlock at 06:20 left the die at 46 C, the screen-off cooldown engaged
# on that reading, and deep-idle economy then skipped every zone read - the state file said
# temp=46, temp_age_s=0 and thermal_cooldown=1 until 08:25 while the zones read 30-39 C, because
# the cooldown releases only on a reading. The REAL keepalive rule, cut from the governor, drives
# that night against the 40 C release: the cooldown ends within two minutes, a normal deep idle
# reads every five, never every tick; then the loop is checked to apply it after every skip rule
# and to publish the true age.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
G="$ROOT/src/asb_governor.c"
fail() { echo "FAIL thermal keepalive: $*" >&2; exit 1; }
awk '/asb_therm_keepalive_due\(time\(NULL\), g_last_thermal_read_ts, fsm.thermal_cooldown\)/{k=NR}
     /if \(fsm.plan.thermal_div > 1\) \{/{d=NR} /int deep_idle_economy = /{e=NR}
     /if \(g_quiet_wake_ramp >= 3\) \{ need_hr = 0; need_thermal = 0; \}/{r=NR}
     /metrics_read_all\(&metrics, need_hr, need_thermal\);/{m=NR}
     /metrics.therm.temp_age_s = \(int\)\(time\(NULL\) - g_last_thermal_read_ts\);/{a=NR}
     END{exit !(k && e && r && d && k > e && k > r && k > d && m > k && a > m)}' "$G" \
  || fail "the keepalive must follow every skip rule, precede the read, and the true age must follow it"
grep -q 'thermal_cooldown=%d\\ntherm_keepalive_reads=%lu\\ntemp_read_epoch=%ld\\n' "$G" || fail "keepalive reads not published"
CC=""; for c in ${HOST_CC:-} gcc clang cc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
[ -n "$CC" ] || { echo "PASS thermal keepalive (source pins only)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
awk '/^#define ASB_THERM_KEEPALIVE_S /{on=1} on{print} on&&/^static int asb_therm_keepalive_due\(/{f=1} f&&/^}$/{exit}' "$G" > "$T/k.c"
grep -q 'ASB_THERM_KEEPALIVE_COOL_S' "$T/k.c" || fail "keepalive block not found"
cat > "$T/t.c" <<'X'
#include <stdio.h>
#include <time.h>
#include "k.c"
static int zone_at(long s) { return s < 60 ? 46 : (s < 1800 ? 37 : 33); }
int main(void) {
    int bad = 0;
    time_t t0 = 1792297246, last = t0, now;
    int cool = 1, reads = 0;
    long released = -1;
    for (now = t0 + 45; now <= t0 + 2 * 3600; now += 45) {
        if (!asb_therm_keepalive_due(now, last, cool)) continue;
        reads++; last = now;
        int c = zone_at((long)(now - t0));
        if (c >= 45) cool = 1; else if (c <= 40) cool = 0;
        if (!cool && released < 0) released = (long)(now - t0);
    }
    if (released < 0 || released > 120) { printf("cooldown released at %lds, want <= 120 s\n", released); bad = 1; }
    if (reads < 20 || reads > 30) { printf("%d reads in two hours of deep idle, want one per ~5 min\n", reads); bad = 1; }
    if (!asb_therm_keepalive_due(t0, 0, 0)) { printf("never read: not due\n"); bad = 1; }
    if (!asb_therm_keepalive_due(t0 - 10, t0, 0)) { printf("clock went back: not due\n"); bad = 1; }
    if (asb_therm_keepalive_due(t0 + 59, t0, 1) || !asb_therm_keepalive_due(t0 + 60, t0, 1)) { printf("cooldown cadence\n"); bad = 1; }
    if (asb_therm_keepalive_due(t0 + 299, t0, 0) || !asb_therm_keepalive_due(t0 + 300, t0, 0)) { printf("idle cadence\n"); bad = 1; }
    if (!bad) printf("ok\n");
    return bad;
}
X
"$CC" -O1 -Wall -Wno-unused-function -Wno-unused-variable -I"$T" -o "$T/t" "$T/t.c" 2>"$T/cc.log" || { cat "$T/cc.log" >&2; fail "harness did not compile"; }
out="$("$T/t")" || { printf '%s\n' "$out" >&2; fail "keepalive wrong"; }
echo "PASS thermal keepalive: the 29835 cooldown releases within two minutes, deep idle reads every five, the published age is the real one"
)

t_action_stock_header_runtime() (
# Runtime (fix169): on Stock the action screen does not report governor settings as in force.
#
# Owner's Stock action log: "Battery tilt: 60%", "Throttling temperature: 64 C" and "night
# quiet: sensor polling slowed" - all three belong to the governor, which Stock stops. The
# REAL header and sleep lines run against a fixture config, in English and in Russian.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
A="$ROOT/action.sh"
fail() { echo "FAIL action stock header: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mod/config"
printf 'version=V65-test\n' > "$T/mod/module.prop"
printf 'smart_battery_bias=600\nsustained_temp_enter=64\nnight_quiet_enable=1\n' > "$T/mod/config/governor.conf"
for l in en ru; do
  for prof in stock balanced; do
    {
      echo "MODDIR='$T/mod'; PROFILE='$prof'; _smart_enabled=0; _rec_disabled=0; _rec_count=0"
      sed -n '/^T_[A-Z0-9_]*="[^"]*"$/p' "$A"
      [ "$l" = en ] || cat "$ROOT/runtime/i18n/action_$l.sh"
      sed -n '/^_s() {/p; /^_f() {/p' "$A"
      sed -n '/^_mver="/,/^_cfgrc="/p' "$A" | sed '$d'
      sed -n '/^\[ "\$PROFILE" = "stock" \] || case "\$(_cfg night_quiet_enable)" in$/,/^esac$/p' "$A"
    } > "$T/run.sh"
    out="$(sh "$T/run.sh" 2>&1)" || fail "$l/$prof: $out"
    case "$l/$prof" in
      en/stock)
        printf '%s\n' "$out" | grep -q 'Profile: stock — the ASB governor is stopped' || fail "no Stock line: $out"
        printf '%s\n' "$out" | grep -q 'Battery tilt\|Battery lean\|Throttling temperature\|sensor polling slowed' && fail "governor settings shown on Stock: $out" ;;
      en/balanced)
        printf '%s\n' "$out" | grep -q 'Profile: balanced (manual — Smart off)' || fail "manual line lost: $out"
        printf '%s\n' "$out" | grep -q 'Battery tilt: 60%' || fail "tilt lost off Stock: $out"
        printf '%s\n' "$out" | grep -q 'Throttling temperature: 64' || fail "throttling temperature lost off Stock: $out"
        printf '%s\n' "$out" | grep -q 'sensor polling slowed' || fail "night quiet lost off Stock: $out" ;;
      ru/stock)
        printf '%s\n' "$out" | grep -q 'регулятор ASB остановлен' || fail "no Russian Stock line: $out"
        printf '%s\n' "$out" | grep -q 'Уклон\|Температура троттлинга\|датчики опрашиваются' && fail "Russian Stock shows governor settings: $out" ;;
    esac
  done
done
for f in "$ROOT"/runtime/i18n/action_*.sh; do
  grep -q '^T_PROFILE_STOCK="[^"]*%s[^"]*"$' "$f" || fail "T_PROFILE_STOCK missing or without the profile in ${f##*/}"
done
echo "PASS action stock header: Stock names the stopped governor and drops its tilt, throttling temperature and night quiet, in every language"
)

t_eta_slot_meter_runtime() (
# Runtime (fix169): a slot estimate gives way to the screen-on drain measured in the profile.
#
# Owner's action log right after a governor start: "Time to 0% (estimate for this hour 5.0%/h)
# ~18 h 48 min with the screen on". This hour's learned drain averages whole sessions, the
# screen-off part included; Smart had measured 9-11 %/h with the screen on that same morning.
# The REAL forecast block of action.sh and the REAL WebUI helper run against fixtures.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
A="$ROOT/action.sh"
H="$ROOT/webroot/index.html"
fail() { echo "FAIL eta slot meter: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
run_eta() {
  {
    echo "PROFILE='$1'; _cap_uah=7300000"
    sed -n '/^T_[A-Z0-9_]*="[^"]*"$/p; /^U_PCTH=/p' "$A"
    sed -n '/^_s() {/p; /^_f() {/p' "$A"
    sed -n '/^_frx=\$(grep -m1 "\^forecast_rate_x10="/,/^_off_ma=\$(( _on_ma \/ 10 ))$/p' "$A" \
      | sed "s#/dev/.asb/state#$T/state#g; s#/dev/.asb_drain_meter#$T/dm#g; s#/data/adb/asb/drain_meter#$T/dm2#g"
    echo 'printf "%s|%s|%s\n" "$_eta_kind" "$_ewma_x10" "$_eta_note"'
  } > "$T/run.sh"
  sh "$T/run.sh"
}
printf 'forecast_rate_x10=50\nforecast_basis=slot\n' > "$T/state"
printf 'smart 3000 2800 0 0 0\nbalanced 0 0 0 0 0\ncurrent smart\n' > "$T/dm"
out="$(run_eta smart)"
[ "$out" = "meter|336|(measured earlier with the screen on in this profile: 33.6%/h over 50 min)" ] || fail "slot not replaced by the measured profile drain: $out"
out="$(run_eta balanced)"
[ "$out" = "slot|50|(estimate for this hour 5.0%/h)" ] || fail "a profile with no measurement must keep the slot estimate: $out"
printf 'smart 300 900 0 0 0\n' > "$T/dm"
out="$(run_eta smart)"
[ "${out%%|*}" = slot ] || fail "under 10 minutes measured is not a measurement: $out"
printf 'forecast_rate_x10=112\nforecast_basis=now\n' > "$T/state"
printf 'smart 3000 2800 0 0 0\n' > "$T/dm"
out="$(run_eta smart)"
[ "$out" = "measured|112|(actual drain 11.2%/h)" ] || fail "a live measurement must lead: $out"
printf 'forecast_rate_x10=94\nforecast_basis=recent\n' > "$T/state"
out="$(run_eta smart)"
[ "${out%%|*}" = average ] || fail "recent screen-on windows must stay ahead of the meter: $out"
for f in "$ROOT"/runtime/i18n/action_*.sh; do
  [ "$(sed -n 's/^T_ETA_METER=//p' "$f" | grep -o '%s' | wc -l)" -eq 2 ] || fail "T_ETA_METER missing or without both values in ${f##*/}"
done
command -v node >/dev/null 2>&1 || { echo "PASS eta slot meter (action only, no node)"; exit 0; }
{
  echo "function T(k, d) { return d; } let _selectedProfile = 'smart'; const _lvMeter = { p: {} };"
  for fn in lvSlotToMeter lvMeterTip; do sed -n "/^function $fn(/,/^}/p" "$H"; done
  cat <<'X'
let bad = 0; const chk = (c, m) => { if (!c) { console.log('FAIL ' + m); bad++; } };
let r = lvSlotToMeter(50, 'slot');
chk(r.basis === 'slot' && r.rate === 50, 'no meter: slot stays');
_lvMeter.p.smart = { on: 96, onMin: 47, off: 0, offN: 0 };
r = lvSlotToMeter(50, 'slot');
chk(r.basis === 'meter' && r.rate === 96 && r.min === 47, 'slot replaced by the meter: ' + JSON.stringify(r));
chk(lvSlotToMeter(112, 'now').basis === 'now' && lvSlotToMeter(94, 'recent').basis === 'recent', 'measured and recent stay');
_selectedProfile = 'battery';
chk(lvSlotToMeter(50, 'slot').basis === 'slot', 'another profile does not borrow Smart\'s figure');
chk(lvMeterTip(47).indexOf('over 47 min') > 0, 'tip names the window');
if (bad) process.exit(1);
console.log('ok');
X
} > "$T/t.js"
out="$(node "$T/t.js" 2>&1)" || fail "$out"
[ "$out" = ok ] || fail "$out"
grep -Fq "const _fPick = lvSlotToMeter(parseInt(kv.forecast_rate_x10 || '0', 10), String(kv.forecast_basis || ''));" "$H" || fail "the time to empty does not use it"
grep -Fq "const _fpk = lvSlotToMeter(parseInt(kv.forecast_rate_x10 || '0', 10), String(kv.forecast_basis || ''));" "$H" || fail "the drain tile does not use it"
python3 - "$ROOT/webroot/i18n" <<'P' || fail "eta_meter_tip"
import json, sys, pathlib
for p in sorted(pathlib.Path(sys.argv[1]).glob('*.json')):
    v = json.loads(p.read_text(encoding='utf-8')).get('eta_meter_tip', '')
    assert v.count('%s') == 1, p.name
P
echo "PASS eta slot meter: after a governor start the screen-on forecast uses the drain measured in this profile, not the slot's session average, on the action screen and in the WebUI"
)

t_logkit_screenoff_sleep_runtime() (
# Runtime (fix179): the report's "NIGHT / SCREEN-OFF CPU SLEEP" line needs ten minutes of
# screen-off time. A CPH2747 report ended seconds after an unplug and printed "0.0h realtime,
# CPU awake 0m -> awake 100.0%". The REAL function runs against a stub batterystats line.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FULL="$ROOT/tools/logkit/asb_log_full_day.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL logkit screen-off sleep: $*" >&2; exit 1; }
sed -n '/^lk_emit_screenoff_sleep() {/,/^}/p' "$FULL" > "$T/f.sh"
grep -q 'awake' "$T/f.sh" || fail "function not found"
run() { ( BS="$1"; lk_dumpsys() { printf '%s\n' "$BS"; }; . "$T/f.sh"; lk_emit_screenoff_sleep ); }
out="$(run '  Time on battery screen off: 7h 36m 0s 0ms realtime, 4h 31m 0s 0ms uptime')"
printf '%s\n' "$out" | grep -q 'screen-off: 7.6h realtime, CPU awake 271m -> awake 59.4% (deep sleep 40.6%)' || fail "a real window: $out"
out="$(run '  Time on battery screen off: 2s 300ms realtime, 2s 500ms uptime')"
printf '%s\n' "$out" | grep -q 'awake 100' && fail "two seconds read as a phone that never slept: $out"
printf '%s\n' "$out" | grep -q 'only 2s of screen-off time' || fail "short window not named: $out"
out="$(run '  Time on battery screen off: 0ms realtime, 0ms uptime')"
printf '%s\n' "$out" | grep -q 'only' && fail "an empty window read as a short one: $out"
printf '%s\n' "$out" | grep -q 'night(longest)' || fail "no pointer to the overnight figure: $out"
echo "PASS logkit screen-off sleep: Android's screen-off window is read only from ten minutes up"
)

t_logkit_multicast_by_app_runtime() (
# Runtime (fix179): the capture names who held Wi-Fi multicast, from batterystats' per-uid
# blocks. A CPH2769 total read 3 h 49 min with no holder anywhere in the capture. The REAL
# lk_wakelock_batterystats_dump runs against a stub dump.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMMON="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL logkit multicast by app: $*" >&2; exit 1; }
printf '10345 com.instagram.android\n10436 ru.vk.store\n' > "$T/uid_map.txt"
cat > "$T/dump" <<'D'
Statistics since last charge:
  Total WiFi Multicast wakelock time: 52m 58s 544ms
  1000:
    Wake lock *alarm* realtime
    WiFi Multicast Wakelock count = 12 time = 41m2s3ms
  u0a345:
    Wake lock AudioMix: 1m 2s realtime
    WiFi Multicast Wakelock count = 3 time = 11m56s541ms
  u0a999:
    Foreground services: 1s
D
out="$( ( set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$COMMON" >/dev/null 2>&1
          LK_OUT_DIR="$T"; LK_WAKELOCK_NAME=asb_logkit_test
          lk_have() { return 0; }; lk_dumpsys() { cat "$T/dump"; }; lk_wakelock_emit_report() { :; }
          lk_wakelock_batterystats_dump; cat "$T/wake_sources.txt" ) )"
sec="$(printf '%s\n' "$out" | sed -n '/^# --- Wi-Fi multicast by app/,/^$/p')"
[ -n "$sec" ] || fail "no multicast-by-app section: $out"
printf '%s\n' "$sec" | grep -qx '1000 (system): WiFi Multicast Wakelock count = 12 time = 41m2s3ms' || fail "system uid: $sec"
printf '%s\n' "$sec" | grep -qx 'u0a345 (com.instagram.android): WiFi Multicast Wakelock count = 3 time = 11m56s541ms' || fail "app uid: $sec"
printf '%s\n' "$sec" | grep -q 'Total\|u0a999' && fail "the total or an unrelated uid was listed: $sec"
echo "PASS logkit multicast by app: the capture names the Wi-Fi multicast holders per uid"
)

t_logkit_energy_model_runtime() (
# Runtime (fix179): the capture records the kernel's energy model - the power cost of every CPU
# step - so the screen-off race-to-idle floor can be judged against the silicon instead of
# argued. The REAL lk_energy_model_write runs against a fake debugfs tree.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMMON="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL logkit energy model: $*" >&2; exit 1; }
for d in cpu0/ps:960000 cpu0/ps:1401600 cpu6/ps:537600; do
  mkdir -p "$T/em/$d"; f="${d##*:}"
  echo "$f" > "$T/em/$d/frequency"; echo $(( f / 4000 )) > "$T/em/$d/power"; echo $(( f / 1000 )) > "$T/em/$d/cost"
done
run() { ( set +u; LK_SCRIPT_DIR="$ROOT/tools/logkit"; . "$COMMON" >/dev/null 2>&1
          LK_OUT_DIR="$T"; ASB_LK_EM_ROOT="$1"; lk_energy_model_write; cat "$T/energy_model.txt" ); }
out="$(run "$T/em")"
[ "$(printf '%s\n' "$out" | sed -n 2p)" = 'cpu0|960000|240|960' ] || fail "first row (steps in kHz order): $out"
printf '%s\n' "$out" | grep -qx 'cpu0|1401600|350|1401' || fail "second step: $out"
printf '%s\n' "$out" | grep -qx 'cpu6|537600|134|537' || fail "second domain: $out"
out="$(run "$T/none")"
printf '%s\n' "$out" | grep -qx 'unavailable' || fail "missing debugfs not said: $out"
grep -q '^  lk_energy_model_write$' "$COMMON" || fail "the capture start does not write the energy model"
echo "PASS logkit energy model: the per-step CPU power table is in the capture where the kernel exposes it"
)

t_logkit_audiomix_summary_runtime() (
# Runtime (fix181): the report's AudioMix holders are data rows only, and a shared system uid
# is named once. CPH2691 capture 8952 printed the header as a holder ("uid|package=
# worksource_uid|package") and uid 1000 as a list of every package sharing it.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FULL="$ROOT/tools/logkit/asb_log_full_day.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL logkit audiomix summary: $*" >&2; exit 1; }
sed -n '/^lk_emit_audiomix_summary() {/,/^}/p' "$FULL" > "$T/f.sh"
grep -q 'AUDIOMIX LIVE ATTRIBUTION' "$T/f.sh" || fail "function not found"
grep -q '^  lk_emit_audiomix_summary$' "$FULL" || fail "the report does not print it"
cat > "$T/audio_wakelock_attribution.tsv" <<'D'
# AudioMix attribution — voluntary debug capture only
# epoch|iso_time|worksource_uid|package|power_manager_hold
1792445836|t|10596|com.google.android.youtube|PARTIAL_WAKE_LOCK 'AudioMix'
1792445883|t|10596|com.google.android.youtube|PARTIAL_WAKE_LOCK 'AudioMix'
1792445900|t|1000|android,com.android.DeviceAsWebcam,com.android.dynsystem|PARTIAL_WAKE_LOCK 'AudioMix'
1792445950|t|10088|com.a,com.b|PARTIAL_WAKE_LOCK 'AudioMix'
D
out="$( LK_OUT_DIR="$T"; . "$T/f.sh"; lk_emit_audiomix_summary )"
printf '%s\n' "$out" | grep -q 'worksource_uid' && fail "the header was counted: $out"
printf '%s\n' "$out" | grep -qx 'samples=2  uid|package=10596|com.google.android.youtube' || fail "app row: $out"
printf '%s\n' "$out" | grep -qx 'samples=1  uid|package=1000|system' || fail "system uid: $out"
printf '%s\n' "$out" | grep -qx 'samples=1  uid|package=10088|com.a (shared uid)' || fail "shared app uid: $out"
printf '%s\n' "$out" | grep -q 'DeviceAsWebcam' && fail "the shared-uid package list was printed: $out"
head -2 "$T/audio_wakelock_attribution.tsv" > "$T/h"; mv "$T/h" "$T/audio_wakelock_attribution.tsv"
out="$( LK_OUT_DIR="$T"; . "$T/f.sh"; lk_emit_audiomix_summary )"
printf '%s\n' "$out" | grep -q 'no AudioMix partial wakelock observed' || fail "headers alone read as samples: $out"
echo "PASS logkit audiomix summary: data rows only, a shared system uid named once"
)

t_shell_caps_publish_runtime() (
# Runtime (fix182): the manual-profile caps service.sh writes are recorded for the governor,
# asbdiag and the logkit, and the screen-off rung is not left behind with the governor up.
# OP15 Battery capture 25307: the governor had no idea what the shell wrote and called the
# profile's own 1785600/1747200 a vendor clamp all day. The REAL functions are cut out of
# service.sh and run against a fake cpufreq tree.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
S="$ROOT/service.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL shell caps publish: $*" >&2; exit 1; }
{
  sed -n '/^asb_freq_pick_pct() {/,/^}/p' "$S"
  sed -n '/^asb_cap_want_for_policy() {/,/^}/p' "$S"
  sed -n '/^apply_cpufreq_caps() {/,/^}/p' "$S" | sed "s#/sys/devices/system/cpu/cpufreq#$T/cpufreq#g"
  sed -n '/^asb_shell_caps_publish() {/,/^}/p' "$S"
  sed -n '/^asb_cap_dev() {/,/^}/p' "$S"
  sed -n '/^asb_manual_cap_pct() {/,/^}/p' "$S"
  sed -n '/^asb_shell_caps_precompute() {/,/^}/p' "$S" | sed "s#/sys/devices/system/cpu/cpufreq#$T/cpufreq#g"
  sed -n '/^apply_screen_aware_caps() {/,/^}/p' "$S"
} > "$T/f.sh"
grep -q 'asb_shell_caps_precompute "$_dev"' "$T/f.sh" || fail "apply_screen_aware_caps does not precompute the manual rungs"
grep -q 'asb_shell_caps_publish "$_shcaps"' "$T/f.sh" || fail "apply_cpufreq_caps does not publish"
grep -q '_rung_note=' "$T/f.sh" || fail "no screen-off rung guard"
mk() {  # policy id, related_cpus, hw max, available
  d="$T/cpufreq/policy$1"; mkdir -p "$d"
  echo "$2" > "$d/related_cpus"; echo "$3" > "$d/cpuinfo_max_freq"; echo 300000 > "$d/cpuinfo_min_freq"
  echo "$4" > "$d/scaling_available_frequencies"; echo "$3" > "$d/scaling_max_freq"; echo 300000 > "$d/scaling_min_freq"
}
mk 0 "0 1 2 3 4 5" 3628800 "300000 1440000 1785600 1900800 3628800"
mk 6 "6 7" 4608000 "300000 1152000 1632000 1747200 1862400 4608000"
cat > "$T/stubs.sh" <<X
little_end=5
CPU_MIN_LITTLE=300000; CPU_MIN_BIG=300000
ASB_SHELL_CAPS_FILE="$T/shell_cpu_caps"
writef_retry() { printf '%s\n' "\$2" > "\$1"; [ -n "\${ROUND_UP:-}" ] && case "\$1" in *policy6/scaling_max_freq) echo 1862400 > "\$1" ;; esac; [ -n "\${CLAMP:-}" ] && case "\$1" in *policy0/scaling_max_freq) echo 1440000 > "\$1" ;; esac; if [ -n "\${HOLD:-}" ]; then case "\$1" in *policy0/scaling_max_freq) echo 1555200 > "\$1" ;; *policy6/scaling_max_freq) echo 1632000 > "\$1" ;; *) return 0 ;; esac; return 1; fi; return 0; }
asb_pick_nearest_freq() { echo "\$2"; }
asb_log() { echo "\$*" >> "$T/log"; }
asb_load_profile() { :; }
asb_feature_enabled() { return 0; }
getprop() { [ "\$1" = ro.board.platform ] && echo canoe; return 0; }
asb_screen_on() { [ "\${SCREEN:-1}" = 1 ]; }
asb_governor_running() { [ "\${GOV:-0}" = 1 ]; }
X
run() { ( . "$T/stubs.sh"; . "$T/f.sh"; ASB_PROFILE=battery; PROFILE=battery; apply_screen_aware_caps ) ; }
SCREEN=1 GOV=1 run
grep -qx 'profile=battery' "$T/shell_cpu_caps" || fail "profile not recorded: $(cat "$T/shell_cpu_caps")"
grep -qx 'screen_on=1' "$T/shell_cpu_caps" || fail "screen rung not recorded"
grep -qx 'policy0=1785600' "$T/shell_cpu_caps" || fail "main cap: $(cat "$T/shell_cpu_caps")"
grep -qx 'policy6=1747200' "$T/shell_cpu_caps" || fail "prime cap: $(cat "$T/shell_cpu_caps")"
ls "$T"/shell_cpu_caps.tmp.* >/dev/null 2>&1 && fail "temp file left behind"
# screen off with the governor running: the screen-on rung stays (nothing would restore it)
SCREEN=0 GOV=1 run
[ "$(cat "$T/cpufreq/policy6/scaling_max_freq")" = 1747200 ] || fail "screen-off rung written with the governor up: $(cat "$T/cpufreq/policy6/scaling_max_freq")"
tail -1 "$T/log" | grep -q 'governor is running and nothing would restore the screen-on rung' || fail "rung note not logged: $(tail -1 "$T/log")"
# screen off without the governor: reconcile follows the screen, so the rung applies
SCREEN=0 GOV=0 run
[ "$(cat "$T/cpufreq/policy6/scaling_max_freq")" = 1152000 ] || fail "screen-off rung (25 %) not applied without the governor: $(cat "$T/cpufreq/policy6/scaling_max_freq")"
grep -qx 'screen_on=0' "$T/shell_cpu_caps" || fail "screen-off rung not recorded"
# a kernel that rounds the request up: the read-back is ours
SCREEN=1 GOV=1 ROUND_UP=1 run
grep -qx 'policy6=1862400' "$T/shell_cpu_caps" || fail "rounded-up read-back not recorded: $(cat "$T/shell_cpu_caps")"
# a clamp already in place when the shell writes: the request is recorded, not the clamp
SCREEN=1 GOV=1 CLAMP=1 run
grep -qx 'policy0=1785600' "$T/shell_cpu_caps" || fail "a vendor clamp was recorded as the shell's cap: $(cat "$T/shell_cpu_caps")"
# fix189: an uncapped Balanced under the vendor's boot clamp - every write reads back lower and
# writef_retry gives up - still records the request. An empty record hid the precomputed rung
# from the governor, and Balanced kept 1555200/1862400 for a whole capture.
( . "$T/stubs.sh"; . "$T/f.sh"; ASB_PROFILE=balanced; PROFILE=balanced; SCREEN=1; GOV=1; HOLD=1; apply_screen_aware_caps )
grep -qx 'profile=balanced' "$T/shell_cpu_caps" && grep -qx 'policy0=3628800' "$T/shell_cpu_caps" && grep -qx 'policy6=4608000' "$T/shell_cpu_caps" \
  || fail "a request held lower by a clamp was not recorded: $(cat "$T/shell_cpu_caps")"
# fix183: every manual profile's screen-on rung is precomputed - also when Smart runs, and
# without writing a ceiling.
grep -qx 'policy6=1747200' "$T/shell_cpu_caps.battery" || fail "battery rung: $(cat "$T/shell_cpu_caps.battery" 2>&1)"
grep -qx 'policy0=3628800' "$T/shell_cpu_caps.balanced" || fail "OP15 balanced is uncapped on screen-on: $(cat "$T/shell_cpu_caps.balanced" 2>&1)"
rm -f "$T"/shell_cpu_caps*
echo 2400000 > "$T/cpufreq/policy0/scaling_max_freq"
( . "$T/stubs.sh"; . "$T/f.sh"; ASB_PROFILE=smart; PROFILE=smart; SCREEN=1; apply_screen_aware_caps )
[ -f "$T/shell_cpu_caps.battery" ] && [ -f "$T/shell_cpu_caps.balanced" ] || fail "Smart boot did not precompute the manual rungs"
[ -f "$T/shell_cpu_caps" ] && fail "Smart wrote a manual record"
[ "$(cat "$T/cpufreq/policy0/scaling_max_freq")" = 2400000 ] || fail "the precompute wrote a ceiling under Smart"
# the per-device tables (multi-device): OP13 battery 58/48, OP12 4 clusters with a MID rung
( . "$T/stubs.sh"; . "$T/f.sh"; asb_manual_cap_pct battery 1 op13; echo "$_P_CPUCAP_L/$_P_CPUCAP_B" ) | grep -qx '58/48' || fail "OP13 battery table"
( . "$T/stubs.sh"; . "$T/f.sh"; asb_manual_cap_pct balanced 1 op15; echo "[$_P_CPUCAP_L/$_P_CPUCAP_B]" ) | grep -qx '\[/\]' || fail "OP15 balanced screen-on must stay uncapped"
( . "$T/stubs.sh"; . "$T/f.sh"; asb_manual_cap_pct smart 1 op15 ) && fail "smart is not a shell-capped profile"
rm -rf "$T/cpufreq"
mk 0 "0 1" 2265600 "300000 1132800 1363200 2265600"
mk 2 "2 3 4" 3148800 "300000 1574400 2457600 2496000 3148800"
mk 5 "5 6" 2956800 "300000 1478400 2265600 2323200 2956800"
mk 7 "7" 3302400 "300000 1497600 1555200 3302400"
cat >> "$T/stubs.sh" <<'X'
little_end=1
getprop() { [ "$1" = ro.board.platform ] && echo pineapple; return 0; }
X
( . "$T/stubs.sh"; . "$T/f.sh"; ASB_PROFILE=smart; PROFILE=smart; SCREEN=1; apply_screen_aware_caps )
# OP12 battery 60/45, MID halfway: 60 + 40/2 = 80 %
grep -qx 'policy0=1363200' "$T/shell_cpu_caps.battery" || fail "OP12 little: $(cat "$T/shell_cpu_caps.battery")"
grep -qx 'policy2=2496000' "$T/shell_cpu_caps.battery" && grep -qx 'policy5=2323200' "$T/shell_cpu_caps.battery" || fail "OP12 mids (80 %): $(cat "$T/shell_cpu_caps.battery")"
grep -qx 'policy7=1497600' "$T/shell_cpu_caps.battery" || fail "OP12 prime (45 %): $(cat "$T/shell_cpu_caps.battery")"
echo "PASS shell caps publish: per-policy record, screen-off rung only where something lifts it again"
)

t_logkit_shell_cap_reference_runtime() (
# Runtime (fix182): in a manual profile the logkit measures throttling and cap_verify against
# what the shell wrote. OP15 Battery capture 25307 logged all 224 samples as throttled (the
# shell's 1747200 prime under the governor's unsent 1862400 rail) and cap_verify compared
# against a legacy 921600 nothing writes.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FULL="$ROOT/tools/logkit/asb_log_full_day.sh"; COM="$ROOT/tools/logkit/_asb_logkit_common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL logkit shell cap reference: $*" >&2; exit 1; }
{
  sed -n '/^lk_state_kv() {/,/^}/p' "$COM"
  sed -n '/^lk_cap_cause() {/,/^}/p' "$COM"
  sed -n '/^lk_throttle_row() {/,/^}/p' "$FULL" | sed "s#/sys/devices/system/cpu/cpufreq/policy0#$T/policy0#g"
  sed -n '/^lk_emit_cap_ownership_verdict() {/,/^}/p' "$FULL"
  sed -n '/^lk_verify_caps() {/,/^}/p' "$COM" | sed "s#/sys/devices/system/cpu/cpufreq#$T/cpufreq#g"
} > "$T/f.sh"
grep -q 'lk_throttle_row' "$T/f.sh" && grep -q 'lk_verify_caps' "$T/f.sh" || fail "functions not found"
mkdir -p "$T/policy0" "$T/policy6" "$T/cpufreq" "$T/mod/profiles"
ln -s "$T/policy0" "$T/cpufreq/policy0"; ln -s "$T/policy6" "$T/cpufreq/policy6"
echo "0 1 2 3 4 5" > "$T/policy0/related_cpus"; echo "6 7" > "$T/policy6/related_cpus"
echo 3628800 > "$T/policy0/cpuinfo_max_freq"; echo 4608000 > "$T/policy6/cpuinfo_max_freq"
echo battery > "$T/mod/current_profile"
printf 'CPU_CAP_BIG=921600\nCPU_CAP_LITTLE=921600\n' > "$T/mod/profiles/battery.sh"
cat > "$T/state" <<'D'
desired_cpu_max0=1555200
desired_cpu_maxp=1862400
desired_cpu_max_prime=1862400
requested_cpu_max0=0
requested_cpu_max_prime=0
cap_writer=shell
shell_cpu_max0=1785600
shell_cpu_max_prime=1747200
D
printf 'profile=battery\nscreen_on=1\nts=1\npolicy0=1785600\npolicy6=1747200\n' > "$T/shell_cpu_caps"
run() {
  ( LK_OUT_DIR="$T"; LK_PRIME_POL="$T/policy6"; LK_P0_HWMAX=3628800; LK_P6_HWMAX=4608000; LK_PH_THROTTLE=0
    MODDIR="$T/mod"; ASB_LK_STATE_FILE="$T/state"; ASB_SHELL_CAPS_FILE="$T/shell_cpu_caps"
    . "$T/f.sh"
    lk_status_json() { printf '{"temp":40,"surface_hotspot":38,"headroom_invalid_reason":"%s","cap_owner":"%s","perf_cap_p0":2361600,"perf_cap_p6":1632000,"cap_source_p0":"shell_applied","cap_source_p6":"%s"}' "${HIR:-ok}" "${OWN:-shell}" "${SRC:-shell_applied}"; }
    "$@" )
}
echo 1785600 > "$T/policy0/scaling_max_freq"; echo 1747200 > "$T/policy6/scaling_max_freq"
run lk_throttle_row active
[ -s "$T/throttle_trace.txt" ] && fail "the profile's own cap was logged as a throttle: $(cat "$T/throttle_trace.txt")"
echo 1632000 > "$T/policy6/scaling_max_freq"
OWN=vendor SRC=vendor_clamp run lk_throttle_row active
grep -q 'prime_by=vendor|writer=shell' "$T/throttle_trace.txt" || fail "a clamp under the shell cap: $(cat "$T/throttle_trace.txt")"
grep -q 'main_by=-' "$T/throttle_trace.txt" || fail "main at the shell cap is not under it: $(cat "$T/throttle_trace.txt")"
out="$(run lk_emit_cap_ownership_verdict)"
printf '%s\n' "$out" | grep -q 'sample(s) were taken in a manual profile' || fail "manual-profile note missing: $out"
# shell rows count as ASB's own, not foreign
printf '%s\n' "$(cut -d'|' -f1-6 "$T/throttle_trace.txt")|cap_owner=shell|main_by=vendor|prime_by=-|writer=shell" > "$T/x"
cat "$T/x" "$T/x" "$T/x" > "$T/throttle_trace.txt"
out="$(run lk_emit_cap_ownership_verdict)"
printf '%s\n' "$out" | grep -q 'foreign cap ownership dominated' && fail "the shell was counted as a foreign owner: $out"
# fix186: in Smart, ASB's own msm_performance registration under its scaling_max_freq is
# ASB's (headroom reason own_cap, node value == live), not the vendor's.
cat > "$T/state" <<'D'
desired_cpu_max0=1996800
desired_cpu_max_prime=1862400
requested_cpu_max0=1996800
requested_cpu_max_prime=1862400
cap_writer=asb
D
: > "$T/throttle_trace.txt"
echo 1996800 > "$T/policy0/scaling_max_freq"; echo 1632000 > "$T/policy6/scaling_max_freq"
HIR=own_cap OWN=asb SRC=asb_dynamic run lk_throttle_row active
grep -q 'prime_by=asb_msm|writer=asb' "$T/throttle_trace.txt" || fail "ASB's msm registration blamed on the vendor: $(cat "$T/throttle_trace.txt")"
: > "$T/throttle_trace.txt"
HIR=ok OWN=asb SRC=asb_dynamic run lk_throttle_row active
grep -q 'prime_by=vendor|writer=asb' "$T/throttle_trace.txt" || fail "a real foreign ceiling lost its owner: $(cat "$T/throttle_trace.txt")"
# cap_verify: the shell's values are the expectation, the legacy 921600 is not
cat > "$T/state" <<'D'
desired_cpu_max0=1555200
desired_cpu_maxp=1862400
desired_cpu_max_prime=1862400
requested_cpu_max0=0
requested_cpu_max_prime=0
cap_writer=shell
shell_cpu_max0=1785600
shell_cpu_max_prime=1747200
D
echo 1785600 > "$T/policy0/scaling_max_freq"
echo 1747200 > "$T/policy6/scaling_max_freq"
run lk_verify_caps
grep -q 'cap_writer: shell' "$T/cap_verify.txt" || fail "cap_verify does not say who writes: $(cat "$T/cap_verify.txt")"
grep -q 'policy0 (MAIN).*profile_expected=1785600.*ok (shell-applied)' "$T/cap_verify.txt" || fail "main: $(cat "$T/cap_verify.txt")"
grep -q 'policy6 (BIG(prime)).*profile_expected=1747200.*ok (shell-applied)' "$T/cap_verify.txt" || fail "prime: $(cat "$T/cap_verify.txt")"
grep -q 'DESYNC' "$T/cap_verify.txt" && fail "DESYNC against values nobody wrote: $(cat "$T/cap_verify.txt")"
echo "PASS logkit shell cap reference: manual-profile throttle and cap_verify use the shell's own ceilings"
)

t_lsposed_verbose_runtime() (
# Runtime (fix187, sweep added in fix197): LSPosed's verbose log, switched only on request.
#
# A user's LSPosed had 31 MB of verbose logs. The REAL C helper (asb --lspd, src/asb_lspd.h)
# runs against a real SQLite database laid out like LSPosed's modules_config.db (host
# libsqlite3 in place of Android's libsqlite.so), and the REAL runtime/asb_lsposed.sh drives
# it: off writes LSPosed's own Boolean false, keeps the newest verbose log and deletes the
# rest, empties the modules log (it has no switch - the sweep empties it again every ten
# minutes from service.sh's loop while the card says off), remembers what LSPosed had; keep
# puts that back (no row = LSPosed's default); a database of another layout is never
# touched; status says whether a write is still waiting for the reboot LSPosed needs.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL lsposed verbose: $*" >&2; exit 1; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP lsposed verbose: no C compiler"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP lsposed verbose: no python3"; exit 0; }
python3 -c 'import sqlite3' 2>/dev/null || { echo "SKIP lsposed verbose: no sqlite3 module"; exit 0; }
LIB="$(python3 -c 'import ctypes.util; print(ctypes.util.find_library("sqlite3") or "")')"
[ -n "$LIB" ] || { echo "SKIP lsposed verbose: no libsqlite3 on this host"; exit 0; }
G="$ROOT/src/asb_governor.c"
grep -Fq 'if (argc >= 3 && strcmp(argv[1], "--lspd") == 0) return asb_lspd_cli(argc - 2, argv + 2);' "$G" || fail "the governor binary does not answer --lspd"
grep -q '^lsposed_verbose=keep$' "$ROOT/config/governor.conf" || fail "not shipped as keep"
grep -q "if (key === 'lsposed_verbose') {" "$ROOT/webroot/index.html" || fail "the card does not run the script"
grep -qE 'asb_lsposed\.sh"?\s+apply\b' "$ROOT/service.sh" && fail "the switch must never run at boot"
# fix197: the setting is still never written at boot - what runs is the sweep loop, which
# only empties the logs, and only while the card says off.
grep -q 'asb_lsposed.sh" sweep' "$ROOT/service.sh" || fail "no modules-log sweep loop in service.sh"
cat > "$T/m.c" <<C
#define ASB_LSPD_SQLITE_LIB "$LIB"
#include "$ROOT/src/asb_lspd.h"
int main(int argc, char **argv) { if (argc >= 3 && strcmp(argv[1], "--lspd") == 0) return asb_lspd_cli(argc - 2, argv + 2); return 9; }
C
mkdir -p "$T/bin"; "$CC" -std=gnu11 -Wall -Werror -o "$T/bin/asb" "$T/m.c" -ldl || fail "helper does not compile"
mk_db() {
  python3 - "$1" "$2" <<'P'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
if sys.argv[2] == 'lspd':
    db.executescript("""
CREATE TABLE modules (mid integer PRIMARY KEY AUTOINCREMENT, module_pkg_name text NOT NULL UNIQUE, apk_path text NOT NULL, enabled BOOLEAN DEFAULT 0);
CREATE TABLE configs (module_pkg_name text NOT NULL, user_id integer NOT NULL, `group` text NOT NULL, `key` text NOT NULL, data blob NOT NULL,
  PRIMARY KEY (module_pkg_name, user_id, `group`, `key`));
INSERT INTO modules (module_pkg_name, apk_path, enabled) VALUES ('lspd', '/x', 1);
INSERT INTO configs VALUES ('lspd', 0, 'config', 'misc_path', X'ACED0005740004666F6F');
""")
else:
    db.executescript("CREATE TABLE settings (k text, v text); INSERT INTO settings VALUES ('enable_verbose_log', '1');")
db.commit()
P
}
row() { python3 -c "
import sqlite3,sys; db=sqlite3.connect('$1')
r=db.execute(\"SELECT hex(data) FROM configs WHERE module_pkg_name='lspd' AND user_id=0 AND \`group\`='config' AND \`key\`='enable_verbose_log'\").fetchone()
print(r[0] if r else 'none')"; }
D="$T/lspd/config/modules_config.db"; mkdir -p "$T/lspd/config" "$T/lspd/log" "$T/state" "$T/mod/config"
mk_db "$D" lspd
[ "$("$T/bin/asb" --lspd verbose-get "$D")" = "verbose=default_on
format=v1" ] || fail "no row is LSPosed's default (on, schema named)"
out="$("$T/bin/asb" --lspd verbose-set off "$D")"; printf '%s\n' "$out" | grep -qx 'verbose=off' || fail "set off: $out"
printf '%s\n' "$out" | grep -qx 'before=default_on' || fail "before: $out"
[ "$(row "$D")" = "ACED0005737200116A6176612E6C616E672E426F6F6C65616ECD207280D59CFAEE0200015A000576616C7565787000" ] || fail "not Java's Boolean false: $(row "$D")"
"$T/bin/asb" --lspd verbose-set on "$D" >/dev/null; [ "$("$T/bin/asb" --lspd verbose-get "$D")" = "verbose=on
format=v1" ] || fail "set on (schema named)"
"$T/bin/asb" --lspd verbose-unset "$D" >/dev/null; [ "$(row "$D")" = none ] || fail "unset left a row"
python3 -c "import sqlite3; db=sqlite3.connect('$D'); assert db.execute(\"SELECT count(*) FROM configs WHERE \`key\`='misc_path'\").fetchone()[0]==1" || fail "another row was touched"
mk_db "$T/other.db" other
out="$("$T/bin/asb" --lspd verbose-set off "$T/other.db" || true)"
printf '%s\n' "$out" | grep -q 'reason=unexpected_schema' || fail "another layout was not refused: $out"
python3 -c "import sqlite3; db=sqlite3.connect('$T/other.db'); assert db.execute('SELECT v FROM settings').fetchone()[0]=='1'" || fail "a foreign database was written"
out="$("$T/bin/asb" --lspd verbose-get "$T/none.db" || true)"; printf '%s\n' "$out" | grep -q 'reason=no_database' || fail "missing db: $out"
# The script, as the card runs it.
for i in 1 2 3; do head -c 2048 /dev/zero > "$T/lspd/log/verbose_2026-10-1${i}T10_00_00.log"; touch -d "2026-10-1${i} 10:00" "$T/lspd/log/verbose_2026-10-1${i}T10_00_00.log"; done
head -c 1024 /dev/zero > "$T/lspd/log/modules_2026-10-13T10_00_00.log"
mkdir -p "$T/lspd/log.old"; head -c 1024 /dev/zero > "$T/lspd/log.old/verbose_2026-10-10T10_00_00.log"
head -c 1024 /dev/zero > "$T/lspd/log.old/modules_2026-10-10T10_00_00.log"
run() { ( MODDIR="$T/mod" ASB_CONF="$T/mod/config/governor.conf" ASB_LSPD_DIR="$T/lspd" ASB_LSPD_PREV="$T/asb/prev" ASB_GOV_BIN="$T/bin/asb" sh "$ROOT/runtime/asb_lsposed.sh" "$@" ); }
echo 'lsposed_verbose=off' > "$T/mod/config/governor.conf"
out="$(run apply)"; printf '%s\n' "$out" | grep -q '^result=off_after_reboot freed_kib=7$' || fail "apply off: $out"
[ -f "$T/lspd/log/verbose_2026-10-13T10_00_00.log" ] || fail "the newest verbose log (held open) was deleted"
# Emptied, not deleted (fix189): LSPosed deletes the eldest of this boot's files itself, and a
# file already gone stalls that for the rest of the boot.
[ -f "$T/lspd/log/verbose_2026-10-11T10_00_00.log" ] && [ ! -s "$T/lspd/log/verbose_2026-10-11T10_00_00.log" ] \
  && [ -f "$T/lspd/log/verbose_2026-10-12T10_00_00.log" ] && [ ! -s "$T/lspd/log/verbose_2026-10-12T10_00_00.log" ] || fail "old verbose logs not emptied in place"
[ -s "$T/lspd/log/verbose_2026-10-13T10_00_00.log" ] || fail "the newest verbose log was emptied"
[ ! -f "$T/lspd/log.old/verbose_2026-10-10T10_00_00.log" ] || fail "the previous boot's verbose log kept"
# fix197: the modules log has no switch in LSPosed, so off keeps it clean as well - every
# file emptied in place, the newest included (the daemon appends; a truncated file simply
# grows again), and the previous boot's deleted like the verbose ones.
[ -f "$T/lspd/log/modules_2026-10-13T10_00_00.log" ] && [ ! -s "$T/lspd/log/modules_2026-10-13T10_00_00.log" ] || fail "the modules log not emptied in place"
[ ! -f "$T/lspd/log.old/modules_2026-10-10T10_00_00.log" ] || fail "the previous boot's modules log kept"
[ "$(cat "$T/asb/prev")" = default_on ] || fail "LSPosed's earlier value not remembered"
out="$(run apply)"; printf '%s\n' "$out" | grep -q '^result=already_off' || fail "second apply: $out"
[ "$(cat "$T/asb/prev")" = default_on ] || fail "the remembered value was overwritten by ASB's own"
out="$(run status)"; printf '%s\n' "$out" | grep -qx 'verbose=off' && printf '%s\n' "$out" | grep -qx 'present=1' || fail "status: $out"
# fix213 (audit K8): the status passes the parsed schema version through to the WebUI.
printf '%s\n' "$out" | grep -qx 'format=v1' || fail "status does not name the schema: $out"
printf '%s\n' "$out" | grep -qx 'modules_kib=0' && printf '%s\n' "$out" | grep -qx 'oldlog_kib=0' || fail "the modules log is not reported apart: $out"
# Written during this boot: the daemon still runs with the old value, the card must say so.
printf '%s\n' "$out" | grep -qx 'pending_reboot=1' || fail "a write from this boot is not reported as waiting for a reboot: $out"
echo 1000 > "$T/asb/prev_at"
run status | grep -qx 'pending_reboot=0' || fail "a write from before this boot still reads as pending"
# Uninstall puts LSPosed's value back whatever the card says.
grep -q 'asb_lsposed.sh" restore' "$ROOT/uninstall.sh" || fail "uninstall leaves LSPosed's setting changed"
out="$(run restore)"; printf '%s\n' "$out" | grep -q '^result=restored prev=default_on' || fail "restore: $out"
[ "$(row "$D")" = none ] && [ ! -f "$T/asb/prev" ] || fail "restore did not put LSPosed's default back"
out="$(run apply)"; printf '%s\n' "$out" | grep -q '^result=off_after_reboot' || fail "off again: $out"
echo 'lsposed_verbose=keep' > "$T/mod/config/governor.conf"
out="$(run apply)"; printf '%s\n' "$out" | grep -q '^result=restored prev=default_on' || fail "keep: $out"
[ "$(row "$D")" = none ] && [ ! -f "$T/asb/prev" ] || fail "LSPosed's default not put back"
out="$(run apply)"; printf '%s\n' "$out" | grep -q '^result=untouched' || fail "keep twice: $out"
# fix188: LSPosed's log already off (the OP15 user had switched it off in the manager): ASB
# writes nothing and records nothing, so nothing later claims ASB switched it off.
"$T/bin/asb" --lspd verbose-set off "$D" >/dev/null
echo 'lsposed_verbose=off' > "$T/mod/config/governor.conf"
out="$(run apply)"; printf '%s\n' "$out" | grep -q '^result=already_off' || fail "already off: $out"
[ ! -f "$T/asb/prev" ] || fail "a value ASB never replaced was recorded as its earlier one"
run status | grep -q '^asb_changed=' && fail "status claims ASB changed LSPosed"
echo off > "$T/asb/prev"   # what fix187 left on such a phone
out="$(run apply)"; printf '%s\n' "$out" | grep -q '^result=already_off' && [ ! -f "$T/asb/prev" ] || fail "fix187's 'off' record not cleared: $out"
echo off > "$T/asb/prev"; echo 'lsposed_verbose=keep' > "$T/mod/config/governor.conf"
out="$(run apply)"; printf '%s\n' "$out" | grep -q '^result=untouched' || fail "keep after an already-off claims a restore: $out"
[ "$("$T/bin/asb" --lspd verbose-get "$D")" = "verbose=off
format=v1" ] || fail "keep changed a value ASB never wrote"
grep -q "LSPosed's log was already off when the card was set" "$ROOT/tools/asb_diag.sh" || fail "asbdiag still says ASB switched an already-off log"
# fix197: sweep - the command service.sh's loop runs every ten minutes. It empties the logs
# while the card says off and touches nothing else: no setting write, no record, and nothing
# at all on keep.
head -c 3072 /dev/zero > "$T/lspd/log/modules_2026-10-14T10_00_00.log"
echo 'lsposed_verbose=keep' > "$T/mod/config/governor.conf"
out="$(run sweep)"; printf '%s\n' "$out" | grep -qx 'result=skip' || fail "sweep on keep: $out"
[ "$(wc -c < "$T/lspd/log/modules_2026-10-14T10_00_00.log")" = 3072 ] || fail "sweep touched the logs on keep"
echo 'lsposed_verbose=off' > "$T/mod/config/governor.conf"
out="$(run sweep)"; printf '%s\n' "$out" | grep -qx 'result=swept freed_kib=3' || fail "sweep on off: $out"
[ ! -s "$T/lspd/log/modules_2026-10-14T10_00_00.log" ] || fail "sweep left the modules log full"
[ -s "$T/lspd/log/verbose_2026-10-13T10_00_00.log" ] || fail "sweep emptied the live verbose log the daemon holds open"
[ "$(row "$D")" = "ACED0005737200116A6176612E6C616E672E426F6F6C65616ECD207280D59CFAEE0200015A000576616C7565787000" ] || fail "sweep wrote LSPosed's setting"
[ ! -f "$T/asb/prev" ] || fail "sweep recorded a previous value it never replaced"
rm -rf "$T/lspd"; echo 'lsposed_verbose=off' > "$T/mod/config/governor.conf"
out="$(run apply)"; printf '%s\n' "$out" | grep -q '^result=absent' || fail "no LSPosed: $out"
out="$(run sweep)"; printf '%s\n' "$out" | grep -qx 'result=absent' || fail "sweep without LSPosed: $out"
echo "PASS lsposed verbose: LSPosed's own switch written as Java's Boolean, remembered and put back; old logs and the modules log freed; sweep only while the card says off; foreign layouts untouched"
)

t_asbdiag_lsposed_modlog_runtime() (
# Runtime (fix189): asbdiag tells the modules log apart from the verbose log and names who
# fills it. An OP15 with LSPosed's verbose log off showed 20 MB an hour after boot - the
# modules log, which LSPosed has no switch for - and the card read "log off" beside it.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fail() { echo "FAIL asbdiag lsposed modlog: $*" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^_asb_lsp_modlog() {$/,/^}$/p' "$ROOT/tools/asb_diag.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || fail "function not found"
grep -q '^  _asb_lsp_modlog$' "$ROOT/tools/asb_diag.sh" || fail "section 0f does not call it"
mkdir -p "$T/log"
i=0; while [ $i -lt 30 ]; do i=$((i + 1))
  printf '[ 2026-10-20T17:30:%02d.123    10179:  1234:  1240 I/LSPosed-Bridge  ] LuckyTool: hook statusbar clock %d\n' $((i % 60)) "$i"
done > "$T/log/modules_2026-10-20T17_00_00.log"
printf '[ 2026-10-20T17:31:01.125     1000:   999:   999 I/LSPosed-Bridge  ] OtherMod: hooked\n' >> "$T/log/modules_2026-10-20T17_00_00.log"
printf 'old\n' > "$T/log/modules_2026-10-20T16_00_00.log"; touch -d '2026-10-20 16:00' "$T/log/modules_2026-10-20T16_00_00.log"
printf 'com.android.systemui 10179 0 /data/user/0/com.android.systemui platform 3003\n' > "$T/pk"
out="$( NOTE() { echo "NOTE $*"; }; . "$T/fn.sh"; ASB_LSPD_LOG="$T/log" ASB_PKG_LIST="$T/pk" _asb_lsp_modlog )"
printf '%s\n' "$out" | grep -q 'in 2 file(s) this boot' || fail "size/count line: $out"
printf '%s\n' "$out" | grep -q 'not the verbose log' || fail "not told apart from the verbose log: $out"
printf '%s\n' "$out" | sed -n 2p | grep -q '96% of the newest file (30 lines): com.android.systemui | LuckyTool: hook statusbar clock #$' || fail "top writer not named: $out"
printf '%s\n' "$out" | grep -q 'system | OtherMod: hooked' || fail "uid 1000 not named system: $out"
out="$( NOTE() { echo "NOTE $*"; }; . "$T/fn.sh"; ASB_LSPD_LOG="$T/none" _asb_lsp_modlog )"
[ -z "$out" ] || fail "printed something without a modules log: $out"
cmp -s "$ROOT/tools/asb_diag.sh" "$ROOT/system/bin/asbdiag" || fail "asbdiag copies differ"
echo "PASS asbdiag lsposed modlog: the modules log is reported apart, with the app and message that fill it"
)

_asb_tests() { declare -F | awk '$3 ~ /^t_/ { print substr($3, 3) }'; }
case "${1:-}" in
  --list) _asb_tests ;;
  --source) "_c_${2:?fixture name}" ;;
  *)
    _asb_failed=0
    for _asb_t in ${*:-$(_asb_tests)}; do
      "t_$_asb_t"
      [ $? -eq 0 ] || { printf 'FAILED: %s\n' "$_asb_t" >&2; _asb_failed=$((_asb_failed + 1)); }
    done
    [ "$_asb_failed" -eq 0 ]
    ;;
esac
