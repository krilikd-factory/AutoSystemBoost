#ifndef ASB_LOG_FEEDBACK_H
#define ASB_LOG_FEEDBACK_H

/* Bounded, read-only consumer contract for the opt-in full-day logger.
 * The logger publishes a sustained-jank hint, never a Smart decision or a frame
 * window. The native governor re-reads GraphicsStats and owns every A/B window,
 * parameter and plateau decision. This parser has no side effects. */
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <limits.h>

#define ASB_LOG_FEEDBACK_SCHEMA       1
#define ASB_LOG_FEEDBACK_MAX_BYTES    2048
#define ASB_LOG_FEEDBACK_FRESH_S      180L
#define ASB_LOG_FEEDBACK_FUTURE_S     30L
#define ASB_LOG_FEEDBACK_MIN_ROWS     2
#define ASB_LOG_FEEDBACK_MIN_FRAMES_PER_ROW 240L
#define ASB_LOG_FEEDBACK_MIN_JANK_X1000 50L
/* Generous for a full-day capture, but small enough that every exported counter also fits
 * a 32-bit unsigned long. All arithmetic is validated before it is performed. */
#define ASB_LOG_FEEDBACK_MAX_FRAMES 1000000000ULL
#define ASB_LOG_FEEDBACK_MAX_SEQ    1000000000ULL

#define ASB_LOG_FEEDBACK_INVALID  0
#define ASB_LOG_FEEDBACK_VALID    1
#define ASB_LOG_FEEDBACK_STALE   -1
#define ASB_LOG_FEEDBACK_FUTURE  -2

#ifndef ASB_LOG_FEEDBACK_FILE
#define ASB_LOG_FEEDBACK_FILE "/dev/.asb/log_smart_feedback.env"
#endif

typedef struct {
    char capture[32];
    unsigned long seq;
    long epoch;
    uint64_t app_hash;
    int app_hint;
    int bucket_id;
    unsigned long rows;
    unsigned long frames;
    unsigned long janky;
    long jank_x1000;
} asb_log_feedback_t;

static int asb_log_feedback_uint(const char *s, uint64_t *v) {
    char *end = NULL;
    unsigned long long n;
    if (!s || !*s) return 0;
    for (const char *p = s; *p; p++) if (*p < '0' || *p > '9') return 0;
    errno = 0;
    n = strtoull(s, &end, 10);
    if (errno == ERANGE || !end || *end) return 0;
    *v = (uint64_t)n;
    return 1;
}

static int asb_log_feedback_hash(const char *s, uint64_t *v) {
    uint64_t n = 0;
    if (!s || strlen(s) != 16) return 0;
    for (int i = 0; i < 16; i++) {
        char c = s[i];
        unsigned x;
        if (c >= '0' && c <= '9') x = (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f') x = (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') x = (unsigned)(c - 'A' + 10);
        else return 0;
        n = (n << 4) | x;
    }
    if (!n) return 0;
    *v = n;
    return 1;
}

static int asb_log_feedback_parse(const char *text, size_t len, long now,
                                  asb_log_feedback_t *out) {
    char buf[ASB_LOG_FEEDBACK_MAX_BYTES];
    uint64_t schema = 0, seq = 0, epoch = 0, rows = 0, frames = 0, janky = 0, jx = 0;
    uint64_t hint = 0, bucket = 0;
    char capture[32] = {0}, hash[17] = {0};
    size_t pos = 0;
    if (!text || !out || !len || len >= sizeof(buf) || text[len - 1] != '\n') return 0;
    memcpy(buf, text, len); buf[len] = 0;
    memset(out, 0, sizeof(*out));
    while (pos < len) {
        char *line = buf + pos;
        char *nl = memchr(line, '\n', len - pos);
        size_t left;
        if (!nl) return 0;
        *nl = 0; left = (size_t)(nl - line) + 1; pos += left;
        if (!*line) continue;
        if (!strncmp(line, "schema=", 7)) {
            if (!asb_log_feedback_uint(line + 7, &schema)) return 0;
        } else if (!strncmp(line, "capture=", 8)) {
            size_t n = strlen(line + 8);
            if (!n || n >= sizeof(capture)) return 0;
            for (size_t i = 0; i < n; i++) {
                char c = line[8 + i];
                if (!((c >= '0' && c <= '9') || c == '_')) return 0;
            }
            memcpy(capture, line + 8, n + 1);
        } else if (!strncmp(line, "seq=", 4)) {
            if (!asb_log_feedback_uint(line + 4, &seq)) return 0;
        } else if (!strncmp(line, "epoch=", 6)) {
            if (!asb_log_feedback_uint(line + 6, &epoch)) return 0;
        } else if (!strncmp(line, "pkg_hash=", 9)) {
            if (strlen(line + 9) != 16) return 0;
            memcpy(hash, line + 9, 17);
        } else if (!strncmp(line, "app_hint=", 9)) {
            if (!asb_log_feedback_uint(line + 9, &hint)) return 0;
        } else if (!strncmp(line, "bucket_id=", 10)) {
            if (!asb_log_feedback_uint(line + 10, &bucket)) return 0;
        } else if (!strncmp(line, "rows=", 5)) {
            if (!asb_log_feedback_uint(line + 5, &rows)) return 0;
        } else if (!strncmp(line, "frames=", 7)) {
            if (!asb_log_feedback_uint(line + 7, &frames)) return 0;
        } else if (!strncmp(line, "janky=", 6)) {
            if (!asb_log_feedback_uint(line + 6, &janky)) return 0;
        } else if (!strncmp(line, "jank_x1000=", 11)) {
            if (!asb_log_feedback_uint(line + 11, &jx)) return 0;
        } else return 0; /* fixed schema: no arbitrary keys or shell evaluation */
    }
    if (schema != ASB_LOG_FEEDBACK_SCHEMA || !capture[0] || !seq || !epoch ||
        seq > ASB_LOG_FEEDBACK_MAX_SEQ || epoch > (uint64_t)LONG_MAX ||
        rows < ASB_LOG_FEEDBACK_MIN_ROWS || rows > 1000 ||
        frames > ASB_LOG_FEEDBACK_MAX_FRAMES || janky > frames ||
        hint > 100 || bucket > 255 || jx > 1000) return 0;
    /* Division expresses frames >= rows * MIN without multiplying untrusted values. */
    if (frames / rows < (uint64_t)ASB_LOG_FEEDBACK_MIN_FRAMES_PER_ROW) return 0;
    if (!asb_log_feedback_hash(hash, &out->app_hash)) return 0;
    if ((long)epoch > now + ASB_LOG_FEEDBACK_FUTURE_S) return ASB_LOG_FEEDBACK_FUTURE;
    if (now - (long)epoch > ASB_LOG_FEEDBACK_FRESH_S || now < (long)epoch - ASB_LOG_FEEDBACK_FUTURE_S)
        return ASB_LOG_FEEDBACK_STALE;
    {
        if (janky > UINT64_MAX / 1000ULL ||
            frames > UINT64_MAX / (uint64_t)ASB_LOG_FEEDBACK_MIN_JANK_X1000) return 0;
        uint64_t calc = frames ? (janky * 1000ULL) / frames : 0;
        uint64_t floor = (frames * (uint64_t)ASB_LOG_FEEDBACK_MIN_JANK_X1000) / 1000ULL;
        if (janky < floor || jx < (uint64_t)ASB_LOG_FEEDBACK_MIN_JANK_X1000 ||
            (calc > jx ? calc - jx : jx - calc) > 1) return 0;
    }
    snprintf(out->capture, sizeof(out->capture), "%s", capture);
    out->seq = (unsigned long)seq; out->epoch = (long)epoch;
    out->app_hint = (int)hint; out->bucket_id = (int)bucket;
    out->rows = (unsigned long)rows; out->frames = (unsigned long)frames;
    out->janky = (unsigned long)janky; out->jank_x1000 = (long)jx;
    return ASB_LOG_FEEDBACK_VALID;
}

#endif
