#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

// ASB screenshot policy v1. A complete document ends with END=<entry count>.
// Incomplete or malformed input never enables an app. Entries are scoped to
// Android user and package; neither a wildcard nor a system UID is accepted.
namespace asb_screenshot {
constexpr size_t kMaxBytes = 8192;
constexpr unsigned kMaxEntries = 64;

inline bool package_valid(const char *s, size_t n) {
    if (!s || n < 3 || n > 127) return false;
    bool dot = false, segment_start = true;
    for (size_t i = 0; i < n; ++i) {
        const char c = s[i];
        if (c == '.') {
            if (segment_start) return false;
            dot = true; segment_start = true; continue;
        }
        const bool letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        if (segment_start && !letter && c != '_') return false;
        if (!letter && !(c >= '0' && c <= '9') && c != '_') return false;
        segment_start = false;
    }
    return dot && !segment_start;
}

inline bool decimal(const char *s, size_t n, unsigned max, unsigned &v) {
    if (!s || n == 0 || n > 6 || (n > 1 && s[0] == '0')) return false;
    v = 0;
    for (size_t i = 0; i < n; ++i) {
        if (s[i] < '0' || s[i] > '9') return false;
        v = v * 10 + unsigned(s[i] - '0');
        if (v > max) return false;
    }
    return true;
}

inline bool selected(const char *data, size_t length, int32_t uid, const char *pkg) {
    static constexpr char header[] = "ASB_SCREENSHOT_V1\n";
    if (!data || !pkg || length > kMaxBytes || length < sizeof(header) ||
        std::memcmp(data, header, sizeof(header)-1) != 0 || data[length-1] != '\n') return false;
    const size_t pkg_len = std::strlen(pkg);
    if (!package_valid(pkg, pkg_len) || uid < 0) return false;
    const unsigned app_id = unsigned(uid) % 100000u, user = unsigned(uid) / 100000u;
    if (app_id < 10000u || app_id > 19999u || user > 999u) return false;
    size_t pos = sizeof(header)-1, entries[kMaxEntries]{}, sizes[kMaxEntries]{};
    unsigned count = 0; bool match = false, ended = false;
    while (pos < length) {
        size_t end = pos;
        while (end < length && data[end] != '\n') ++end;
        if (end == length || end == pos || ended) return false;
        if (end-pos >= 4 && std::memcmp(data+pos, "END=", 4) == 0) {
            unsigned expected = 0;
            if (!decimal(data+pos+4, end-pos-4, kMaxEntries, expected) || expected != count) return false;
            ended = true;
        } else {
            size_t sep = pos;
            while (sep < end && data[sep] != '|') ++sep;
            unsigned entry_user = 0;
            if (sep == end || !decimal(data+pos, sep-pos, 999, entry_user) ||
                !package_valid(data+sep+1, end-sep-1) || count >= kMaxEntries) return false;
            for (unsigned i = 0; i < count; ++i)
                if (sizes[i] == end-pos && std::memcmp(data+entries[i], data+pos, sizes[i]) == 0) return false;
            entries[count] = pos; sizes[count] = end-pos; ++count;
            if (entry_user == user && end-sep-1 == pkg_len &&
                std::memcmp(data+sep+1, pkg, pkg_len) == 0) match = true;
        }
        pos = end+1;
    }
    return ended && match;
}
}
