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
#include "../src/asb_metrics.h"

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
