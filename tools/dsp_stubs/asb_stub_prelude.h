#pragma once
// Minimal stand-ins for the AIDL audio surface, for -fsyntax-only.
//
// These must mirror the REAL signatures, not convenient ones. A stub that accepts
// anything would compile the very mistakes this exists to catch: the point is that
// AudioDeviceDescription::type is an enum and not a struct, and that
// EffectImpl::setParameterCommon takes a const Parameter&. Getting those two wrong in
// the stub would make the check pass on broken code, which is worse than no check.
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <memory>

namespace aidl::android::media::audio::common { struct AudioChannelLayout; }

namespace ndk {
struct ScopedAStatus {
    static ScopedAStatus ok() { return {}; }
    static ScopedAStatus fromExceptionCode(int) { return {}; }
    bool isOk() const { return true; }
};
template <typename T> using SharedRefBase = T;
}

namespace aidl::android::hardware::audio::common {
inline int getChannelCount(const ::aidl::android::media::audio::common::AudioChannelLayout&,
                           int = 0) { return 2; }
}

namespace aidl::android::media::audio::common {
enum class AudioDeviceType {
    OUT_SPEAKER, OUT_SPEAKER_EARPIECE, OUT_SPEAKER_SAFE,
    OUT_HEADPHONE, OUT_HEADSET, OUT_DEFAULT
};
struct AudioDeviceDescription {
    AudioDeviceType type = AudioDeviceType::OUT_DEFAULT;   // enum, NOT a struct
    std::string connection;
};
struct AudioChannelLayout { int layout = 0; };
struct AudioUuid {
    int32_t timeLow = 0; int32_t timeMid = 0; int32_t timeHiAndVersion = 0;
    int32_t clockSeq = 0; std::vector<uint8_t> node;
};
struct AudioFormatDescription { int type = 0; };
}

namespace aidl::android::hardware::audio::effect {
namespace acommon = ::aidl::android::media::audio::common;

struct Descriptor {
    struct Identity {
        acommon::AudioUuid type; acommon::AudioUuid uuid; acommon::AudioUuid proxy;
    };
    struct Common { Identity id; int flags = 0; std::string name; std::string implementor; };
    Common common;
};
enum class RetCode { SUCCESS, ERROR_ILLEGAL_PARAMETER, ERROR_NULL_POINTER, ERROR_EFFECT_LIB_ERROR };
struct IEffect {
    struct Status { int status = 0; int fmqProduced = 0; int fmqConsumed = 0; };
};

struct Parameter {
    struct Common {
        struct Base {
            int sampleRate = 48000;
            acommon::AudioChannelLayout channelMask{};
        };
        struct IO { Base base; };
        IO input; IO output;
        int session = 0;
    };
    struct Specific { int dummy = 0; };
    struct Id { int dummy = 0; };

    enum Tag { common, deviceDescription, specific };
    Tag getTag() const { return common; }
    template <Tag t> std::vector<acommon::AudioDeviceDescription> get() const { return {}; }
};

struct EffectContext {
    EffectContext() = default;
    EffectContext(int /*statusDepth*/, const Parameter::Common& /*common*/) {}
    virtual ~EffectContext() = default;
};

struct EffectImpl {
    virtual ~EffectImpl() = default;
    virtual ndk::ScopedAStatus getDescriptor(Descriptor*) { return {}; }
    // The real one takes const Parameter&. An override written against Parameter::Common&
    // hides this rather than overriding it - exactly the error that reached main.
    virtual ndk::ScopedAStatus setParameterCommon(const Parameter&) { return {}; }
    virtual ndk::ScopedAStatus setParameter(const Parameter&) { return {}; }
    virtual ndk::ScopedAStatus setParameterSpecific(const Parameter::Specific&) { return {}; }
    virtual ndk::ScopedAStatus getParameterSpecific(const Parameter::Id&, Parameter::Specific*) { return {}; }
    virtual std::shared_ptr<EffectContext> createContext(const Parameter::Common&) { return nullptr; }
    virtual ndk::ScopedAStatus commandImpl(int) { return {}; }
    virtual void cleanUp() {}
    std::shared_ptr<EffectContext> mContext;
};
}

// binder_status_t constants used by the source.
enum { STATUS_OK = 0, STATUS_INVALID_OPERATION = -38, STATUS_BAD_VALUE = -22 };

namespace aidl::android::hardware::audio::effect {
// Range/Capability appear in the descriptor tables.
struct Range {
    struct AsbLoudnessRange { int min = 0; int max = 0; };
};
struct Capability { int dummy = 0; };
struct Flags { int dummy = 0; };
}

extern "C" int __system_property_get(const char*, char*);
