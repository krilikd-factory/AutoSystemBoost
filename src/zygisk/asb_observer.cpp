#include "zygisk.hpp"
#include "asb_observer_core.h"

#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef ASB_ABI_TAG
#define ASB_ABI_TAG "unknown"
#endif
#ifndef ASB_GOVERNOR_SOCKET
#define ASB_GOVERNOR_SOCKET "/dev/.asb/ctl.sock"
#endif
#ifndef ASB_GOVERNOR_CLIENT_DIR
#define ASB_GOVERNOR_CLIENT_DIR "/dev/.asb"
#endif
#define ASB_GOVERNOR_HINT_TIMEOUT_US 100000

namespace {

/* Plain syscalls only: the zygote-side path must not construct iostreams or parse the
 * 40 KB governor.conf on every fork (fix272). */
ssize_t read_small(int fd, char *buf, size_t cap) {
    size_t done = 0;
    while (done < cap) {
        const ssize_t n = read(fd, buf + done, cap - done);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return -1;
        if (n == 0) break;
        done += static_cast<size_t>(n);
    }
    return static_cast<ssize_t>(done);
}

bool load_policy_fd(int fd, AsbObserverPolicy &policy) {
    char buf[ASB_OBSERVER_POLICY_MAX_BYTES + 1];
    const ssize_t n = read_small(fd, buf, sizeof(buf));
    close(fd);
    if (n <= 0 || static_cast<size_t>(n) > ASB_OBSERVER_POLICY_MAX_BYTES) return false;
    return asb_observer_policy_parse(buf, static_cast<size_t>(n), policy);
}

/* Root side (companion): the same generated policy, read by absolute path. */
bool load_policy_root(AsbObserverPolicy &policy) {
    const int fd = open(ASB_ZYGISK_POLICY_ABS, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { policy = AsbObserverPolicy(); return false; }
    return load_policy_fd(fd, policy);
}

uint64_t process_start_ticks(pid_t pid) {
    char path[48];
    std::snprintf(path, sizeof(path), "/proc/%d/stat", static_cast<int>(pid));
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char buf[1024];
    const ssize_t n = read_small(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    char *p = std::strrchr(buf, ')');
    if (!p || p[1] != ' ') return 0;
    p += 2; /* field 3 */
    for (int field = 3; field < 22; ++field) {
        p = std::strchr(p, ' ');
        if (!p) return 0;
        ++p;
    }
    char *end = nullptr;
    errno = 0;
    const unsigned long long value = std::strtoull(p, &end, 10);
    if (end == p || errno != 0) return 0;
    return static_cast<uint64_t>(value);
}

long process_rss_kb(pid_t pid) {
    char path[48];
    std::snprintf(path, sizeof(path), "/proc/%d/status", static_cast<int>(pid));
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char buf[4096];
    const ssize_t n = read_small(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    const char *p = std::strstr(buf, "\nVmRSS:");
    if (!p) return 0;
    return std::strtol(p + 7, nullptr, 10);
}

/* The screen state the governor last published: 1 on, 0 off, -1 unknown. */
int governor_screen_on() {
    const int fd = open(ASB_GOVERNOR_STATE, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    char buf[4096];
    const ssize_t n = read_small(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    const char *p = std::strstr(buf, "\nscreen=");
    if (!p) return -1;
    if (p[8] == '0') return 0;
    if (p[8] == '1') return 1;
    return -1;
}

bool write_all(int fd, const void *data, size_t size) {
    const char *p = static_cast<const char *>(data);
    while (size) {
        const ssize_t n = send(fd, p, size, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n;
        size -= static_cast<size_t>(n);
    }
    return true;
}

// 1 = complete frame, 0 = orderly disconnect, -1 = malformed/truncated stream.
int read_frame(int fd, AsbObserverFrame &frame) {
    char *p = reinterpret_cast<char *>(&frame);
    size_t done = 0;
    while (done < sizeof(frame)) {
        const ssize_t n = recv(fd, p + done, sizeof(frame) - done, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n == 0) return done == 0 ? 0 : -1;
        if (n < 0) return -1;
        done += static_cast<size_t>(n);
    }
    return 1;
}

AsbObserverFrame make_frame(uint16_t kind, uint32_t flags, const std::string &package) {
    AsbObserverFrame frame {};
    frame.magic = ASB_OBSERVER_MAGIC;
    frame.version = ASB_OBSERVER_VERSION;
    frame.kind = kind;
    frame.size = sizeof(frame);
    frame.pid = getpid();
    frame.flags = flags;
    frame.process_start_ticks = process_start_ticks(frame.pid);
    frame.monotonic_ms = asb_observer_monotonic_ms();
    if (package.size() < sizeof(frame.package))
        std::snprintf(frame.package, sizeof(frame.package), "%s", package.c_str());
    return frame;
}

enum class GovernorHintResult { accepted, vetoed, unavailable };

/* One bounded datagram round trip with a fixed opcode. No package name or tuning value
 * crosses this interface. An old/missing governor simply leaves its current policy
 * untouched; the application is never punished for a timeout. */
GovernorHintResult request_governor(const char *command) {
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return GovernorHintResult::unavailable;
    struct sockaddr_un client_addr {};
    client_addr.sun_family = AF_UNIX;
    std::snprintf(client_addr.sun_path, sizeof(client_addr.sun_path),
                  "%s/zygisk_hint_%d.sock", ASB_GOVERNOR_CLIENT_DIR, static_cast<int>(getpid()));
    unlink(client_addr.sun_path);
    if (bind(fd, reinterpret_cast<struct sockaddr *>(&client_addr), sizeof(client_addr)) != 0) {
        close(fd);
        return GovernorHintResult::unavailable;
    }
    struct timeval timeout {0, ASB_GOVERNOR_HINT_TIMEOUT_US};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_un server_addr {};
    server_addr.sun_family = AF_UNIX;
    std::snprintf(server_addr.sun_path, sizeof(server_addr.sun_path), "%s", ASB_GOVERNOR_SOCKET);
    const size_t length = std::strlen(command);
    const ssize_t sent = sendto(fd, command, length, 0,
                                reinterpret_cast<struct sockaddr *>(&server_addr), sizeof(server_addr));
    GovernorHintResult result = GovernorHintResult::unavailable;
    if (sent == static_cast<ssize_t>(length)) {
        char reply[32] {};
        const ssize_t got = recv(fd, reply, sizeof(reply) - 1, 0);
        if (got > 0) result = std::strcmp(reply, "ok") == 0
            ? GovernorHintResult::accepted : GovernorHintResult::vetoed;
    }
    unlink(client_addr.sun_path);
    close(fd);
    return result;
}

GovernorHintResult request_governor_refresh() {
    static const char command[] = "zygisk-refresh";
    return request_governor(command);
}

GovernorHintResult request_governor_launch() {
    static const char command[] = "zygisk-launch";
    return request_governor(command);
}

class Broker {
public:
    static Broker &instance() { static Broker broker; return broker; }

    void handle(int client) {
        int owned_pid = -1;
        for (;;) {
            const uint64_t cpu_before = cpu_us();
            AsbObserverFrame frame {};
            const int result = read_frame(client, frame);
            const int64_t now = asb_observer_monotonic_ms();
            AsbObserverPolicy policy;
            load_policy_root(policy);
            Request request = Request::none;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                ++wakeups_;
                if (result == 1) {
                    // SO_PEERCRED was fixed when pre-specialize connected the socket.
                    struct ucred peer {};
                    socklen_t len = sizeof(peer);
                    const bool peer_ok = getsockopt(client, SOL_SOCKET, SO_PEERCRED, &peer, &len) == 0;
                    const bool start_ok = process_start_ticks(frame.pid) == frame.process_start_ticks &&
                                          frame.process_start_ticks != 0;
                    if (!peer_ok || peer.pid != frame.pid || !start_ok || !asb_observer_frame_valid(frame)) {
                        core_.reject_invalid();
                    } else if (frame.kind == ASB_OBSERVER_EVENT_SPAWN) {
                        request = spawn_locked(frame, policy, now);
                    } else if (!policy.valid || !policy.observer) {
                        ++policy_absent_;
                    } else {
                        policy_generation_ = policy.generation;
                        const auto accepted = core_.start(frame, now);
                        const bool changed = accepted == AsbObserverResult::accepted;
                        if (changed) owned_pid = frame.pid;
                        request = refresh_locked(changed, policy, now);
                    }
                } else {
                    if (result < 0) core_.reject_invalid();
                    const bool changed = owned_pid > 0 && core_.exit(owned_pid);
                    core_.prune(now);
                    request = refresh_locked(changed, policy, now);
                }
                ipc_cpu_us_ += cpu_us() - cpu_before;
            }
            /* The governor round trip (<= 100 ms) runs outside the state lock, so a slow
             * governor never stalls another app's start or exit record. */
            const uint64_t cpu_ipc = cpu_us();
            GovernorHintResult outcome = GovernorHintResult::unavailable;
            if (request != Request::none) {
                std::lock_guard<std::mutex> ipc(ipc_mutex_);
                outcome = request == Request::launch ? request_governor_launch() : request_governor_refresh();
            }
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (request == Request::launch) count(outcome, launch_accepted_, launch_vetoed_, launch_unavailable_);
                if (request == Request::refresh) count(outcome, hints_accepted_, hints_vetoed_, hints_unavailable_);
                ipc_cpu_us_ += cpu_us() - cpu_ipc;
                persist_locked(now, policy);
            }
            if (result != 1) break;
        }
        close(client);
    }

private:
    enum class Request { none, refresh, launch };

    static uint64_t cpu_us() {
        struct timespec ts {};
        return clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts) == 0
            ? static_cast<uint64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000 : 0;
    }

    static void count(GovernorHintResult r, uint64_t &ok, uint64_t &veto, uint64_t &none) {
        switch (r) {
            case GovernorHintResult::accepted: ++ok; break;
            case GovernorHintResult::vetoed: ++veto; break;
            case GovernorHintResult::unavailable: ++none; break;
        }
    }

    Request refresh_locked(bool changed, const AsbObserverPolicy &policy, int64_t now) {
        if (!changed || !policy.valid || !policy.hints) return Request::none;
        if (!core_.hint_permit(now)) { ++hints_throttled_; return Request::none; }
        ++policy_hints_;
        return Request::refresh;
    }

    Request spawn_locked(const AsbObserverFrame &frame, const AsbObserverPolicy &policy, int64_t now) {
        ++spawn_events_;
        if (!policy.valid) { ++policy_absent_; return Request::none; }
        policy_generation_ = policy.generation;
        const bool top = (frame.flags & ASB_OBSERVER_FLAG_TOP_APP) != 0;
        if ((frame.flags & ASB_OBSERVER_FLAG_LEDGER) && policy.ledger)
            core_.ledger_record(frame.package, governor_screen_on(), top, now);
        if (!(frame.flags & ASB_OBSERVER_FLAG_LAUNCH) || !policy.launch) return Request::none;
        ++launch_events_;
        if (!core_.launch_permit(now)) { ++launch_throttled_; return Request::none; }
        return Request::launch;
    }

    void persist_locked(int64_t now, const AsbObserverPolicy &policy) {
        mkdir("/dev/.asb", 0700);
        mkdir(ASB_ZYGISK_RUN_DIR, 0700);
        const std::string path = std::string(ASB_ZYGISK_RUN_DIR) + "/state." ASB_ABI_TAG ".tsv";
        const std::string tmp = path + ".tmp";
        const int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0) return;
        std::ostringstream out;
        out << "Z\tschema\t2\nZ\tmode\tobserver\nZ\tabi\t" ASB_ABI_TAG "\n";
        out << "Z\tupdated_monotonic_ms\t" << now << "\n";
        out << "Z\tpolicy_generation\t" << (policy.valid ? policy.generation : policy_generation_) << "\n";
        out << "Z\tpolicy_generation_seen\t" << policy_generation_ << "\n";
        out << "Z\tevents_total\t" << core_.events_total() << "\n";
        out << "Z\tevents_dropped_total\t" << core_.dropped() << "\n";
        out << "Z\tevents_dropped_rate_limit\t" << core_.rate_limited() << "\n";
        out << "Z\tevents_dropped_duplicate\t" << core_.duplicate() << "\n";
        out << "Z\tevents_dropped_invalid\t" << core_.invalid() << "\n";
        out << "Z\tevents_dropped_capacity\t" << core_.capacity_dropped() << "\n";
        out << "Z\tevents_policy_absent\t" << policy_absent_ << "\n";
        out << "Z\tipc_cpu_ms\t" << ipc_cpu_us_ / 1000 << "\n";
        out << "Z\tipc_wakeups\t" << wakeups_ << "\n";
        out << "Z\tpolicy_hints\t" << policy_hints_ << "\n";
        out << "Z\thints_accepted\t" << hints_accepted_ << "\n";
        out << "Z\thints_vetoed\t" << hints_vetoed_ << "\n";
        out << "Z\thints_unavailable\t" << hints_unavailable_ << "\n";
        out << "Z\thints_throttled\t" << hints_throttled_ << "\n";
        out << "Z\tspawn_events\t" << spawn_events_ << "\n";
        out << "Z\tlaunch_events\t" << launch_events_ << "\n";
        out << "Z\tlaunch_accepted\t" << launch_accepted_ << "\n";
        out << "Z\tlaunch_vetoed\t" << launch_vetoed_ << "\n";
        out << "Z\tlaunch_unavailable\t" << launch_unavailable_ << "\n";
        out << "Z\tlaunch_throttled\t" << launch_throttled_ << "\n";
        out << "Z\tledger_events\t" << core_.ledger_events() << "\n";
        out << "Z\tledger_evicted\t" << core_.ledger_evicted() << "\n";
        long rss = 0;
        for (const auto &entry : core_.processes()) {
            const long current_rss = process_rss_kb(entry.first);
            if (current_rss > 0) rss += current_rss;
            out << "P\t" << entry.first << "\t" << entry.second.start_ticks << "\t"
                << entry.second.package << "\t" << current_rss << "\n";
        }
        out << "Z\tmemory_kb\t" << rss << "\n";
        for (const auto &entry : core_.ledger()) {
            out << "L\t" << entry.first << "\t" << entry.second.screen_off << "\t"
                << entry.second.screen_on << "\t" << entry.second.top_app << "\n";
        }
        const std::string data = out.str();
        const char *p = data.data();
        size_t left = data.size();
        while (left) {
            const ssize_t n = write(fd, p, left);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            p += n; left -= static_cast<size_t>(n);
        }
        close(fd);
        if (left == 0) rename(tmp.c_str(), path.c_str()); else unlink(tmp.c_str());
    }

    std::mutex mutex_;
    std::mutex ipc_mutex_;
    AsbObserverCore core_;
    uint64_t ipc_cpu_us_ = 0;
    uint64_t wakeups_ = 0;
    uint64_t policy_hints_ = 0, hints_accepted_ = 0, hints_vetoed_ = 0;
    uint64_t hints_unavailable_ = 0, hints_throttled_ = 0;
    uint64_t spawn_events_ = 0, launch_events_ = 0, launch_accepted_ = 0, launch_vetoed_ = 0;
    uint64_t launch_unavailable_ = 0, launch_throttled_ = 0, policy_absent_ = 0;
    unsigned long policy_generation_ = 0;
};

class Observer final : public zygisk::ModuleBase {
public:
    /* Runs once in zygote. If the absolute policy path is blocked (EACCES under SELinux),
     * every fork uses the loader's module-directory fd instead of repeating a denied open. */
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        api_ = api; env_ = env;
        const int fd = open(ASB_ZYGISK_POLICY_ABS, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) { close(fd); abs_path_ = true; }
        else abs_path_ = errno == ENOENT;
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        socket_ = -1;
        package_.clear();
        if (!args || (args->is_child_zygote && *args->is_child_zygote) ||
            !asb_observer_regular_app_uid(args->uid)) return skip();
        AsbObserverPolicy policy;
        if (!read_policy(policy) || !policy.active()) return skip();
        const bool top = args->is_top_app && *args->is_top_app;
        const bool launch = policy.launch && top;
        std::string base;
        if (((policy.observer && policy.packages) || policy.ledger) && args->nice_name) {
            const char *raw = env_->GetStringUTFChars(args->nice_name, nullptr);
            if (raw) {
                base = asb_observer_base_package(raw);
                env_->ReleaseStringUTFChars(args->nice_name, raw);
            }
            if (!asb_observer_package_valid(base) || asb_observer_package_denied(base)) base.clear();
        }
        const bool observe = !base.empty() && policy.selected(base.c_str());
        const bool ledger = !base.empty() && policy.ledger;
        if (!observe && !launch && !ledger) return skip();
        const int sock = api_->connectCompanion();
        if (sock < 0) return skip();
        if (launch || ledger) {
            const uint32_t flags = (top ? ASB_OBSERVER_FLAG_TOP_APP : 0u) |
                                   (launch ? ASB_OBSERVER_FLAG_LAUNCH : 0u) |
                                   (ledger ? ASB_OBSERVER_FLAG_LEDGER : 0u);
            const AsbObserverFrame frame = make_frame(ASB_OBSERVER_EVENT_SPAWN, flags,
                                                      ledger ? base : std::string());
            if (!write_all(sock, &frame, sizeof(frame))) { close(sock); return skip(); }
        }
        /* Not allowlisted: the one-shot record is sent; nothing stays in the process. */
        if (!observe || !api_->exemptFd(sock)) { close(sock); return skip(); }
        socket_ = sock;
        package_ = base;
        // Selected processes retain the library only to own this fd. No hooks are installed.
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (socket_ < 0) return;
        if (!asb_observer_package_valid(package_) || package_.size() >= sizeof(AsbObserverFrame::package)) {
            close(socket_);
            socket_ = -1;
            return;
        }
        const AsbObserverFrame frame = make_frame(ASB_OBSERVER_EVENT_PROCESS_START, 0u, package_);
        if (!write_all(socket_, &frame, sizeof(frame))) {
            close(socket_);
            socket_ = -1;
        }
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs *) override { skip(); }

private:
    /* Absent policy = dormant: one failed open, nothing parsed, no IPC. */
    bool read_policy(AsbObserverPolicy &policy) {
        int fd = -1;
        if (abs_path_) {
            fd = open(ASB_ZYGISK_POLICY_ABS, O_RDONLY | O_CLOEXEC);
            if (fd < 0 && errno == ENOENT) return false;
        }
        if (fd < 0) {
            const int dir = api_->getModuleDir();
            if (dir < 0) return false;
            fd = openat(dir, ASB_ZYGISK_POLICY_REL, O_RDONLY | O_CLOEXEC);
            if (fd < 0) return false;
        }
        return load_policy_fd(fd, policy);
    }

    void skip() { api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY); }
    zygisk::Api *api_ = nullptr;
    JNIEnv *env_ = nullptr;
    bool abs_path_ = true;
    int socket_ = -1;
    std::string package_;
};

void companion_handler(int client) { Broker::instance().handle(client); }

} // namespace

REGISTER_ZYGISK_MODULE(Observer)
REGISTER_ZYGISK_COMPANION(companion_handler)
