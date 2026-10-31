#ifndef ASB_OBSERVER_PROTOCOL_H
#define ASB_OBSERVER_PROTOCOL_H

/* Versioned process-lifecycle protocol. The separate optional governor request is only
 * "refresh evidence"; it carries no package, cap, profile or application-policy opcode. */
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <time.h>

#ifndef ASB_ZYGISK_CONFIG
#define ASB_ZYGISK_CONFIG "/data/adb/modules/AutoSystemBoost/config/governor.conf"
#endif
#ifndef ASB_ZYGISK_DIR
#define ASB_ZYGISK_DIR "/data/adb/asb/zygisk_observer"
#endif

#define ASB_OBSERVER_MAGIC 0x4153425au /* "ASBZ" */
#define ASB_OBSERVER_VERSION 1u
#define ASB_OBSERVER_EVENT_PROCESS_START 1u
#define ASB_OBSERVER_MAX_PROCESSES 64u
#define ASB_OBSERVER_MAX_EVENTS_PER_MINUTE 64u
#define ASB_OBSERVER_HINT_MAX_PER_MINUTE 8u
#define ASB_OBSERVER_HINT_MIN_INTERVAL_MS 2000

#pragma pack(push, 1)
struct AsbObserverFrame {
    uint32_t magic;
    uint16_t version;
    uint16_t kind;
    uint32_t size;
    int32_t pid;
    uint32_t reserved;
    uint64_t process_start_ticks;
    int64_t monotonic_ms;
    char package[128];
};
#pragma pack(pop)

inline int64_t asb_observer_monotonic_ms() {
    struct timespec ts {};
    return clock_gettime(CLOCK_MONOTONIC, &ts) == 0
        ? static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000 : 0;
}

inline std::string asb_observer_base_package(const std::string &process_name) {
    const size_t colon = process_name.find(':');
    return process_name.substr(0, colon);
}

inline bool asb_observer_package_valid(const std::string &package) {
    if (package.size() < 3 || package.size() > 127 || package.find('.') == std::string::npos)
        return false;
    if (package.front() == '.' || package.back() == '.' || package.find("..") != std::string::npos)
        return false;
    for (unsigned char c : package) {
        if (!(std::isalnum(c) || c == '_' || c == '.')) return false;
    }
    return true;
}

inline bool asb_observer_package_denied(const std::string &process_name) {
    static const char *const exact[] = {
        "system_server", "com.android.systemui", "com.android.packageinstaller",
        "com.android.permissioncontroller", "com.android.settings", "com.android.phone",
        "com.android.providers.media", "com.android.providers.downloads",
        "me.weishu.kernelsu", "com.rifsxd.ksunext", "com.topjohnwu.magisk",
        "io.github.vvb2060.magisk", "org.lsposed.manager", "com.tsng.hidemyapplist"
    };
    static const char *const prefixes[] = {
        "android.", "com.android.shell", "com.qualcomm.", "com.qti.", "vendor.",
        "com.oplus.safecenter", "com.coloros.safecenter", "com.heytap.safecenter"
    };
    if (process_name == "system_server" || process_name == "zygote" ||
        process_name == "zygote64" || process_name == "zygote32") return true;
    const std::string base = asb_observer_base_package(process_name);
    for (const char *value : exact) if (base == value) return true;
    for (const char *value : prefixes) {
        const size_t n = std::strlen(value);
        if (base.compare(0, n, value) == 0) return true;
    }
    return false;
}

inline bool asb_observer_frame_valid(const AsbObserverFrame &frame) {
    if (frame.magic != ASB_OBSERVER_MAGIC || frame.version != ASB_OBSERVER_VERSION ||
        frame.kind != ASB_OBSERVER_EVENT_PROCESS_START || frame.size != sizeof(AsbObserverFrame) ||
        frame.pid <= 1 || frame.reserved != 0 || frame.monotonic_ms <= 0) return false;
    if (std::memchr(frame.package, '\0', sizeof(frame.package)) == nullptr) return false;
    const std::string package(frame.package);
    return asb_observer_package_valid(package) && !asb_observer_package_denied(package);
}

#endif
