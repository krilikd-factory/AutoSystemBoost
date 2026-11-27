#pragma once
#include <cstdint>
#include <cstring>

// A narrowly supported AOSP WindowManager.LayoutParams wire layout. Unknown
// Android versions, interface names and record shapes are left untouched.
namespace asb_screenshot {
constexpr int32_t kSecure = 0x00002000;
// SurfaceControl flags, distinct from WindowManager.LayoutParams flags.
constexpr int32_t kSurfaceSecure = 0x00000080;
constexpr int32_t kSurfaceSkipScreenshot = 0x00000040;
inline int32_t surface_filtered(int32_t flags) {
    return flags & ~(kSurfaceSecure | kSurfaceSkipScreenshot);
}
struct WindowFields { int32_t width, height, x, y, type, flags; };
inline bool supported(int sdk, unsigned pointer_bytes) { return sdk >= 35 && sdk <= 37 && pointer_bytes == 8; }
inline bool is_window_session(const char *descriptor) {
    return descriptor && std::strcmp(descriptor, "android.view.IWindowSession") == 0;
}
inline bool candidate(const WindowFields &w) {
    const auto dimension = [](int32_t v) { return v == -1 || v == -2 || (v >= 0 && v <= 16384); };
    return dimension(w.width) && dimension(w.height) && w.x >= -16384 && w.x <= 16384 &&
           w.y >= -16384 && w.y <= 16384 && w.type >= 1 && w.type <= 2999 && (w.flags & kSecure);
}
inline int32_t filtered(int32_t flags) { return flags & ~kSecure; }
}
