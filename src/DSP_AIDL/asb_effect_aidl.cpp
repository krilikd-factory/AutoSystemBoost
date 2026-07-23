// asb_effect_aidl.cpp — AutoSystemBoost loudness DSP as an AIDL audio effect.
//
// Modelled directly on AOSP's own Loudness Enhancer effect
// (hardware/interfaces/audio/aidl/default/loudnessEnhancer). It inherits the
// EffectImpl base class from libaudioaidlcommon, which already implements the whole
// IEffect contract — FMQ setup, the processing thread, open/close/command, the state
// machine and parameter plumbing. The previous hand-rolled BnEffect reimplemented all
// of that by hand and audioserver rejected it with "could not create effect ...
// status: -22" (EINVAL): the descriptor carried no Capability, and the manual FMQ /
// state handling did not match what AudioFlinger expects.
//
// A subclass of EffectImpl only provides: a Context (realtime state), getDescriptor(),
// createContext()/releaseContext(), getEffectName(), the parameter getters/setters,
// and effectProcessImpl() — the math, forwarded to the shared asb_dsp_core.h (identical
// to the legacy effect).
//
// type UUID = standard Loudness Enhancer (fe3199be-...), so the framework treats this
// as a loudness enhancer and applies it to the music stream; impl UUID (a5b10001-...)
// is ours. Build with soong (see Android.bp).
//
// BUILD NOTE: the exact spelling of a few AIDL helpers (MAKE_RANGE, the EffectContext
// ctor, the LoudnessEnhancer tags, getChannelCount) can vary by platform version. If
// the compiler flags one, check it against the loudnessEnhancer effect in *your* AOSP
// tree — this file mirrors that structure.

#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include <android-base/logging.h>
#include <system/audio_effects/effect_uuid.h>
#include <sys/system_properties.h>

#include "effect-impl/EffectImpl.h"
#include "effect-impl/EffectContext.h"
#include "effect-impl/EffectTypes.h"

#include "asb_dsp_core.h"

namespace aidl::android::hardware::audio::effect {

using ::aidl::android::media::audio::common::AudioUuid;

// ---- UUIDs -----------------------------------------------------------------
// Impl UUID: unique to ASB. Must equal <effect uuid=...> in audio_effects_config.xml.
static const AudioUuid kAsbImplUuid = {static_cast<int32_t>(0xa5b10001),
                                       0x7e55, 0x4c60, 0x9f21,
                                       {0x41, 0x53, 0x42, 0x44, 0x53, 0x50}};
// Type UUID: the standard Loudness Enhancer type (matches <effect type=...>).
static const AudioUuid kAsbTypeUuid = {static_cast<int32_t>(0xfe3199be),
                                       0xaed0, 0x413f, 0x87bb,
                                       {0x11, 0x26, 0x0e, 0xb6, 0x3c, 0xf1}};

static int asb_prop_int(const char* key, int def) {
    char buf[PROP_VALUE_MAX];
    if (__system_property_get(key, buf) <= 0) return def;
    char* end = nullptr;
    long v = strtol(buf, &end, 10);
    return end == buf ? def : (int)v;
}

// Read one DSP tunable, preferring the vendor-namespace copy.
//
// The effect lives in the vendor HAL process, while the module writes persist.asb.dsp.*
// with resetprop - those land in the default_prop SELinux context, which a vendor domain
// generally cannot read (confirmed on device: getprop -Z reported default_prop). Properties
// under the vendor namespace are the ones vendor code is meant to read, so the module now
// writes both names and this prefers the readable one, falling back to the legacy name so
// an older install keeps working.
static int asb_dsp_prop(const char* leaf, int def) {
    char key[128];
    snprintf(key, sizeof(key), "persist.vendor.asb.dsp.%s", leaf);
    char buf[PROP_VALUE_MAX];
    if (__system_property_get(key, buf) > 0) {
        char* end = nullptr;
        long v = strtol(buf, &end, 10);
        if (end != buf) return (int)v;
    }
    snprintf(key, sizeof(key), "persist.asb.dsp.%s", leaf);
    return asb_prop_int(key, def);
}

// ---- Context: holds the realtime DSP state ---------------------------------
class AsbLoudnessContext final : public EffectContext {
  public:
    AsbLoudnessContext(int statusDepth, const Parameter::Common& common)
        : EffectContext(statusDepth, common) {
        asb_core_reset(&mCore);
        reload(common);
    }

    // (Re)load tunables from the persist.asb.dsp.* props the WebUI writes.
    void reload(const Parameter::Common& common) {
        mCommon = common;
        applyTunables(/*gainOverrideMb=*/-1);
    }

    // gainOverrideMb >= 0 means "use this gain instead of the property" - that is the path
    // taken when the attach daemon pushes the gain over binder. It matters because the
    // effect runs inside the vendor HAL process (audiohalservice.qti) while the
    // persist.asb.dsp.* properties are written by the module with resetprop, i.e. they land
    // in the default_prop context. A vendor domain that cannot read that context gets the
    // defaults instead - enable=0, gain=0 - which configures the core as bypass and makes a
    // fully attached, ACTIVE, non-suspended effect pass audio through untouched.
    void applyTunables(int gainOverrideMb) {
        int rate = mCommon.input.base.sampleRate > 0 ? mCommon.input.base.sampleRate : 48000;
        int ch = ::aidl::android::hardware::audio::common::getChannelCount(
                mCommon.input.base.channelMask);
        if (ch <= 0) ch = 2;
        int enable = asb_dsp_prop("enable", 0);
        int gain   = asb_dsp_prop("gain_mb", 0);
        int ceil   = asb_dsp_prop("ceiling_mb", -15);
        int comp   = asb_dsp_prop("comp", 1);
        int ratio  = asb_dsp_prop("comp_ratio_x10", 60);
        int thresh = asb_dsp_prop("comp_thresh_mb", -2400);
        int soft   = asb_dsp_prop("softclip", 0);
        int post   = asb_dsp_prop("postgain_x100", 300);
        if (gainOverrideMb >= 0) {
            gain = gainOverrideMb;
            if (gain > 0) enable = 1;
        }
        LOG(WARNING) << "ASB configure: enable=" << enable << " gain_mb=" << gain
                     << " ceiling_mb=" << ceil << " comp=" << comp << " ratio=" << ratio
                     << " thresh_mb=" << thresh << " softclip=" << soft
                     << " postgain_x100=" << post << " rate=" << rate << " ch=" << ch
                     << (gainOverrideMb >= 0 ? " (gain from parameter)" : " (gain from property)");
        asb_core_configure_ex(&mCore, enable, gain, ceil, comp, ratio, thresh, ch,
                              (uint32_t)rate, /*fmt_ok=*/1, soft, post);
        mGainMb = gain;
    }

    RetCode setGainMb(int gainMb) { applyTunables(gainMb); return RetCode::SUCCESS; }
    int getGainMb() const { return mGainMb; }

    IEffect::Status process(float* in, float* out, int samples) {
        IEffect::Status s{STATUS_INVALID_OPERATION, 0, 0};
        if (in == nullptr || out == nullptr || samples <= 0) return s;
        int ch = mCore.channels > 0 ? mCore.channels : 2;
        size_t frames = (size_t)samples / (size_t)ch;
        // Rate-limited proof of life. Attaching an effect and processing audio through it
        // are different things: without this trace there is no way to tell whether the
        // framework routes any audio to us at all (no lines = never called, e.g. the stream
        // is compress-offloaded or the session-0 chain is suspended), whether we are called
        // but bypassed (bypass=1, props not visible in the HAL process), or whether we do
        // amplify and the gain is undone further down the chain (outPeak > inPeak yet no
        // audible change). Every 500th buffer keeps this to a few lines per second.
        const bool trace = ((mCalls++ % 500) == 0);
        float inPeak = 0.0f;
        if (trace) {
            for (int i = 0; i < samples; i++) { float a = fabsf(in[i]); if (a > inPeak) inPeak = a; }
        }
        if (mCore.bypass) {
            if (in != out) memcpy(out, in, sizeof(float) * (size_t)samples);
        } else {
            asb_core_process_f32(&mCore, in, out, frames, /*accumulate=*/0);
        }
        if (trace) {
            float outPeak = 0.0f;
            for (int i = 0; i < samples; i++) { float a = fabsf(out[i]); if (a > outPeak) outPeak = a; }
            LOG(WARNING) << "ASB process: n=" << mCalls << " samples=" << samples << " ch=" << ch
                         << " bypass=" << mCore.bypass << " gain=" << mCore.gain
                         << " inPeak=" << inPeak << " outPeak=" << outPeak;
        }
        s.status = STATUS_OK;
        s.fmqConsumed = samples;
        s.fmqProduced = samples;
        return s;
    }

  private:
    asb_core_t mCore{};
    Parameter::Common mCommon{};
    int mGainMb = 0;
    unsigned long mCalls = 0;
};

// ---- Effect: thin EffectImpl subclass --------------------------------------
class AsbLoudnessEffect final : public EffectImpl {
  public:
    AsbLoudnessEffect() = default;
    ~AsbLoudnessEffect() override { cleanUp(); }

    ndk::ScopedAStatus getDescriptor(Descriptor* _aidl_return) override {
        *_aidl_return = kDescriptor;
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus setParameterSpecific(const Parameter::Specific& specific) override {
        if (specific.getTag() != Parameter::Specific::loudnessEnhancer)
            return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        if (!mContext) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        auto& le = specific.get<Parameter::Specific::loudnessEnhancer>();
        if (le.getTag() == LoudnessEnhancer::gainMb)
            mContext->setGainMb(le.get<LoudnessEnhancer::gainMb>());
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getParameterSpecific(const Parameter::Id& id,
                                            Parameter::Specific* specific) override {
        if (id.getTag() != Parameter::Id::loudnessEnhancerTag)
            return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        if (!mContext) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        LoudnessEnhancer le;
        le.set<LoudnessEnhancer::gainMb>(mContext->getGainMb());
        specific->set<Parameter::Specific::loudnessEnhancer>(le);
        return ndk::ScopedAStatus::ok();
    }

    std::shared_ptr<EffectContext> createContext(const Parameter::Common& common) override {
        if (mContext) return mContext;
        mContext = std::make_shared<AsbLoudnessContext>(1 /*statusFmqDepth*/, common);
        return mContext;
    }

    RetCode releaseContext() override {
        if (mContext) mContext.reset();
        return RetCode::SUCCESS;
    }

    std::string getEffectName() override { return "ASB Loudness"; }

    IEffect::Status effectProcessImpl(float* in, float* out, int samples) override {
        IEffect::Status s{STATUS_NOT_ENOUGH_DATA, 0, 0};
        if (!mContext) return s;
        return mContext->process(in, out, samples);
    }

  private:
    std::shared_ptr<AsbLoudnessContext> mContext;

    // Capability MUST be present or AudioFlinger rejects the effect with -22.
    static const std::vector<Range::LoudnessEnhancerRange> kRanges;
    static const Capability kCapability;
    static const Descriptor kDescriptor;
};

const std::vector<Range::LoudnessEnhancerRange> AsbLoudnessEffect::kRanges = {
        MAKE_RANGE(LoudnessEnhancer, gainMb, 0, ASB_GAIN_MB_MAX)};

const Capability AsbLoudnessEffect::kCapability = {
        .range = Range::make<Range::loudnessEnhancer>(AsbLoudnessEffect::kRanges)};

const Descriptor AsbLoudnessEffect::kDescriptor = {
        .common = {.id = {.type = kAsbTypeUuid, .uuid = kAsbImplUuid, .proxy = std::nullopt},
                   // INSERT effect placed first in the chain, volume-control aware.
                   // NOT POST_PROC — that flag combination is invalid for this type.
                   .flags = {.type = Flags::Type::INSERT,
                             .insert = Flags::Insert::FIRST,
                             .volume = Flags::Volume::CTRL},
                   .name = "ASB Loudness",
                   .implementor = "AutoSystemBoost"},
        .capability = AsbLoudnessEffect::kCapability};

}  // namespace aidl::android::hardware::audio::effect

// ---- Factory ABI audioserver dlsym's ---------------------------------------
using ::aidl::android::hardware::audio::effect::AsbLoudnessEffect;
using ::aidl::android::hardware::audio::effect::Descriptor;
using ::aidl::android::hardware::audio::effect::IEffect;
using ::aidl::android::hardware::audio::effect::kAsbImplUuid;
using ::aidl::android::hardware::audio::effect::kAsbTypeUuid;
using ::aidl::android::media::audio::common::AudioUuid;

// Render a uuid for the log so we can see exactly what the vendor factory probes with.
static std::string asbUuidStr(const AudioUuid& u) {
    char b[64];
    std::string s;
    snprintf(b, sizeof(b), "%08x-", (unsigned)u.timeLow);          s += b;
    snprintf(b, sizeof(b), "%04x-", (unsigned)(u.timeMid & 0xffff));        s += b;
    snprintf(b, sizeof(b), "%04x-", (unsigned)(u.timeHiAndVersion & 0xffff)); s += b;
    snprintf(b, sizeof(b), "%04x-", (unsigned)(u.clockSeq & 0xffff));      s += b;
    for (auto n : u.node) { snprintf(b, sizeof(b), "%02x", (unsigned)(n & 0xff)); s += b; }
    // Also dump the raw 32-bit fields. The canonical form masks to 16 bits, so a
    // sign-extended constant (e.g. clockSeq 0xFFFF9F21 instead of 0x00009F21) prints
    // identically to a correct one while comparing unequal - that is precisely how the
    // uuid mismatch stayed invisible in the first round of this diagnostic.
    snprintf(b, sizeof(b), " [raw %08x %08x %08x %08x]", (unsigned)u.timeLow,
             (unsigned)u.timeMid, (unsigned)u.timeHiAndVersion, (unsigned)u.clockSeq);
    s += b;
    return s;
}

extern "C" binder_exception_t createEffect(const AudioUuid* uuid,
                                           std::shared_ptr<IEffect>* instance) {
    if (instance == nullptr) {
        LOG(ERROR) << "ASB createEffect: null instance out-param";
        return EX_NULL_POINTER;
    }
    if (uuid == nullptr) {
        LOG(WARNING) << "ASB createEffect: null uuid, creating anyway";
    } else if (*uuid != kAsbImplUuid && *uuid != kAsbTypeUuid) {
        LOG(WARNING) << "ASB createEffect: unexpected uuid " << asbUuidStr(*uuid)
                     << ", creating anyway";
    }
    *instance = ndk::SharedRefBase::make<AsbLoudnessEffect>();
    return EX_NONE;
}

extern "C" binder_exception_t queryEffect(const AudioUuid* uuid, Descriptor* desc) {
    // NEVER answer with a failure here unless there is literally nowhere to write the
    // descriptor. AHAL_EffectFactoryQti aborts its ENTIRE enumeration when one library
    // returns an error, and the device is then left with
    //     EffectsFactoryHalAidl with 0 nonProxyEffects and 0 proxyEffects
    // i.e. every effect vanishes - ours and the vendor's alike - after which every
    // AudioEffect::set() fails with -19 (NO_INIT), including the attach daemon's.
    // This library implements exactly one effect, so answering with our own descriptor
    // whatever uuid we are probed with is both harmless and the only safe behaviour.
    if (desc == nullptr) {
        LOG(ERROR) << "ASB queryEffect: null descriptor";
        return EX_ILLEGAL_ARGUMENT;
    }
    if (uuid == nullptr) {
        LOG(WARNING) << "ASB queryEffect: probed with null uuid, answering anyway";
    } else if (*uuid != kAsbImplUuid && *uuid != kAsbTypeUuid) {
        LOG(WARNING) << "ASB queryEffect: probed with uuid " << asbUuidStr(*uuid)
                     << ", answering with our descriptor anyway";
    }
    auto effect = ndk::SharedRefBase::make<AsbLoudnessEffect>();
    if (!effect->getDescriptor(desc).isOk()) {
        LOG(ERROR) << "ASB queryEffect: getDescriptor failed";
        return EX_ILLEGAL_STATE;
    }
    return EX_NONE;
}

// destroyEffect is intentionally NOT defined here: AOSP's EffectImpl.cpp (linked in
// via :effectCommonFile) already provides the shared destroyEffect factory function.
// Defining our own caused: ld.lld: error: duplicate symbol: destroyEffect.
