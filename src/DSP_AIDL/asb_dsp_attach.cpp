// ASB DSP attacher.
//
// WHY THIS EXISTS
// On OxygenOS 16 the framework does not apply the <postprocess> section of
// audio_effects_config.xml at all: AudioPolicyEffects logs
//   "addOutputSessionEffects(): no output processing needed for this stream"
// for EVERY stream, including the stock music_helper entry. Effects on this device are
// attached programmatically by apps through the AudioEffect API instead - ViperFX does it
// from com.llsl.viper4android, OPlus from com.oplus.audio.effectcenter. Confirmed on the
// device: ViperFX has only <library> + <effect> lines and NO <apply> anywhere, yet it sits
// live in audioflinger as "Effect ID 59, UUID 90380da3-...".
//
// ASB ships no Android app, so nothing ever asked the framework to instantiate our effect:
// the library was loaded and the factory listed it (8 -> 9 effects), but no client created
// it. This tiny daemon is that client. It creates the effect on session 0
// (AUDIO_SESSION_OUTPUT_MIX = the global mix, which is where ViperFX and OplusAudioX sit),
// enables it, and stays alive so the effect is not torn down.
//
// It re-checks periodically: audioserver restarts (and our own asb_audio_apply.sh triggers
// one on slider changes) drop all effects, so the daemon re-attaches instead of dying.

#include <unistd.h>
#include <sys/system_properties.h>

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

#include <binder/IPCThreadState.h>
#include <binder/IServiceManager.h>
#include <binder/ProcessState.h>
#include <media/AudioEffect.h>
#include <utils/Log.h>
#include <utils/RefBase.h>
#include <android/content/AttributionSourceState.h>

using android::sp;
using android::status_t;
using android::OK;

// Must match kAsbImplUuid / kAsbTypeUuid in asb_effect_aidl.cpp and the uuid/type written
// into audio_effects_config.xml by common/install.sh. Keep all three in sync.
//   impl: a5b10001-7e55-4c60-9f21-415342445350  ("ASBDSP" in the node bytes)
//   type: fe3199be-aed0-413f-87bb-11260eb63cf1  (standard Loudness Enhancer)
static const effect_uuid_t kAsbImplUuid = {
        0xa5b10001, 0x7e55, 0x4c60, 0x9f21, {0x41, 0x53, 0x42, 0x44, 0x53, 0x50}};
static const effect_uuid_t kAsbTypeUuid = {
        0xfe3199be, 0xaed0, 0x413f, 0x87bb, {0x11, 0x26, 0x0e, 0xb6, 0x3c, 0xf1}};

static void logline(const char* fmt, ...) {
    // Plain stdout; the launcher redirects it to /data/adb/asb/dsp_attach.log so the state
    // is inspectable without logcat.
    va_list ap;
    va_start(ap, fmt);
    char ts[32];
    time_t now = time(nullptr);
    struct tm tmv;
    localtime_r(&now, &tmv);
    strftime(ts, sizeof(ts), "%H:%M:%S", &tmv);
    printf("[%s] ", ts);
    vprintf(fmt, ap);
    printf("\n");
    fflush(stdout);
    va_end(ap);
}

int main(int /*argc*/, char** /*argv*/) {
    android::ProcessState::self()->startThreadPool();

    android::content::AttributionSourceState attributionSource;
    attributionSource.packageName = "asb_dsp";
    attributionSource.uid = static_cast<int32_t>(getuid());
    attributionSource.pid = static_cast<int32_t>(getpid());
    attributionSource.token = android::sp<android::BBinder>::make();

    sp<android::AudioEffect> fx;
    int attached = 0;
    int was_on = -1;
    int fails = 0;   // consecutive failures, used to back off

    for (;;) {
        // Battery: only hold the effect while the DSP is actually on. An attached effect
        // processes every frame during playback AND can push the stream off the hardware
        // compress-offload path onto software decoding, which costs real power. With the
        // slider at 0 there is nothing to process, so we release it completely and the audio
        // path goes back to exactly what it was without the module.
        char pv[PROP_VALUE_MAX] = {0};
        __system_property_get("persist.asb.dsp.enable", pv);
        int want_on = (pv[0] == '1');
        int gain = 0;
        char gv[PROP_VALUE_MAX] = {0};
        __system_property_get("persist.asb.dsp.gain_mb", gv);
        gain = atoi(gv);
        if (gain <= 0) want_on = 0;

        if (want_on != was_on) {
            logline("dsp %s (gain_mb=%d)", want_on ? "enabled" : "disabled", gain);
            was_on = want_on;
        }

        if (!want_on) {
            if (fx != nullptr) { logline("releasing effect (dsp off)"); fx.clear(); attached = 0; }
            // Nothing to maintain - poll lazily. nanosleep uses CLOCK_MONOTONIC, which does
            // not advance while the device is suspended, so this never wakes the SoC by
            // itself; it simply resumes when the device is already awake.
            sleep(60);
            continue;
        }

        // Re-attach whenever the effect is gone: audioserver restarts (including the ones
        // asb_audio_apply.sh fires when the slider moves) tear every effect down.
        bool alive = (fx != nullptr && fx->initCheck() == OK);
        if (!alive) {
            if (attached) logline("effect lost (audioserver restart?) - re-attaching");
            fx.clear();

            sp<android::AudioEffect> next = sp<android::AudioEffect>::make(attributionSource);
            // Pass BOTH type and implementation uuid: the type gets us past the vendor
            // factory's type table (a custom type is silently skipped - the log shows that
            // happening to "audiosphere"), while the uuid pins the instance to OUR effect
            // rather than the stock Loudness Enhancer that shares the type.
            status_t st = next->set(&kAsbTypeUuid,
                                    &kAsbImplUuid,
                                    /*priority=*/0,
                                    /*cbf=*/nullptr,
                                    /*user=*/nullptr,
                                    /*sessionId=*/AUDIO_SESSION_OUTPUT_MIX,
                                    /*io=*/AUDIO_IO_HANDLE_NONE);
            status_t ic = (st == OK) ? next->initCheck() : st;
            if (ic == OK) {
                status_t en = next->setEnabled(true);
                if (en == OK) {
                    fx = next;
                    if (!attached) logline("attached to session 0 and enabled");
                    attached = 1;
                    fails = 0;
                } else {
                    logline("setEnabled failed: %d", (int)en);
                }
            } else {
                if (++fails <= 3 || (fails % 20) == 0)
                    logline("create failed: set=%d initCheck=%d (attempt %d)", (int)st, (int)ic, fails);
                // Back off after repeated failures instead of hammering the audio stack every
                // 30 s forever. If the effect cannot be created, retrying harder does not help
                // and only adds load (and log spam) while something else is wrong.
                if (fails >= 10) {
                    if (fails == 10) logline("too many failures - backing off to 5 min");
                    sleep(300);
                    continue;
                }
            }
        }
        // 30 s instead of 5 s: re-attaching a few seconds later after an audioserver restart
        // is inaudible, and this cuts idle wakeups by 6x. The check itself is a local field
        // read plus two property reads - no IPC, microseconds of CPU.
        sleep(30);
    }

    android::IPCThreadState::self()->joinThreadPool();
    return 0;
}
