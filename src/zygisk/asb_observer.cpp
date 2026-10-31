#include "zygisk.hpp"
#include "asb_observer_core.h"

#include <cerrno>
#include <chrono>
#include <fcntl.h>
#include <fstream>
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

std::string trim(std::string value) {
    while (!value.empty() && std::isspace(static_cast<unsigned char>(value.back()))) value.pop_back();
    size_t first = 0;
    while (first < value.size() && std::isspace(static_cast<unsigned char>(value[first]))) ++first;
    return value.substr(first);
}

bool observer_config_enabled() {
    if (access(ASB_ZYGISK_DIR "/disable", F_OK) == 0) return false;
    std::ifstream config(ASB_ZYGISK_CONFIG);
    if (!config) return false;
    bool enabled = false;
    std::string line;
    while (std::getline(config, line)) {
        line = trim(line);
        if (line.compare(0, 15, "zygisk_enabled=") == 0)
            enabled = trim(line.substr(15)) == "1";
        if (line.compare(0, 12, "zygisk_mode=") == 0 &&
            trim(line.substr(12)) != "observer") return false;
    }
    return enabled;
}

bool observer_hints_enabled() {
    if (access(ASB_ZYGISK_DIR "/disable", F_OK) == 0) return false;
    std::ifstream config(ASB_ZYGISK_CONFIG);
    if (!config) return false;
    bool enabled = false, hints = false;
    std::string line;
    while (std::getline(config, line)) {
        line = trim(line);
        if (line.compare(0, 15, "zygisk_enabled=") == 0)
            enabled = trim(line.substr(15)) == "1";
        if (line.compare(0, 13, "zygisk_hints=") == 0)
            hints = trim(line.substr(13)) == "1";
        if (line.compare(0, 12, "zygisk_mode=") == 0 &&
            trim(line.substr(12)) != "observer") return false;
    }
    return enabled && hints;
}

bool package_selected(const std::string &process_name) {
    if (!asb_observer_package_valid(asb_observer_base_package(process_name)) ||
        asb_observer_package_denied(process_name)) return false;
    std::ifstream list(ASB_ZYGISK_DIR "/packages.list");
    if (!list) return false;
    const std::string base = asb_observer_base_package(process_name);
    std::string line;
    size_t count = 0;
    while (std::getline(list, line) && count < ASB_OBSERVER_MAX_PROCESSES) {
        line = trim(line);
        if (line.empty() || line[0] == '#') continue;
        ++count;
        if (line == base) return true;
    }
    return false;
}

uint64_t process_start_ticks(pid_t pid) {
    std::ifstream stat("/proc/" + std::to_string(pid) + "/stat");
    std::string value;
    std::getline(stat, value);
    const size_t end = value.rfind(')');
    if (end == std::string::npos || end + 2 >= value.size()) return 0;
    std::istringstream fields(value.substr(end + 2)); // begins at field 3
    std::string token;
    for (int field = 3; field <= 22; ++field) {
        if (!(fields >> token)) return 0;
    }
    try { return std::stoull(token); } catch (...) { return 0; }
}

long process_rss_kb(pid_t pid) {
    std::ifstream status("/proc/" + std::to_string(pid) + "/status");
    std::string line;
    while (std::getline(status, line)) {
        if (line.compare(0, 6, "VmRSS:") == 0) {
            try { return std::stol(trim(line.substr(6))); } catch (...) { return 0; }
        }
    }
    return 0;
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

enum class GovernorHintResult { accepted, vetoed, unavailable };

/* One bounded datagram round trip, opened only for an accepted lifecycle transition.
 * No package name or tuning value crosses this interface. An old/missing governor simply
 * leaves its current policy untouched; the application is never punished for a timeout. */
GovernorHintResult request_governor_refresh() {
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
    static const char command[] = "zygisk-refresh";
    const ssize_t sent = sendto(fd, command, sizeof(command) - 1, 0,
                                reinterpret_cast<struct sockaddr *>(&server_addr), sizeof(server_addr));
    GovernorHintResult result = GovernorHintResult::unavailable;
    if (sent == static_cast<ssize_t>(sizeof(command) - 1)) {
        char reply[32] {};
        const ssize_t got = recv(fd, reply, sizeof(reply) - 1, 0);
        if (got > 0) result = std::strcmp(reply, "ok") == 0
            ? GovernorHintResult::accepted : GovernorHintResult::vetoed;
    }
    unlink(client_addr.sun_path);
    close(fd);
    return result;
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
            bool changed = false;
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
                    if (!peer_ok || peer.pid != frame.pid || !start_ok) core_.reject_invalid();
                    else {
                        const auto accepted = core_.start(frame, now);
                        changed = accepted == AsbObserverResult::accepted;
                        if (changed) owned_pid = frame.pid;
                        perhaps_hint_locked(changed, now);
                    }
                } else {
                    if (result < 0) core_.reject_invalid();
                    if (owned_pid > 0) changed = core_.exit(owned_pid);
                    core_.prune(now);
                    perhaps_hint_locked(changed, now);
                    ipc_cpu_us_ += cpu_us() - cpu_before;
                    if (changed || result < 0) persist_locked(now);
                    break;
                }
                ipc_cpu_us_ += cpu_us() - cpu_before;
                persist_locked(now);
            }
        }
        close(client);
    }

private:
    static uint64_t cpu_us() {
        struct timespec ts {};
        return clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts) == 0
            ? static_cast<uint64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000 : 0;
    }

    void perhaps_hint_locked(bool changed, int64_t now) {
        if (!changed || !observer_hints_enabled()) return;
        if (!core_.hint_permit(now)) { ++hints_throttled_; return; }
        ++policy_hints_;
        switch (request_governor_refresh()) {
            case GovernorHintResult::accepted: ++hints_accepted_; break;
            case GovernorHintResult::vetoed: ++hints_vetoed_; break;
            case GovernorHintResult::unavailable: ++hints_unavailable_; break;
        }
    }

    void persist_locked(int64_t now) {
        mkdir(ASB_ZYGISK_DIR, 0700);
        const std::string path = std::string(ASB_ZYGISK_DIR) + "/state." ASB_ABI_TAG ".tsv";
        const std::string tmp = path + ".tmp";
        const int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0) return;
        std::ostringstream out;
        out << "Z\tschema\t1\nZ\tmode\tobserver\nZ\tabi\t" ASB_ABI_TAG "\n";
        out << "Z\tupdated_monotonic_ms\t" << now << "\n";
        out << "Z\tevents_total\t" << core_.events_total() << "\n";
        out << "Z\tevents_dropped_total\t" << core_.dropped() << "\n";
        out << "Z\tevents_dropped_rate_limit\t" << core_.rate_limited() << "\n";
        out << "Z\tevents_dropped_duplicate\t" << core_.duplicate() << "\n";
        out << "Z\tevents_dropped_invalid\t" << core_.invalid() << "\n";
        out << "Z\tevents_dropped_capacity\t" << core_.capacity_dropped() << "\n";
        out << "Z\tipc_cpu_ms\t" << ipc_cpu_us_ / 1000 << "\n";
        out << "Z\tipc_wakeups\t" << wakeups_ << "\n";
        out << "Z\tpolicy_hints\t" << policy_hints_ << "\n";
        out << "Z\thints_accepted\t" << hints_accepted_ << "\n";
        out << "Z\thints_vetoed\t" << hints_vetoed_ << "\n";
        out << "Z\thints_unavailable\t" << hints_unavailable_ << "\n";
        out << "Z\thints_throttled\t" << hints_throttled_ << "\n";
        long rss = 0;
        for (const auto &entry : core_.processes()) {
            const long current_rss = process_rss_kb(entry.first);
            if (current_rss > 0) rss += current_rss;
            out << "P\t" << entry.first << "\t" << entry.second.start_ticks << "\t"
                << entry.second.package << "\t" << current_rss << "\n";
        }
        out << "Z\tmemory_kb\t" << rss << "\n";
        const std::string data = out.str();
        const char *p = data.data();
        size_t left = data.size();
        while (left) {
            const ssize_t n = write(fd, p, left);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            p += n; left -= static_cast<size_t>(n);
        }
        fsync(fd);
        close(fd);
        if (left == 0) rename(tmp.c_str(), path.c_str()); else unlink(tmp.c_str());
    }

    std::mutex mutex_;
    AsbObserverCore core_;
    uint64_t ipc_cpu_us_ = 0;
    uint64_t wakeups_ = 0;
    uint64_t policy_hints_ = 0, hints_accepted_ = 0, hints_vetoed_ = 0;
    uint64_t hints_unavailable_ = 0, hints_throttled_ = 0;
};

class Observer final : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override { api_ = api; env_ = env; }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        if (!args || !args->nice_name || !observer_config_enabled()) return skip();
        const char *raw = env_->GetStringUTFChars(args->nice_name, nullptr);
        if (!raw) return skip();
        package_ = raw;
        env_->ReleaseStringUTFChars(args->nice_name, raw);
        if (!package_selected(package_)) return skip();
        socket_ = api_->connectCompanion();
        if (socket_ < 0 || !api_->exemptFd(socket_)) {
            if (socket_ >= 0) close(socket_);
            socket_ = -1;
            return skip();
        }
        package_ = asb_observer_base_package(package_);
        // Selected processes retain the library only to own this fd. No hooks are installed.
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (socket_ < 0) return;
        AsbObserverFrame frame {};
        frame.magic = ASB_OBSERVER_MAGIC;
        frame.version = ASB_OBSERVER_VERSION;
        frame.kind = ASB_OBSERVER_EVENT_PROCESS_START;
        frame.size = sizeof(frame);
        frame.pid = getpid();
        frame.process_start_ticks = process_start_ticks(frame.pid);
        frame.monotonic_ms = asb_observer_monotonic_ms();
        if (!asb_observer_package_valid(package_) || package_.size() >= sizeof(frame.package)) {
            close(socket_);
            socket_ = -1;
            return;
        }
        std::snprintf(frame.package, sizeof(frame.package), "%s", package_.c_str());
        if (!write_all(socket_, &frame, sizeof(frame))) {
            close(socket_);
            socket_ = -1;
        }
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs *) override { skip(); }

private:
    void skip() { api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY); }
    zygisk::Api *api_ = nullptr;
    JNIEnv *env_ = nullptr;
    int socket_ = -1;
    std::string package_;
};

void companion_handler(int client) { Broker::instance().handle(client); }

} // namespace

REGISTER_ZYGISK_MODULE(Observer)
REGISTER_ZYGISK_COMPANION(companion_handler)
