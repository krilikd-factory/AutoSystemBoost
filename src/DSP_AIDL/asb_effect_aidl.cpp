// asb_effect_aidl.cpp — AutoSystemBoost loudness DSP as an AIDL audio effect.
//
// Why this file exists: on Android 13+ audioserver loads effects through the
// android.hardware.audio.effect AIDL contract (a libraryname.so that exports
// createEffect / queryEffect / destroyEffect and hands back an IEffect binder),
// NOT the legacy AUDIO_EFFECT_LIBRARY_INFO_SYM / effect_handle_t path. A legacy
// .so registered in a v2.0 audio_effects_config.xml is never bound to the stream,
// which is exactly why the legacy libasbdsp produced no audible gain on OOS 16.
//
// The DSP math is unchanged: it lives in asb_dsp_core.h (lifted verbatim from the
// legacy asb_dsp.c) and is shared, so both effects apply identical loudness.
//
// This is built with the NDK against AOSP effect headers (see Android.bp). It is
// intentionally minimal: a "post-processing" insert that reads the same
// persist.asb.dsp.* tunables the WebUI already writes.

#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <mutex>
#include <condition_variable>

#include <aidl/android/hardware/audio/effect/BnEffect.h>
#include <aidl/android/hardware/audio/effect/BnFactory.h>
#include <android-base/logging.h>
#include <fmq/AidlMessageQueue.h>
#include <system/audio_effects/effect_uuid.h>
#include <sys/system_properties.h>

#include "asb_dsp_core.h"

using ::aidl::android::hardware::audio::effect::BnEffect;
using ::aidl::android::hardware::audio::effect::CommandId;
using ::aidl::android::hardware::audio::effect::Descriptor;
using ::aidl::android::hardware::audio::effect::Flags;
using ::aidl::android::hardware::audio::effect::IEffect;
using ::aidl::android::hardware::audio::effect::IFactory;
using ::aidl::android::hardware::audio::effect::Parameter;
using ::aidl::android::hardware::audio::effect::Processing;
using ::aidl::android::hardware::audio::effect::State;
using ::aidl::android::media::audio::common::AudioUuid;
using ::android::AidlMessageQueue;
using ::ndk::ScopedAStatus;

namespace {

// UUID must match the <effect ... uuid> the module registers in
// audio_effects_config.xml (a5b10001-7e55-4c60-9f21-415342445350).
static const AudioUuid kAsbImplUuid = {
        static_cast<int32_t>(0xa5b10001), 0x7e55, 0x4c60, 0x9f21, {0x41, 0x53, 0x42, 0x44, 0x53, 0x50}};

// Proprietary post-processing type. The <effect type=...> attribute must equal
// this so the AIDL factory attaches us to the stream (a missing type is the second
// reason the legacy registration went silent).
static const AudioUuid kAsbTypeUuid = {
        static_cast<int32_t>(0xa5b10000), 0x7e55, 0x4c60, 0x9f21, {0x41, 0x53, 0x42, 0x54, 0x59, 0x50}};

static int prop_int(const char* key, int def) {
    char buf[PROP_VALUE_MAX];
    if (__system_property_get(key, buf) <= 0) return def;
    char* end = nullptr;
    long v = strtol(buf, &end, 10);
    if (end == buf) return def;
    return (int)v;
}

class AsbEffect : public BnEffect {
  public:
    AsbEffect() { asb_core_reset(&core_); }

    ScopedAStatus getDescriptor(Descriptor* desc) override {
        desc->common.id.type = kAsbTypeUuid;
        desc->common.id.uuid = kAsbImplUuid;
        // POST_PROC (not INSERT): the AIDL factory attaches an effect to a stream's
        // post-processing chain only when its type is POST_PROC. With INSERT the effect
        // is registered but never bound to <postprocess><stream type="music">, so the
        // gain does nothing - the exact bug seen on the legacy path. offloadIndication
        // lets it ride compress-offloaded music (common on Snapdragon) instead of being
        // bypassed by it.
        desc->common.flags.type = Flags::Type::POST_PROC;
        desc->common.flags.insert = Flags::Insert::LAST;
        desc->common.flags.volume = Flags::Volume::CTRL;
        desc->common.flags.offloadIndication = true;
        desc->common.name = "ASB Loudness";
        desc->common.implementor = "AutoSystemBoost";
        return ScopedAStatus::ok();
    }

    ScopedAStatus open(const Parameter::Common& common,
                       const std::optional<Parameter::Specific>& /*specific*/,
                       IEffect::OpenEffectReturn* ret) override {
        if (state_ != State::INIT) return ScopedAStatus::ok();
        common_ = common;
        // Allocate the FMQs audioserver exchanges audio through.
        int frames = common.input.frameCount > 0 ? common.input.frameCount : 256;
        int ch = channelCount(common.input.base.channelMask);
        size_t cap = (size_t)frames * (size_t)ch;
        if (cap < 256) cap = 256;
        inMQ_ = std::make_shared<DataMQ>(cap, true);
        outMQ_ = std::make_shared<DataMQ>(cap, true);
        statusMQ_ = std::make_shared<StatusMQ>(1, true);
        if (!inMQ_->isValid() || !outMQ_->isValid() || !statusMQ_->isValid())
            return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
        ret->statusMQ = statusMQ_->dupeDesc();
        ret->inputDataMQ = inMQ_->dupeDesc();
        ret->outputDataMQ = outMQ_->dupeDesc();
        refresh();
        state_ = State::IDLE;
        thread_ = std::thread([this] { loop(); });
        return ScopedAStatus::ok();
    }

    // reopen() is new in audio.effect-V3 (Android 16). It re-hands the current FMQ
    // descriptors back to the client without a full close/open cycle (e.g. after the
    // client loses its copies). The V2 port lacked it, which made AsbEffect abstract.
    // We return the existing queues' descriptors if we are open; otherwise a benign OK.
    ScopedAStatus reopen(IEffect::OpenEffectReturn* ret) override {
        if (state_ == State::INIT || !inMQ_ || !outMQ_ || !statusMQ_)
            return ScopedAStatus::ok();
        if (!inMQ_->isValid() || !outMQ_->isValid() || !statusMQ_->isValid())
            return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
        ret->statusMQ = statusMQ_->dupeDesc();
        ret->inputDataMQ = inMQ_->dupeDesc();
        ret->outputDataMQ = outMQ_->dupeDesc();
        return ScopedAStatus::ok();
    }

    ScopedAStatus close() override {
        {
            std::lock_guard<std::mutex> l(mtx_);
            if (state_ == State::INIT) return ScopedAStatus::ok();
            state_ = State::INIT;
        }
        cv_.notify_all();
        if (thread_.joinable()) thread_.join();
        inMQ_.reset(); outMQ_.reset(); statusMQ_.reset();
        return ScopedAStatus::ok();
    }

    ScopedAStatus command(CommandId id) override {
        std::lock_guard<std::mutex> l(mtx_);
        switch (id) {
            case CommandId::START:
                if (state_ == State::IDLE) { refresh(); state_ = State::PROCESSING; }
                break;
            case CommandId::STOP:
            case CommandId::RESET:
                if (state_ == State::PROCESSING) state_ = State::IDLE;
                asb_core_reset(&core_);
                break;
            default: break;
        }
        cv_.notify_all();
        return ScopedAStatus::ok();
    }

    ScopedAStatus getState(State* s) override { *s = state_; return ScopedAStatus::ok(); }

    // We keep parameters in properties (the WebUI writes persist.asb.dsp.*), so the
    // generic AIDL parameter setters just trigger a refresh.
    ScopedAStatus setParameter(const Parameter& /*p*/) override { refresh(); return ScopedAStatus::ok(); }
    ScopedAStatus getParameter(const Parameter::Id& /*id*/, Parameter* /*p*/) override {
        return ScopedAStatus::ok();
    }

  private:
    using DataMQ = AidlMessageQueue<float, ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>;
    using StatusMQ = AidlMessageQueue<::aidl::android::hardware::audio::effect::IEffect::Status,
                                      ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>;

    static int channelCount(
            const ::aidl::android::media::audio::common::AudioChannelLayout& m) {
        // Layout carries an explicit mask for I/O; popcount gives the channel count.
        using Tag = ::aidl::android::media::audio::common::AudioChannelLayout;
        if (m.getTag() == Tag::layoutMask)
            return __builtin_popcount(m.get<Tag::layoutMask>());
        return 2;
    }

    void refresh() {
        int rate = common_.input.base.sampleRate > 0 ? common_.input.base.sampleRate : 48000;
        int ch = channelCount(common_.input.base.channelMask);
        // softclip defaults to 1 (saturation). On loud modern masters the brick-wall
        // limiter measured +4.1 dB RMS while tanh saturation measured +9.7 dB with no
        // hard clamping, which is the difference the user hears vs ViperFX. Set
        // persist.asb.dsp.softclip=0 to return to the old limiter without rebuilding.
        asb_core_configure_ex(&core_,
                           prop_int("persist.asb.dsp.enable", 0),
                           prop_int("persist.asb.dsp.gain_mb", 0),
                           prop_int("persist.asb.dsp.ceiling_mb", -15),
                           prop_int("persist.asb.dsp.comp", 1),
                           prop_int("persist.asb.dsp.comp_ratio_x10", 60),
                           prop_int("persist.asb.dsp.comp_thresh_mb", -2400),
                           ch, (uint32_t)rate, /*fmt_ok=*/1,
                           prop_int("persist.asb.dsp.softclip", 1),
                           prop_int("persist.asb.dsp.postgain_x100", 115));
    }

    void loop() {
        std::vector<float> buf;
        for (;;) {
            std::unique_lock<std::mutex> l(mtx_);
            cv_.wait(l, [this] {
                return state_ == State::INIT ||
                       (state_ == State::PROCESSING && inMQ_ && inMQ_->availableToRead() > 0);
            });
            if (state_ == State::INIT) return;
            size_t avail = inMQ_->availableToRead();
            if (avail == 0) continue;
            buf.resize(avail);
            if (!inMQ_->read(buf.data(), avail)) continue;
            l.unlock();

            size_t frames = avail / (core_.channels > 0 ? core_.channels : 2);
            if (core_.bypass) {
                // pass through untouched
            } else {
                asb_core_process_f32(&core_, buf.data(), buf.data(), frames, /*acc=*/0);
            }
            outMQ_->write(buf.data(), avail);
            IEffect::Status st{STATUS_OK, (int32_t)avail, (int32_t)avail};
            statusMQ_->write(&st, 1);
        }
    }

    asb_core_t core_{};
    Parameter::Common common_{};
    State state_ = State::INIT;
    std::shared_ptr<DataMQ> inMQ_, outMQ_;
    std::shared_ptr<StatusMQ> statusMQ_;
    std::thread thread_;
    std::mutex mtx_;
    std::condition_variable cv_;
};

}  // namespace

// ---- AIDL effect library factory ABI (what audioserver dlsym's) --------------
extern "C" binder_exception_t createEffect(const AudioUuid* uuid,
                                           std::shared_ptr<IEffect>* instance) {
    if (uuid == nullptr || *uuid != kAsbImplUuid) return EX_ILLEGAL_ARGUMENT;
    *instance = ndk::SharedRefBase::make<AsbEffect>();
    return EX_NONE;
}

extern "C" binder_exception_t queryEffect(const AudioUuid* uuid, Descriptor* desc) {
    if (uuid == nullptr || *uuid != kAsbImplUuid) return EX_ILLEGAL_ARGUMENT;
    desc->common.id.type = kAsbTypeUuid;
    desc->common.id.uuid = kAsbImplUuid;
    // Must match getDescriptor(): the factory reads THIS descriptor at match time (before
    // an instance exists) to decide whether to attach us to a stream. If this said INSERT
    // while getDescriptor said POST_PROC, the effect would still be skipped. Keep both
    // POST_PROC + offloadIndication.
    desc->common.flags.type = Flags::Type::POST_PROC;
    desc->common.flags.insert = Flags::Insert::LAST;
    desc->common.flags.volume = Flags::Volume::CTRL;
    desc->common.flags.offloadIndication = true;
    desc->common.name = "ASB Loudness";
    desc->common.implementor = "AutoSystemBoost";
    return EX_NONE;
}

extern "C" binder_exception_t destroyEffect(const std::shared_ptr<IEffect>& instance) {
    if (instance) instance->close();
    return EX_NONE;
}
