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

#include <cstring>
#include <memory>
#include <string>
#include <vector>

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
                                       0x7e55, 0x4c60, static_cast<int16_t>(0x9f21),
                                       {0x41, 0x53, 0x42, 0x44, 0x53, 0x50}};
// Type UUID: the standard Loudness Enhancer type (matches <effect type=...>).
static const AudioUuid kAsbTypeUuid = {static_cast<int32_t>(0xfe3199be),
                                       static_cast<int16_t>(0xaed0), 0x413f,
                                       static_cast<int16_t>(0x87bb),
                                       {0x11, 0x26, 0x0e, 0xb6, 0x3c, 0xf1}};

static int asb_prop_int(const char* key, int def) {
    char buf[PROP_VALUE_MAX];
    if (__system_property_get(key, buf) <= 0) return def;
    char* end = nullptr;
    long v = strtol(buf, &end, 10);
    return end == buf ? def : (int)v;
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
        int rate = common.input.base.sampleRate > 0 ? common.input.base.sampleRate : 48000;
        int ch = ::aidl::android::hardware::audio::common::getChannelCount(
                common.input.base.channelMask);
        if (ch <= 0) ch = 2;
        asb_core_configure(&mCore,
                           asb_prop_int("persist.asb.dsp.enable", 0),
                           asb_prop_int("persist.asb.dsp.gain_mb", 0),
                           asb_prop_int("persist.asb.dsp.ceiling_mb", -15),
                           asb_prop_int("persist.asb.dsp.comp", 1),
                           asb_prop_int("persist.asb.dsp.comp_ratio_x10", 60),
                           asb_prop_int("persist.asb.dsp.comp_thresh_mb", -2400),
                           ch, (uint32_t)rate, /*fmt_ok=*/1);
    }

    RetCode setGainMb(int gainMb) { mGainMb = gainMb; return RetCode::SUCCESS; }
    int getGainMb() const { return mGainMb; }

    IEffect::Status process(float* in, float* out, int samples) {
        IEffect::Status s{STATUS_INVALID_OPERATION, 0, 0};
        if (in == nullptr || out == nullptr || samples <= 0) return s;
        int ch = mCore.channels > 0 ? mCore.channels : 2;
        size_t frames = (size_t)samples / (size_t)ch;
        if (mCore.bypass) {
            if (in != out) memcpy(out, in, sizeof(float) * (size_t)samples);
        } else {
            asb_core_process_f32(&mCore, in, out, frames, /*accumulate=*/0);
        }
        s.status = STATUS_OK;
        s.fmqConsumed = samples;
        s.fmqProduced = samples;
        return s;
    }

  private:
    asb_core_t mCore{};
    int mGainMb = 0;
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
using ::aidl::android::media::audio::common::AudioUuid;

extern "C" binder_exception_t createEffect(const AudioUuid* uuid,
                                           std::shared_ptr<IEffect>* instance) {
    if (uuid == nullptr || *uuid != kAsbImplUuid) return EX_ILLEGAL_ARGUMENT;
    if (instance == nullptr) return EX_NULL_POINTER;
    *instance = ndk::SharedRefBase::make<AsbLoudnessEffect>();
    return EX_NONE;
}

extern "C" binder_exception_t queryEffect(const AudioUuid* uuid, Descriptor* desc) {
    if (uuid == nullptr || *uuid != kAsbImplUuid) return EX_ILLEGAL_ARGUMENT;
    if (desc == nullptr) return EX_NULL_POINTER;
    auto effect = ndk::SharedRefBase::make<AsbLoudnessEffect>();
    return effect->getDescriptor(desc).isOk() ? EX_NONE : EX_ILLEGAL_STATE;
}

extern "C" binder_exception_t destroyEffect(const std::shared_ptr<IEffect>& instance) {
    if (!instance) return EX_ILLEGAL_ARGUMENT;
    return EX_NONE;
}
