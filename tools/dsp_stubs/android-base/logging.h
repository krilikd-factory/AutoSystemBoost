#pragma once
// LOG(x) << ... needs to swallow anything on the right of <<.
#include <iostream>
struct AsbStubLog { template <typename T> AsbStubLog& operator<<(const T&) { return *this; } };
#define LOG(x) AsbStubLog()
#define ALOGI(...)
#define ALOGE(...)
#define ALOGD(...)
